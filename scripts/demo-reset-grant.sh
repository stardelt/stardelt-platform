#!/usr/bin/env bash
# Give the demo-reset principal the `playground` warehouse's `modify` role (platform#1316).
#
# Since platform#1130 an stardelt `write` grant is Lakekeeper `write`, and dropping a table
# or a schema is an administrator action: the nightly reset (`make demo-reset-now`) needs
# `modify`, which OpenFGA resolves down from the warehouse to every schema and table in it.
# The grant goes to the user `oidc~<subject>` of `sp-pipeline-demo`, never to the `demo`
# role: access-sync deletes every warehouse grant of a role it manages when the Catalog does
# not declare it, while a grant to another subject is left alone (it reads as `foreign` in
# the Catalog's Drift condition).
#
#   make demo-reset-grant                       grant it (idempotent; needs no YES=1)
#   bash scripts/demo-reset-grant.sh --check    read only; exit 1 when it is missing
#
# Copied from scripts/catalog-authz-bootstrap.sh: the temp directory and trap, the
# port-forward and the token helper. Secrets never reach argv or stdout: the token lives in
# a 0600 temp directory and curl reads it from a file (`-H @file`); the principal is named
# in the output, its `sub` never printed.
set -euo pipefail

NAMESPACE=${NAMESPACE:-stardelt}
BASE=http://127.0.0.1:18181
WAREHOUSE_NAME=playground
PRINCIPAL=service-account-sp-pipeline-demo
PASS=0
FAIL=0

ACTION=grant
case "${1:-}" in
  --check) ACTION=check ;;
  "") ;;
  *) printf 'usage: %s [--check]\n' "$0" >&2; exit 2 ;;
esac

TMP=$(mktemp -d)
chmod 700 "$TMP"
PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { printf '  ✓ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }
check() { # check <description> <0|1>
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

# --- the reset principal and its warehouse ------------------------------------
SUBJECT="$(kubectl -n "$NAMESPACE" get secret sp-pipeline-demo -o jsonpath='{.data.subject}' | base64 -d)"
[ -n "$SUBJECT" ] || die "Secret sp-pipeline-demo has no subject"
WAREHOUSE_ID="$(kubectl -n "$NAMESPACE" get catalog "$WAREHOUSE_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="CatalogReady")].message}' | awk '{print $NF}')"
case "$WAREHOUSE_ID" in *-*-*-*-*) ;; *) die "catalog $WAREHOUSE_NAME has no Lakekeeper warehouse id";; esac

token() { # token <client suffix> -> $TMP/token-<name>, $TMP/hdr-<name>
  local name=$1 id secret url scope cfg
  id=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.client-id}' | base64 -d)
  secret=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.client-secret}' | base64 -d)
  url=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.token-url}' | base64 -d)
  scope=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.scope}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "${scope:-}" ] || scope=openid
  cfg=$TMP/curl-$name.cfg
  {
    printf 'url = "%s"\n' "$url"
    printf 'data-urlencode = "grant_type=client_credentials"\n'
    printf 'data-urlencode = "client_id=%s"\n' "$id"
    printf 'data-urlencode = "client_secret=%s"\n' "$secret"
    printf 'data-urlencode = "scope=%s"\n' "$scope"
    printf 'silent\nshow-error\n'
  } > "$cfg"
  chmod 600 "$cfg"
  curl -K "$cfg" > "$TMP/token-$name.json" \
    || die "token request failed for svc-catalog-$name"
  python3 - "$TMP/token-$name.json" "$TMP/token-$name" <<'PY'
import json, sys
token = json.load(open(sys.argv[1]))["access_token"]
open(sys.argv[2], "w").write(token)
PY
  [ -s "$TMP/token-$name" ] || die "empty token for svc-catalog-$name"
  { printf 'Authorization: Bearer '; cat "$TMP/token-$name"; printf '\n'; } > "$TMP/hdr-$name"
  chmod 600 "$TMP/hdr-$name"
}

# --- c. port-forward and current state ---------------------------------------
kubectl -n "$NAMESPACE" port-forward svc/lakekeeper 18181:8181 >/dev/null 2>"$TMP/pf.log" &
PF_PID=$!
for _ in $(seq 1 40); do
  curl -sf "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "$BASE/health" >/dev/null 2>&1 || die "port-forward to Lakekeeper failed"

# The bridge's token is the one that reads and writes the assignment list.
token bridge

ASSIGNMENTS=$TMP/warehouse-assignments.json
curl -sS -f -H @"$TMP/hdr-bridge" \
  "$BASE/management/v1/permissions/warehouse/$WAREHOUSE_ID/assignments" > "$ASSIGNMENTS" \
  || die "Lakekeeper refused the warehouse assignment list"

has_modify() { # has_modify — prints yes when the principal holds modify on the warehouse
  python3 - "$ASSIGNMENTS" "$SUBJECT" <<'PY'
import json, sys
assignments = json.load(open(sys.argv[1])).get("assignments", [])
subject = "oidc~" + sys.argv[2]
print("yes" if any(a.get("type") == "modify" and a.get("user") == subject
                   for a in assignments) else "no")
PY
}

if [ "$(has_modify)" = yes ]; then
  if [ "$ACTION" = check ]; then
    ok "modify on warehouse $WAREHOUSE_NAME ($WAREHOUSE_ID) for $PRINCIPAL"
  else
    printf '› warehouse %s: unchanged — modify already granted\n' "$WAREHOUSE_NAME"
  fi
  exit 0
fi

if [ "$ACTION" = check ]; then
  printf 'MISSING  modify on warehouse %s (%s) for %s — run: make demo-reset-grant\n' \
    "$WAREHOUSE_NAME" "$WAREHOUSE_ID" "$PRINCIPAL" >&2
  exit 1
fi

# One assignment on the warehouse reaches every schema and table under it, and nothing
# outside it. The subject goes in a 0600 file, never on the command line.
PAYLOAD=$TMP/grant.json
python3 - "$SUBJECT" > "$PAYLOAD" <<'PY'
import json, sys
json.dump({"writes": [{"type": "modify", "user": "oidc~" + sys.argv[1]}], "deletes": []}, sys.stdout)
PY
chmod 600 "$PAYLOAD"
CODE=$(curl -sS -o "$TMP/grant-response.json" -w '%{http_code}' \
  -H @"$TMP/hdr-bridge" -H 'Content-Type: application/json' \
  --data @"$PAYLOAD" \
  "$BASE/management/v1/permissions/warehouse/$WAREHOUSE_ID/assignments")
case "$CODE" in
  200|204) ;;
  *) die "Lakekeeper answered HTTP $CODE to the grant — nothing was changed" ;;
esac
printf '› warehouse %s (%s): modify granted to %s\n' "$WAREHOUSE_NAME" "$WAREHOUSE_ID" "$PRINCIPAL"
