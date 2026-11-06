#!/usr/bin/env bash
# Check that every image this repository pins is readable with the cluster's own pull credential
# (stardelt-platform#560). A pin is a string: it can name a digest the registry no longer serves, or
# a package the cluster credential cannot read, while every manifest still looks correct — which is
# how the dev cluster spent hours in ImagePullBackOff on a private ghcr.io/stardelt/superset package
# while its siblings were public (platform#558). This script:
#
#   1. collects every ghcr.io/stardelt/* pin from helm-values/*.yaml and manifests/*.yaml:
#        helm-values  an `image:` block with `repository:` (or `name:`) and the next `tag:`
#                     containing `@sha256:`; manifests  `image: <repo>:<tag>@sha256:<hex>`
#      (deduped on repo@digest; images this repository does not own are ignored)
#   2. reads the cluster's pull credential (Secret .dockerconfigjson, never printed)
#   3. for each pin: the GHCR token endpoint with that Basic credential (401/403 => the credential
#      cannot read the package), then HEAD of the manifest by digest (200 readable, 403 cannot read,
#      404 digest gone)
#   4. prints one line per pin and exits:
#        0  every pin is readable (PASS)
#        1  a pin is not readable (FAIL)
#        3  the credential could not be read, so the run proved nothing (UNVERIFIED)
#
# It needs the *cluster's* credential, so it is a manual target (`make verify-images`), never CI.
# Read-only: no pulls, no kubectl apply, no mutations.
#
#   scripts/verify-images.sh              check every pin with the cluster credential
#   scripts/verify-images.sh --pins-only  print the pins it collected, no cluster needed
#
# Environment:
#   NAMESPACE  default stardelt
#   SECRET     default ghcr-creds  (the imagePullSecret)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

pins_only=0
case "${1:-}" in
  --pins-only) pins_only=1 ;;
  "") ;;
  *) echo "usage: $0 [--pins-only]" >&2; exit 2 ;;
esac

NAMESPACE="${NAMESPACE:-stardelt}"
SECRET="${SECRET:-ghcr-creds}"

ok()         { printf '✓ %s\n' "$*"; }
fail()       { printf '✗ %s\n' "$*"; }
unverified() { printf '? %s\n' "$*" >&2; }

command -v kubectl >/dev/null 2>&1 || { unverified "kubectl not found"; echo "UNVERIFIED (kubectl not found)" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { unverified "python3 is required"; echo "UNVERIFIED (python3 not found)" >&2; exit 3; }
command -v curl >/dev/null 2>&1    || { unverified "curl is required"; echo "UNVERIFIED (curl not found)" >&2; exit 3; }
command -v base64 >/dev/null 2>&1  || { unverified "base64 is required"; echo "UNVERIFIED (base64 not found)" >&2; exit 3; }

# ---------------------------------------------------------------------------
# 1. Collect every ghcr.io/stardelt/* pin (repo + sha256 digest), deduped.
# ---------------------------------------------------------------------------
pins="$(python3 - <<'PY'
import glob, os, re, sys

owned = "ghcr.io/stardelt/"
# repo (owner/name, no ghcr.io/) -> digest (64 hex, no sha256: prefix)
seen = {}
order = []

def add(repo, digest):
    key = (repo, digest)
    if key not in seen:
        seen[key] = True
        order.append(key)

repo_line = re.compile(r'^\s*(?:repository|name)\s*:\s*["\']?(ghcr\.io/stardelt/[^\s"\']+)["\']?\s*$')
tag_line = re.compile(r'^\s*tag\s*:\s*["\']?[^\s"\']*@sha256:([0-9a-f]{64})["\']?')
digest_line = re.compile(r'^\s*digest\s*:\s*["\']?(?:sha256:)?([0-9a-f]{64})["\']?\s*$')
image_line = re.compile(r'(ghcr\.io/stardelt/[^\s"\']+)@sha256:([0-9a-f]{64})')

def repo_only(ref):
    # Strip a :tag suffix (e.g. nova:dev) so the API path and dedupe key name the repository.
    base = ref.rsplit("/", 1)
    if len(base) == 2 and ":" in base[1]:
        return base[0] + "/" + base[1].split(":", 1)[0]
    return ref

for path in sorted(glob.glob("helm-values/*.yaml") + glob.glob("manifests/*.yaml")):
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        continue
    pending_repo = None
    for line in lines:
        # Every `image:`/value line carrying a full pinned reference, anywhere in the file.
        m = image_line.search(line)
        if m:
            add(repo_only(m.group(1)), m.group(2))
        # Helm values state machine: remember the most recent owned repository/name, emit it
        # with the next tag that carries a digest. A repository without a following digest tag
        # (e.g. a bare tag during a break-glass) leaves nothing behind.
        rm = repo_line.match(line)
        if rm:
            pending_repo = rm.group(1)
            continue
        tm = tag_line.match(line)
        if tm and pending_repo and pending_repo.startswith(owned):
            add(pending_repo, tm.group(1))
            pending_repo = None
        dm = digest_line.match(line)
        if dm and pending_repo and pending_repo.startswith(owned):
            add(pending_repo, dm.group(1))
            pending_repo = None

for repo, digest in order:
    print(repo + "\t" + digest)
PY
)"

