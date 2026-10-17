#!/usr/bin/env bash
# Create/refresh the ghcr.io image pull secret used by stardelt workloads.
#
# The Nova image lives at a private GHCR package; the node pulls it with this
# secret. Requires `gh` logged in with `write:packages`. The token is never
# written to the repository.
#
#   ./dev/ghcr-pull-secret.sh
set -euo pipefail

NS="${NS:-stardelt}"
USER="${GHCR_USER:-$(gh api user --jq .login)}"

command -v gh >/dev/null 2>&1 || { echo "gh not found" >&2; exit 1; }

kubectl create secret docker-registry ghcr-creds \
  --namespace "$NS" \
  --docker-server=ghcr.io \
  --docker-username="$USER" \
  --docker-password="$(gh auth token)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ ghcr-creds present in namespace $NS (user $USER)"
