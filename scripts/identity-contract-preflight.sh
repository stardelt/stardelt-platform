#!/usr/bin/env bash
# The identity keys the Trino overlay reads must exist before the helm upgrade
# (platform#1093). `make upgrade` installs identity first (`scripts/platform.sh`),
# but `make trino` alone does not: a ConfigMap that predates `tokenEndpoint`
# leaves CATALOG_TOKEN_URL unset while the overlay still renders the catalog
# properties, and Trino refuses to start
# ("Environment variable is not set: CATALOG_TOKEN_URL").
#
#   NAMESPACE=stardelt BASE_DOMAIN=alpha.dev.stardelt.io bash scripts/identity-contract-preflight.sh
#
# Reads ConfigMap stardelt-identity only. When a key is missing it runs
# scripts/identity-bootstrap.sh once (idempotent: existing Secrets are kept) and
# checks again. Exit 0 = nothing to do or repaired, 1 = cannot repair.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
BOOTSTRAP="${IDENTITY_BOOTSTRAP:-}"
[ -n "$BOOTSTRAP" ] || BOOTSTRAP="scripts/identity-bootstrap.sh"
KEYS=(tokenEndpoint trinoUrl)

command -v kubectl >/dev/null 2>&1 || { echo "identity-contract-preflight: kubectl not found" >&2; exit 1; }

if ! kubectl -n "$NAMESPACE" get configmap stardelt-identity >/dev/null 2>&1; then
  echo "identity-contract-preflight: no platform IdP (ConfigMap stardelt-identity is absent) — nothing to check"
  exit 0
fi

# One unset key per word, so a message can list them without word splitting.
missing() {
  local key
  for key in "${KEYS[@]}"; do
    [ -n "$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath="{.data.${key}}")" ] \
      || printf '%s ' "$key"
  done
}

absent="$(missing)"
if [ -z "$absent" ]; then
  echo "identity-contract-preflight: OK (tokenEndpoint and trinoUrl present)"
  exit 0
fi

if [ -z "$BASE_DOMAIN" ]; then
  echo "identity-contract-preflight: ConfigMap stardelt-identity lacks ${absent}and BASE_DOMAIN is empty." >&2
  echo "  Run: NAMESPACE=${NAMESPACE} BASE_DOMAIN=<the base domain> bash scripts/identity-bootstrap.sh" >&2
  exit 1
fi

echo "› ConfigMap stardelt-identity lacks ${absent}— running ${BOOTSTRAP}"
NAMESPACE="$NAMESPACE" BASE_DOMAIN="$BASE_DOMAIN" bash "$BOOTSTRAP" >/dev/null

absent="$(missing)"
if [ -n "$absent" ]; then
  echo "identity-contract-preflight: ${BOOTSTRAP} did not add ${absent}; refusing to render Trino" >&2
  exit 1
fi
echo "identity-contract-preflight: repaired (tokenEndpoint and trinoUrl present)"
