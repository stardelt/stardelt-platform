#!/usr/bin/env bash
# Point *.${STARDELT_DOMAIN} at the current k3s master public IP via Cloudflare.
# Idempotent: creates the A-record if missing, updates it if the IP changed.
#
# Requires:
#   STARDELT_DOMAIN       e.g. lab.stardelt.io
#   CLOUDFLARE_API_TOKEN  DNS:Edit token for the stardelt.io zone
#                         (falls back to reading the in-cluster secret)
#   kubectl context pointing at the target cluster; curl + jq installed.
set -euo pipefail

: "${STARDELT_DOMAIN:?STARDELT_DOMAIN must be set (e.g. lab.stardelt.io)}"
NAMESPACE="${NAMESPACE:-stardelt}"
record="*.${STARDELT_DOMAIN}"
# Zone is the registrable domain: strip all but the last two labels.
zone="$(echo "$STARDELT_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"

# Token: prefer env, else read the in-cluster secret created from the template.
token="${CLOUDFLARE_API_TOKEN:-}"
if [ -z "$token" ]; then
  token="$(kubectl -n "$NAMESPACE" get secret cloudflare-api-token \
    -o jsonpath='{.data.api-token}' | base64 -d)"
fi
[ -n "$token" ] || { echo "no Cloudflare token (set CLOUDFLARE_API_TOKEN or apply the secret)" >&2; exit 1; }

# Current master public IP: the node labeled control-plane, ExternalIP.
ip="$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
[ -n "$ip" ] || { echo "could not determine master ExternalIP from kubectl" >&2; exit 1; }
echo "› master IP: $ip"

cf() { curl -sf -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$@"; }
api="https://api.cloudflare.com/client/v4"

zone_id="$(cf "$api/zones?name=$zone" | jq -r '.result[0].id')"
[ -n "$zone_id" ] && [ "$zone_id" != "null" ] || { echo "zone $zone not found in Cloudflare" >&2; exit 1; }

rec_id="$(cf "$api/zones/$zone_id/dns_records?type=A&name=$record" | jq -r '.result[0].id // empty')"
payload="$(jq -nc --arg ip "$ip" --arg name "$record" \
  '{type:"A", name:$name, content:$ip, ttl:120, proxied:false}')"

if [ -n "$rec_id" ]; then
  cf -X PUT "$api/zones/$zone_id/dns_records/$rec_id" --data "$payload" >/dev/null
  echo "› updated $record → $ip"
else
  cf -X POST "$api/zones/$zone_id/dns_records" --data "$payload" >/dev/null
  echo "› created $record → $ip"
fi
