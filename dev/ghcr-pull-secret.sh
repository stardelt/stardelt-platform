#!/usr/bin/env bash
# Create/refresh the ghcr.io image pull secret used by stardelt workloads.
#
# The Nova image lives at a private GHCR package; the node pulls it with this
# secret. The token is never written to the repository.
#
#   ./dev/ghcr-pull-secret.sh                 # uses `gh auth token`
#   GHCR_TOKEN=... ./dev/ghcr-pull-secret.sh  # preferred: a PAT with read:packages only
#
# The secret is stored in the cluster, readable by anything that can read Secrets in
# the namespace. `gh auth token` is your full GitHub login token (often with `repo`
# scope), so prefer a dedicated read:packages token via GHCR_TOKEN.
#
# Acts on kubectl's current context (override with KUBE_CONTEXT=...); it is printed
# before anything is applied.
set -euo pipefail

NS="${NS:-stardelt}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 1; }
if [ -z "${GHCR_TOKEN:-}" ] || [ -z "${GHCR_USER:-}" ]; then
  command -v gh >/dev/null 2>&1 || { echo "gh not found (or set both GHCR_USER and GHCR_TOKEN)" >&2; exit 1; }
fi

user="${GHCR_USER:-$(gh api user --jq .login)}"
if [ -n "${GHCR_TOKEN:-}" ]; then
  token="$GHCR_TOKEN"
else
  echo "note: using your gh login token; set GHCR_TOKEN to a read:packages-only PAT instead" >&2
  token="$(gh auth token)"
fi

kube=(kubectl)
if [ -n "${KUBE_CONTEXT:-}" ]; then
  kube+=(--context "$KUBE_CONTEXT")
  ctx="$KUBE_CONTEXT"
else
  ctx="$(kubectl config current-context)"
fi
echo "› kube-context: $ctx"

"${kube[@]}" create secret docker-registry ghcr-creds \
  --namespace "$NS" \
  --docker-server=ghcr.io \
  --docker-username="$user" \
  --docker-password="$token" \
  --dry-run=client -o yaml | "${kube[@]}" apply -f -

echo "✓ ghcr-creds present in namespace $NS (user $user, context $ctx)"
