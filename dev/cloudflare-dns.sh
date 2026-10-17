#!/usr/bin/env bash
# Upsert or delete the playground DNS records in Cloudflare.
#
# Usage:
#   NAME=alpha.dev.stardelt.io IP=203.0.113.10 ./cloudflare-dns.sh upsert
#   NAME=alpha.dev.stardelt.io ./cloudflare-dns.sh delete
#
# Credentials are read from ~/.config/stardelt/cloudflare.env (mode 600) unless
# already exported. `WILDCARD=0` skips the wildcard A record.
set -euo pipefail

CF_ENV="${CF_ENV:-$HOME/.config/stardelt/cloudflare.env}"
# Runtime path, resolved via CF_ENV.
# shellcheck source=/dev/null
[ -f "$CF_ENV" ] && { set -a; . "$CF_ENV"; set +a; }

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (or create $CF_ENV)}"
ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-stardelt.io}"
NAME="${NAME:-${INGRESS_HOST:-alpha.dev.stardelt.io}}"
IP="${IP:-}"
WILDCARD="${WILDCARD:-1}"
TTL="${TTL:-300}"
ACTION="${1:-upsert}"
API="https://api.cloudflare.com/client/v4"

zone_id() {
  if [ -n "${CLOUDFLARE_ZONE_ID:-}" ]; then echo "$CLOUDFLARE_ZONE_ID"; return; fi
  curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "$API/zones?name=$ZONE_NAME" | jq -r '.result[0].id'
}

ZID="$(zone_id)"
if [ -z "$ZID" ] || [ "$ZID" = "null" ]; then
  echo "zone not found: $ZONE_NAME" >&2
  exit 1
fi

record_id() {
  curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "$API/zones/$ZID/dns_records?type=A&name=$1" | jq -r '.result[0].id // empty'
}

upsert() {
  local name="$1" content="$2" id body
  id="$(record_id "$name")"
  body="$(jq -nc --arg n "$name" --arg c "$content" --argjson ttl "$TTL" \
    '{type:"A",name:$n,content:$c,ttl:$ttl,proxied:false}')"
  if [ -n "$id" ]; then
    curl -fsS -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
      "$API/zones/$ZID/dns_records/$id" -d "$body" | jq -c '{action:"updated",name:.result.name,content:.result.content}'
  else
    curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
      "$API/zones/$ZID/dns_records" -d "$body" | jq -c '{action:"created",name:.result.name,content:.result.content}'
  fi
}

remove() {
  local name="$1" id
  id="$(record_id "$name")"
  if [ -z "$id" ]; then
    echo "{\"action\":\"absent\",\"name\":\"$name\"}"
    return
  fi
  curl -fsS -X DELETE -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "$API/zones/$ZID/dns_records/$id" | jq -c --arg n "$name" '{action:"deleted",name:$n,success:.success}'
}

case "$ACTION" in
  upsert)
    : "${IP:?IP is required for upsert}"
    upsert "$NAME" "$IP"
    [ "$WILDCARD" = "1" ] && upsert "*.$NAME" "$IP"
    ;;
  delete)
    remove "$NAME"
    [ "$WILDCARD" = "1" ] && remove "*.$NAME"
    ;;
  *)
    echo "usage: $0 upsert|delete  (env: NAME, IP, WILDCARD, TTL)" >&2
    exit 2
    ;;
esac