if [ -z "$pins" ]; then
  unverified "no ghcr.io/stardelt/* pins found under helm-values/*.yaml or manifests/*.yaml"
  echo "UNVERIFIED (no pins found)" >&2
  exit 3
fi
if [ "$pins_only" = "1" ]; then
  printf '%s\n' "$pins"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Read the cluster credential (never printed).
# ---------------------------------------------------------------------------
if ! dockerconfig="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null)"; then
  unverified "cannot read Secret $NAMESPACE/$SECRET (kube-context: $(kubectl config current-context 2>/dev/null || echo none))"
  echo "UNVERIFIED (Secret $NAMESPACE/$SECRET cannot be read)" >&2
  exit 3
fi
if [ -z "$dockerconfig" ]; then
  unverified "Secret $NAMESPACE/$SECRET has no .dockerconfigjson"
  echo "UNVERIFIED (Secret $NAMESPACE/$SECRET has no .dockerconfigjson)" >&2
  exit 3
fi

# Decode .dockerconfigjson -> ghcr.io Basic credential. Prefer the `auth` field; fall back to
# username:password. Output is a single line "<kind>\t<value>" where kind is "auth" (already
# base64 user:pass) or "userpass". The value never reaches stdout except through this variable,
# which is never echoed.
cred_kind_value="$(printf '%s' "$dockerconfig" | base64 -d 2>/dev/null | python3 -c '
import base64, json, sys
try:
    cfg = json.load(sys.stdin)
except Exception:
    print("error\tcannot parse .dockerconfigjson")
    raise SystemExit(0)
entry = (cfg.get("auths") or {}).get("ghcr.io") or {}
auth = entry.get("auth") or ""
if auth:
    print("auth\t" + auth)
else:
    u = entry.get("username") or ""
    p = entry.get("password") or ""
    if u or p:
        print("userpass\t" + base64.b64encode((u + ":" + p).encode()).decode())
    else:
        print("error\tno ghcr.io auth in .dockerconfigjson")
')" || true

cred_kind="${cred_kind_value%%$'\t'*}"
cred_b64="${cred_kind_value#*$'\t'}"
if [ "$cred_kind" = "error" ] || [ -z "$cred_b64" ] || [ "$cred_kind_value" = "$cred_b64" ]; then
  unverified "Secret $NAMESPACE/$SECRET: ${cred_b64:-cannot read credential}"
  echo "UNVERIFIED (Secret $NAMESPACE/$SECRET has no usable ghcr.io credential)" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# 3. Check each pin with the cluster credential. No anonymous fallback.
# ---------------------------------------------------------------------------
failures=0
total=0
while IFS=$'\t' read -r repo digest; do
  [ -n "$repo" ] || continue
  total=$((total + 1))
  # ghcr.io/stardelt/<name> -> owner stardelt, name <name>
  name="${repo#ghcr.io/}"
  short="${repo#ghcr.io/stardelt/}"
  short_digest="${digest:0:8}"

  token_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Basic ${cred_b64}" \
    "https://ghcr.io/token?scope=repository:${name}:pull&service=ghcr.io" 2>/dev/null)" || true
  token_status="${token_status:-000}"
  # Keep only the HTTP status (curl may append nothing else, but be defensive).
  token_status="${token_status: -3}"

  if [ "$token_status" = "401" ] || [ "$token_status" = "403" ]; then
    failures=$((failures + 1))
    fail "$short   $repo@sha256:$digest   ${token_status}: the cluster credential cannot read this package"
    continue
  elif [ "$token_status" != "200" ]; then
    failures=$((failures + 1))
    fail "$short   $repo@sha256:$digest   ${token_status}: the token endpoint did not accept the cluster credential"
    continue
  fi

  token="$(curl -fsS -H "Authorization: Basic ${cred_b64}" \
    "https://ghcr.io/token?scope=repository:${name}:pull&service=ghcr.io" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)" || token=""

  if [ -z "$token" ]; then
    failures=$((failures + 1))
    fail "$short   $repo@sha256:$digest   the token endpoint returned no token"
    continue
  fi

  manifest_status="$(curl -sS -o /dev/null -w '%{http_code}' -X HEAD \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${name}/manifests/sha256:${digest}" 2>/dev/null)" || true
  manifest_status="${manifest_status:-000}"
  manifest_status="${manifest_status: -3}"

  case "$manifest_status" in
    200)
      ok "$short   $repo@sha256:${short_digest}…   readable"
      ;;
    403)
      failures=$((failures + 1))
      fail "$short   $repo@sha256:$digest   403: the cluster credential cannot read this package (private package?)"
      ;;
    404)
      failures=$((failures + 1))
      fail "$short   $repo@sha256:$digest   404: the digest is gone from the registry (garbage-collected?)"
      ;;
    *)
      failures=$((failures + 1))
      fail "$short   $repo@sha256:$digest   ${manifest_status}: the manifest could not be read"
      ;;
  esac
done <<<"$pins"

# ---------------------------------------------------------------------------
# 4. Verdict.
# ---------------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "FAIL ($failures of $total images is not readable)"
  exit 1
fi

echo "PASS ($total images readable, 0 failed)"
