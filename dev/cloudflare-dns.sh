#!/usr/bin/env bash
# Upsert or delete the playground DNS records in Cloudflare.
#
# Usage:
#   NAME=alpha.dev.stardelt.io IP=203.0.113.10 ./cloudflare-dns.sh upsert
#   NAME=alpha.dev.stardelt.io ./cloudflare-dns.sh delete
#
# A home host behind a router with a dynamic address points the record at the
# router's DDNS name instead of an address, so the record survives an IP change:
#   TYPE=CNAME TARGET=yourname.ddns-provider.example NAME=alpha.example.dev ./cloudflare-dns.sh upsert
#
# Credentials are read from ~/.config/stardelt/cloudflare.env (mode 600) unless
# already exported. `WILDCARD=0` skips the wildcard record.
#
# Guard rail: NAME must be a strict subdomain of the zone (never the apex), so a typo
# or an empty/odd INGRESS_HOST cannot touch the zone's own records.
set -euo pipefail

CF_ENV="${CF_ENV:-$HOME/.config/stardelt/cloudflare.env}"
# Runtime path, resolved via CF_ENV.
# shellcheck source=/dev/null
[ -f "$CF_ENV" ] && { set -a; . "$CF_ENV"; set +a; }

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (or create $CF_ENV)}"
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-stardelt.io}"
NAME="${NAME:-${INGRESS_HOST:-alpha.dev.stardelt.io}}"
TYPE="${TYPE:-A}"
IP="${IP:-}"
TARGET="${TARGET:-}"
WILDCARD="${WILDCARD:-1}"
TTL="${TTL:-300}"
ACTION="${1:-upsert}"
API="https://api.cloudflare.com/client/v4"

case "$ACTION" in
  upsert|delete) ;;
  *)
    echo "usage: $0 upsert|delete  (env: NAME, IP, WILDCARD, TTL)" >&2
    exit 2
    ;;
esac

NAME="${NAME,,}"
if [[ ! "$NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || [[ "$NAME" != *".$ZONE_NAME" ]]; then
  echo "refusing NAME='$NAME': must be a hostname strictly below zone $ZONE_NAME" >&2
  exit 2
fi
case "$TYPE" in
  A|CNAME) ;;
  *) echo "TYPE must be A or CNAME (got '$TYPE')" >&2; exit 2 ;;
esac
if [ "$ACTION" = "upsert" ]; then
  if [ "$TYPE" = "CNAME" ]; then
    [[ "$TARGET" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
      || { echo "TARGET must be a hostname for a CNAME (got '$TARGET')" >&2; exit 2; }
  else
    [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "IP must be an IPv4 address (got '${IP}')" >&2; exit 2; }
  fi
fi

# cf <method> <path> [curl args...] — authenticated Cloudflare API call. The token is
# handed to curl through a config on a pipe, so it never shows up in `ps` output.
cf() {
  local method="$1" path="$2"
  shift 2
  curl -fsS --connect-timeout 10 --max-time 30 -X "$method" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
    -H "Content-Type: application/json" "$@" "$API$path"
}

zone_id() {
  if [ -n "${CLOUDFLARE_ZONE_ID:-}" ]; then echo "$CLOUDFLARE_ZONE_ID"; return; fi
  cf GET "/zones?name=$ZONE_NAME" | jq -r '.result[0].id'
}

ZID="$(zone_id)"
if [ -z "$ZID" ] || [ "$ZID" = "null" ]; then
  echo "zone not found: $ZONE_NAME" >&2
  exit 1
fi

# Any record type at that name would collide with the one we want (Cloudflare
# refuses a CNAME next to an A), so look the name up by name and replace the
# other type when it exists.
upsert() {
  local name="$1" content="$2" id body
  id="$(cf GET "/zones/$ZID/dns_records?name=$1" | jq -r --arg t "$TYPE" \
    '(.result[] | select(.type == $t) | .id) // empty' | head -1)"
  # A leftover record of the other type at the same name blocks this one.
  local other="A"; [ "$TYPE" = "A" ] && other="CNAME"
  local stale
  stale="$(cf GET "/zones/$ZID/dns_records?name=$1" | jq -r --arg t "$other" \
    '(.result[] | select(.type == $t) | .id) // empty' | head -1)"
  if [ -n "$stale" ]; then
    cf DELETE "/zones/$ZID/dns_records/$stale" >/dev/null
    echo "{\"action\":\"replaced-$other\",\"name\":\"$name\"}"
  fi
  body="$(jq -nc --arg t "$TYPE" --arg n "$name" --arg c "$content" --argjson ttl "$TTL" \
    '{type:$t,name:$n,content:$c,ttl:$ttl,proxied:false}')"
  if [ -n "$id" ]; then
    cf PUT "/zones/$ZID/dns_records/$id" -d "$body" | jq -c '{action:"updated",name:.result.name,content:.result.content}'
  else
    cf POST "/zones/$ZID/dns_records" -d "$body" | jq -c '{action:"created",name:.result.name,content:.result.content}'
  fi
}

remove() {
  local name="$1" id
  id="$(record_id "$name")"
  if [ -z "$id" ]; then
    echo "{\"action\":\"absent\",\"name\":\"$name\"}"
    return
  fi
  cf DELETE "/zones/$ZID/dns_records/$id" | jq -c --arg n "$name" '{action:"deleted",name:$n,success:.success}'
}

CONTENT="$IP"
[ "$TYPE" = "CNAME" ] && CONTENT="$TARGET"

case "$ACTION" in
  upsert)
    upsert "$NAME" "$CONTENT"
    if [ "$WILDCARD" = "1" ]; then upsert "*.$NAME" "$CONTENT"; fi
    ;;
  delete)
    remove "$NAME"
    if [ "$WILDCARD" = "1" ]; then remove "*.$NAME"; fi
    ;;
esac
