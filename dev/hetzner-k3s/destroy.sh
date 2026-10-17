#!/usr/bin/env bash
# Delete the stardelt dev cluster and its playground DNS records.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CF_ENV="${CF_ENV:-$HOME/.config/stardelt/cloudflare.env}"
# Runtime paths, resolved via CF_ENV / HETZNER_ENV.
# shellcheck source=/dev/null
[ -f "$CF_ENV" ] && { set -a; . "$CF_ENV"; set +a; }
HETZNER_ENV="${HETZNER_ENV:-$HOME/.config/stardelt/hetzner.env}"
# shellcheck source=/dev/null
[ -f "$HETZNER_ENV" ] && { set -a; . "$HETZNER_ENV"; set +a; }
INGRESS_HOST="${INGRESS_HOST:-alpha.dev.stardelt.io}"

if [ -f "$HERE/cluster.yaml" ]; then
  command -v hetzner-k3s >/dev/null || { echo "hetzner-k3s not found" >&2; exit 1; }
  echo "› deleting cluster (hetzner-k3s)"
  hetzner-k3s delete --config "$HERE/cluster.yaml" --force --quiet || true
else
  echo "no cluster.yaml — nothing to delete (run provision.sh first)"
fi

if [ -f "$CF_ENV" ] && [ -x "$HERE/../cloudflare-dns.sh" ]; then
  echo "› removing DNS records for ${INGRESS_HOST}"
  NAME="$INGRESS_HOST" bash "$HERE/../cloudflare-dns.sh" delete || true
fi
