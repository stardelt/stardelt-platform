#!/usr/bin/env bash
# Delete the stardelt dev cluster and its playground DNS records.
#
# Deletes exactly what dev/hetzner-k3s/cluster.yaml describes (written by provision.sh)
# and the DNS records for $INGRESS_HOST, and shows both first. On a terminal it asks
# for confirmation; FORCE=1 skips the question. Without a terminal (scripts, CI) it
# proceeds after printing the plan, as before.
#
# DNS is only removed once the cluster is gone (or when there is no cluster.yaml), so a
# failed delete never leaves a live cluster without its hostname.
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

CFG="$HERE/cluster.yaml"
cluster=""
if [ -f "$CFG" ]; then
  command -v hetzner-k3s >/dev/null || { echo "hetzner-k3s not found" >&2; exit 1; }
  cluster="$(awk -F': *' '/^cluster_name:/ { print $2; exit }' "$CFG")"
  if [ -z "$cluster" ]; then
    echo "cannot read cluster_name from $CFG" >&2
    exit 1
  fi
  if [ -n "${CLUSTER_NAME:-}" ] && [ "$CLUSTER_NAME" != "$cluster" ]; then
    echo "refusing: CLUSTER_NAME is '$CLUSTER_NAME' but $CFG describes '$cluster'." >&2
    exit 1
  fi
fi
do_dns=0
if [ -f "$CF_ENV" ] && [ -x "$HERE/../cloudflare-dns.sh" ]; then do_dns=1; fi

echo "About to delete:"
if [ -n "$cluster" ]; then
  echo "  - Hetzner cluster '$cluster' (config: $CFG) and everything on its disks"
else
  echo "  - no cluster (no $CFG)"
fi
if [ "$do_dns" = 1 ]; then
  echo "  - DNS A records ${INGRESS_HOST} and *.${INGRESS_HOST}"
fi

if [ "${FORCE:-0}" != 1 ] && [ -t 0 ]; then
  read -r -p "Proceed? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi

if [ -n "$cluster" ]; then
  echo "› deleting cluster '$cluster' (hetzner-k3s)"
  if ! hetzner-k3s delete --config "$CFG" --force --quiet; then
    echo "cluster delete failed — leaving DNS in place. Check the Hetzner console; once the" >&2
    echo "cluster is really gone, run 'make dev-dns-down'." >&2
    exit 1
  fi
else
  echo "no cluster.yaml — nothing to delete (run provision.sh first)"
fi

if [ "$do_dns" = 1 ]; then
  echo "› removing DNS records for ${INGRESS_HOST}"
  if ! NAME="$INGRESS_HOST" bash "$HERE/../cloudflare-dns.sh" delete; then
    echo "DNS cleanup failed — the records still point at a released IP. Run 'make dev-dns-down'." >&2
    exit 1
  fi
fi
