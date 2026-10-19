#!/usr/bin/env bash
# Initialise and configure the sandbox secret store (OpenBao, platform#160). Idempotent: run it
# after `helm upgrade --install openbao ...` (`make openbao` does).
#
#   NAMESPACE=stardelt bash scripts/openbao-bootstrap.sh
#
# 1. Initialises the store once (one recovery key, auto-unseal by the static key) and keeps the
#    recovery key and the initial root token in Secret `openbao-init`. SANDBOX ONLY: a root token
#    in a Secret is acceptable for a throwaway sandbox and for nothing else.
# 2. Enables the KV v2 engine at `secret/`.
# 3. Enables the JWT auth method against the platform's identity provider (the issuer is read from
#    ConfigMap `stardelt-identity`, key `issuerUrl`, or from ISSUER_URL) and the role
#    `platform-users`: tokens with the audience `openbao`, user = `preferred_username`, groups from
#    the `groups` claim, 15 minute tokens. Who may read and write which path is decided per owner
#    group by policies, external groups and group aliases (a later step).
#
# Tokens reach the store only through stdin of `kubectl exec`, never through argv or a log line.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
POD="${POD:-openbao-0}"
CONTAINER="${CONTAINER:-openbao}"
INIT_SECRET=openbao-init

for tool in kubectl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "openbao-bootstrap: $tool not found" >&2; exit 1; }
done

fail() { echo "openbao-bootstrap: $*" >&2; exit 1; }
K=(kubectl -n "$NAMESPACE")

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# bao <args...>: no token. bao_root <args...>: the root token is sent as the first line of stdin and
# exported inside the pod; anything the caller pipes in follows it.
bao() { "${K[@]}" exec -i "$POD" -c "$CONTAINER" -- env BAO_ADDR=http://127.0.0.1:8200 bao "$@"; }
bao_root() {
  { printf '%s\n' "$ROOT_TOKEN"; cat; } | "${K[@]}" exec -i "$POD" -c "$CONTAINER" -- \
    sh -c 'IFS= read -r BAO_TOKEN; export BAO_TOKEN BAO_ADDR=http://127.0.0.1:8200; exec bao "$@"' sh "$@"
}
json_get() { python3 -c 'import sys,json;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "$1"; }

# 1. Wait for the server, then initialise once.
status=""
for _ in $(seq 1 60); do
  if status="$(bao status -format=json 2>/dev/null)" && [ -n "$status" ]; then break; fi
  # `bao status` exits 2 when sealed or uninitialised but still prints the JSON.
  status="$(bao status -format=json 2>/dev/null || true)"; [ -n "$status" ] && break
  sleep 2
done
[ -n "$status" ] || fail "OpenBao ($POD in $NAMESPACE) never answered — is the release installed?"

if [ "$(printf '%s' "$status" | json_get initialized)" != "True" ]; then
  bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json > "$tmp/init.json" \
    || fail "initialisation failed"
  python3 - "$tmp" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/init.json"))
open(sys.argv[1] + "/recovery-key", "w").write(d["recovery_keys_b64"][0])
open(sys.argv[1] + "/root-token", "w").write(d["root_token"])
PY
  "${K[@]}" create secret generic "$INIT_SECRET" \
    --from-file=recovery-key="$tmp/recovery-key" --from-file=root-token="$tmp/root-token" >/dev/null \
    || fail "could not store Secret $INIT_SECRET (does it exist from an earlier install?)"
  "${K[@]}" label secret "$INIT_SECRET" app.kubernetes.io/part-of=stardelt >/dev/null
  echo "› OpenBao initialised; recovery key and root token are in Secret $INIT_SECRET (sandbox only)"
else
  echo "› OpenBao already initialised"
fi

ROOT_TOKEN="$("${K[@]}" get secret "$INIT_SECRET" -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)" \
  || true
[ -n "${ROOT_TOKEN:-}" ] || fail "Secret $INIT_SECRET has no root token: the store is initialised but its token is gone"

# 2. Wait until it is open (auto-unseal takes a moment after a restart).
for _ in $(seq 1 30); do
  [ "$(bao status -format=json 2>/dev/null | json_get sealed)" = "False" ] && break
  sleep 2
done
[ "$(bao status -format=json 2>/dev/null | json_get sealed)" = "False" ] \
  || fail "OpenBao stays sealed: check that Secret openbao-seal-key is the one the data was created with"

# 3. KV v2 at secret/.
if bao_root secrets list -format=json < /dev/null | python3 -c 'import sys,json;sys.exit(0 if "secret/" in json.load(sys.stdin) else 1)'; then
  echo "› secret/ (kv-v2): present"
else
  bao_root secrets enable -path=secret kv-v2 < /dev/null >/dev/null
  echo "› secret/ (kv-v2): enabled"
fi

# 4. JWT auth against the platform identity provider.
ISSUER="${ISSUER_URL:-$("${K[@]}" get configmap stardelt-identity -o jsonpath='{.data.issuerUrl}' 2>/dev/null || true)}"
case "$ISSUER" in https://*) ;; *) fail "no https issuer: ConfigMap stardelt-identity has no issuerUrl (run make install-identity) and ISSUER_URL is not set" ;; esac
if bao_root auth list -format=json < /dev/null | python3 -c 'import sys,json;sys.exit(0 if "jwt/" in json.load(sys.stdin) else 1)'; then
  echo "› jwt auth: present"
else
  bao_root auth enable jwt < /dev/null >/dev/null
  echo "› jwt auth: enabled"
fi
bao_root write auth/jwt/config "oidc_discovery_url=$ISSUER" "bound_issuer=$ISSUER" < /dev/null >/dev/null \
  || fail "OpenBao could not read the identity provider's discovery document at $ISSUER"
bao_root write auth/jwt/role/platform-users role_type=jwt bound_audiences=openbao \
  user_claim=preferred_username groups_claim=groups token_policies=default token_ttl=15m < /dev/null >/dev/null
echo "› jwt auth: configured for $ISSUER, role platform-users (audience openbao, groups from the groups claim)"

echo "openbao-bootstrap: OK"
