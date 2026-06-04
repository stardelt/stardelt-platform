#!/usr/bin/env bash
# Render a manifest template by substituting our explicit tokens (and only those):
#   __STARDELT_DOMAIN__       → $STARDELT_DOMAIN
#   __STARDELT_ACME_SERVER__  → $STARDELT_ACME_SERVER (defaults to LE prod if unset)
# Usage: STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh manifests/ingress/foo.yaml
set -euo pipefail

file="${1:?usage: render.sh <template-file>}"
: "${STARDELT_DOMAIN:?STARDELT_DOMAIN must be set (e.g. lab.stardelt.io)}"
acme="${STARDELT_ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"

# '|' as the sed delimiter because the ACME server value contains '/'.
sed -e "s/__STARDELT_DOMAIN__/${STARDELT_DOMAIN}/g" \
    -e "s|__STARDELT_ACME_SERVER__|${acme}|g" \
    "$file"
