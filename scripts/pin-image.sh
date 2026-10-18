#!/usr/bin/env bash
# Pin a deployment to the newest published digest of an image tag.
#
#   ./scripts/pin-image.sh nova              # ghcr.io/stardelt/nova:dev → namespace stardelt
#   ./scripts/pin-image.sh stardelt-operator stardelt main
#   APP=trino NS=lab TAG=v480 ./scripts/pin-image.sh
#
# Why this exists: a moving tag is not an upgrade path. CI publishes `dev` on
# every merge to main, but a node that already has layers for that tag can keep
# serving the older image after a pod restart, so "the tag moved" and "the
# cluster changed" are different events. Deployments pin digests; this resolves
# the tag to its current digest in the registry and applies that.
#
# Works for public packages anonymously, and for private ones with `gh` logged
# in (the token is passed to the registry, never printed).
set -euo pipefail

APP="${1:-${APP:-nova}}"
NS="${2:-${NS:-stardelt}}"
TAG="${3:-${TAG:-dev}}"
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-stardelt}"
REPO="$OWNER/$APP"
DEPLOY="${DEPLOY:-$APP}"
CONTAINER="${CONTAINER:-}"

for tool in curl kubectl; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

# Anonymous pull token first; GHCR issues one for public packages without auth.
token=$(curl -fsS "https://$REGISTRY/token?scope=repository:$REPO:pull&service=$REGISTRY" 2>/dev/null \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || token=""

accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

resolve() {
  curl -fsSI -H "Authorization: Bearer $1" -H "Accept: $accept" \
    "https://$REGISTRY/v2/$REPO/manifests/$TAG" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}

digest=$(resolve "$token" || true)

if [ -z "$digest" ] && command -v gh >/dev/null; then
  # Private package: the gh token carries read:packages for GHCR.
  gh_user=$(gh api user --jq .login 2>/dev/null || true)
  gh_token=$(gh auth token 2>/dev/null || true)
  if [ -n "$gh_user" ] && [ -n "$gh_token" ]; then
    basic=$(printf '%s:%s' "$gh_user" "$gh_token" | base64 | tr -d '\n')
    private_token=$(curl -fsS -H "Authorization: Basic $basic" \
      "https://$REGISTRY/token?scope=repository:$REPO:pull&service=$REGISTRY" 2>/dev/null \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || private_token=""
    [ -n "$private_token" ] && digest=$(resolve "$private_token" || true)
  fi
fi

if [ -z "$digest" ]; then
  echo "$REGISTRY/$REPO:$TAG not resolvable (private package needs read:packages?)" >&2
  exit 1
fi

if [ -z "$CONTAINER" ]; then
  CONTAINER=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].name}')
fi

current=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}")
echo "› $NS/$DEPLOY $CONTAINER"
echo "    now:  $current"
echo "    new:  $REGISTRY/$REPO@$digest"

# The deployment and the manifest are updated independently: skipping the first because the
# cluster already matches must not skip the second, or the manifest keeps the old digest and
# the next `kubectl apply` puts it back. (That hole shipped once — the early exit said
# "already pinned" and left the file alone.)
if [ "$current" = "$REGISTRY/$REPO@$digest" ]; then
  echo "already pinned"
else
  kubectl -n "$NS" set image "deploy/$DEPLOY" "$CONTAINER=$REGISTRY/$REPO@$digest" >/dev/null
  kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout="${TIMEOUT:-300s}"
fi

# Keep the manifest in step, or the next `kubectl apply` puts the mutable tag back and a
# stale cached layer can serve an older image (that happened four times in one day, twice
# during an apply that looked like a no-op). The reference keeps the tag for readability
# and adds the digest the kubelet actually resolves: `:dev@sha256:…`.
#
# Components without a checked-in image line (stardelt-operator) skip this half.
case "$APP" in
  nova)  manifest="${MANIFEST:-manifests/nova-deployment.yaml}" ;;
  spark) manifest="${MANIFEST:-manifests/spark.yaml}" ;;
  *)     manifest="${MANIFEST:-}" ;;
esac

if [ -n "$manifest" ] && [ -f "$manifest" ] && grep -qE "^\s+image: $REGISTRY/$REPO:" "$manifest"; then
  python3 - "$manifest" "$REGISTRY/$REPO" "$digest" "$APP" <<'PYEOF'
import re, sys
path, repo, digest, app = sys.argv[1:5]
text = open(path).read()

# The Deployment's own image.
text, replaced = re.subn(
    rf"(^\s+image: ){re.escape(repo)}:([^\s@]+)(?:@sha256:[0-9a-f]+)?\s*$",
    lambda m: f"{m.group(1)}{repo}:{m.group(2)}@{digest}",
    text,
    flags=re.M,
)

# Spark executors are created by the driver from spark-defaults.conf, not from
# the Deployment spec. Pin the same digest there, or a node with a cached `dev`
# layer can run executors from an older build while the driver runs the new one.
if app == "spark":
    text, executor = re.subn(
        rf"(^\s+spark\.kubernetes\.container\.image\s+){re.escape(repo)}:([^\s@]+)(?:@sha256:[0-9a-f]+)?\s*$",
        lambda m: f"{m.group(1)}{repo}:{m.group(2)}@{digest}",
        text,
        flags=re.M,
    )
    replaced += executor

if replaced:
    open(path, "w").write(text)
    print(f"› {path}: image pinned to {repo}:…@{digest[:19]}…")
PYEOF
fi
