#!/usr/bin/env bash
# The permission matrix, proved against the OPA bridge (authz 7/8,
# stardelt-platform#309).
#
#   make verify-catalog-permissions
#
# Asks the bridge the same question Trino will ask it after the switch: for each
# seed person (`dev-finops`, `dev-analytics`, `dev-outsider` — the users
# `make seed-dev-access` creates) and each row of the matrix below,
# `POST http://lakekeeper-opa:8282/v1/data/trino/allow` with the person's
# Keycloak user id as `context.identity.user` (the bridge prefixes `oidc~`, which
# is how access-sync writes role assignees) and the operation/resource Trino
# sends for that statement. `true` means the catalog says yes, `false` means no.
#
# The probe runs in a throwaway pod labelled like the Trino coordinator, because
# NetworkPolicy `lakekeeper-ingress` admits the bridge on 8282 to that label only;
# the pod is deleted on exit, including on failure. Nothing is written: the
# bridge answers read-only questions from the catalog's OpenFGA store.
#
# The matrix is exactly the ticket's:
#
#   operation                                dev-finops  dev-analytics  dev-outsider
#   AccessCatalog finance                       true        true          false
#   SelectFromColumns finance.seed.nation       true        true          false
#   InsertIntoTable finance.seed.nation         true        false         false
#   AccessCatalog product                       true        true          false
#   SelectFromColumns product.seed.nation       false       true          false
#   InsertIntoTable product.seed.nation         false       true          false
#   AccessCatalog sandbox                       true        true          true
#   InsertIntoTable sandbox.seed.nation         true        true          true
#   SelectFromColumns warehouse.demo.trips      true        true          true
#
# Exit 1 on any mismatch, so `make verify-catalog-permissions` is a gate.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
BRIDGE_URL="${BRIDGE_URL:-http://lakekeeper-opa:8282/v1/data/trino/allow}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.10.1}"

USERS=(dev-finops dev-analytics dev-outsider)

# operation | catalog | schema | table | columns | finops | analytics | outsider
MATRIX=(
  "AccessCatalog|finance||||true|true|false"
  "SelectFromColumns|finance|seed|nation|n_name|true|true|false"
  "InsertIntoTable|finance|seed|nation||true|false|false"
  "AccessCatalog|product||||true|true|false"
  "SelectFromColumns|product|seed|nation|n_name|false|true|false"
  "InsertIntoTable|product|seed|nation||false|true|false"
  "AccessCatalog|sandbox||||true|true|true"
  "InsertIntoTable|sandbox|seed|nation||true|true|true"
  "SelectFromColumns|warehouse|demo|trips|n_name|true|true|true"
)

CURL=(curl --fail-with-body --silent --show-error --max-time 30)

fail() { echo "verify-catalog-permissions: $*" >&2; exit 1; }

for tool in kubectl curl jq python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify-catalog-permissions: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pod=""
cleanup() {
  keycloak_admin_stop
  [ -z "$pod" ] || kubectl -n "$NAMESPACE" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# The admin API on loopback (scripts/lib/keycloak-admin.sh), for the user ids.
# shellcheck disable=SC2034
KC_LOG_PREFIX=verify-catalog-permissions
# shellcheck source=lib/keycloak-admin.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"

kc() { "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$@"; }

# 1. The three people, by the id the bridge resolves to `oidc~<id>`.
declare -A sub_by_user=()
for user in "${USERS[@]}"; do
  sub="$(kc --get --data-urlencode "username=$user" --data-urlencode 'exact=true' "$API/users" \
    | jq -r '.[0].id // ""')"
  [ -n "$sub" ] || fail "no user $user in realm $REALM — run 'make seed-dev-access YES=1' first"
  sub_by_user[$user]="$sub"
done

# 2. One throwaway pod, labelled like the coordinator so the NetworkPolicy admits
#    the bridge. It stays for the whole table and is deleted by the trap.
pod="qa-catalog-permissions-$RANDOM"
kubectl -n "$NAMESPACE" run "$pod" --image="$PROBE_IMAGE" --restart=Never \
  --labels='app.kubernetes.io/name=trino,app.kubernetes.io/component=coordinator' \
  --command -- sleep 600 >/dev/null \
  || fail "cannot start the probe pod"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null \
  || fail "the probe pod never became ready"

# 3. Ask the bridge one question and print its verdict.
probe() {  # probe <operation> <catalog> <schema> <table> <columns> <user-id>
  local body answer
  body="$(python3 - "$@" <<'PY'
import json, sys
operation, catalog, schema, table, columns, user = sys.argv[1:7]
if operation == "AccessCatalog":
    resource = {"catalog": {"name": catalog}}
else:
    resource = {"table": {"catalogName": catalog, "schemaName": schema, "tableName": table}}
    if columns:
        resource["table"]["columns"] = columns.split(",")
print(json.dumps({"input": {"context": {"identity": {"user": user, "groups": []}},
                            "action": {"operation": operation, "resource": resource}}}))
PY
)"
  answer="$(kubectl -n "$NAMESPACE" exec -i "$pod" -- \
    curl -sS --max-time 15 -X POST "$BRIDGE_URL" -H 'Content-Type: application/json' -d @- <<<"$body")" \
    || fail "the bridge did not answer a $1 question"
  printf '%s' "$answer" | jq -e '.result != null' >/dev/null 2>&1 \
    || fail "the bridge answered '$answer' instead of {\"result\": …}"
  printf '%s' "$answer" | jq -r '.result'
}

# 4. The table, row by row and person by person.
label() {  # what a human calls the row
  local operation="$1" catalog="$2" schema="$3" table="$4"
  case "$operation" in
    AccessCatalog) printf 'AccessCatalog %s' "$catalog" ;;
    *) printf '%s %s.%s.%s' "$operation" "$catalog" "$schema" "$table" ;;
  esac
}

printf '%-42s %-13s %-13s %-13s\n' "operation" "${USERS[@]}"
failures=0
for row in "${MATRIX[@]}"; do
  IFS='|' read -r operation catalog schema table columns expected_finops expected_analytics expected_outsider <<<"$row"
  expected=("$expected_finops" "$expected_analytics" "$expected_outsider")
  printf '%-42s' "$(label "$operation" "$catalog" "$schema" "$table")"
  for index in 0 1 2; do
    user="${USERS[$index]}"
    actual="$(probe "$operation" "$catalog" "$schema" "$table" "$columns" "${sub_by_user[$user]}")"
    if [ "$actual" = "${expected[$index]}" ]; then
      printf ' %-13s' PASS
    else
      printf ' %-13s' "FAIL(want ${expected[$index]})"
      failures=$((failures + 1))
    fi
  done
  printf '\n'
done

if [ "$failures" -ne 0 ]; then
  fail "$failures matrix cell(s) disagree with the grants — see the table above"
fi
echo ""
echo "verify-catalog-permissions: OK — all ${#MATRIX[@]} rows PASS for ${USERS[*]}"
