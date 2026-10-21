#!/usr/bin/env bash
# The permission probe: what each person may do with each catalog, proved
# against the OPA bridge (authz 7/8, stardelt-platform#309; live oracle, #365).
#
#   make verify-catalog-permissions
#
# Asks the bridge the same questions Trino asks it after the switch: for each
# Catalog in the namespace, each of the four data verbs (`browse`, `select`,
# `write`, `create`) and each person (`dev-finops`, `dev-analytics`,
# `dev-outsider` — the users `make seed-dev-access` creates — plus one member of
# `stardelt-admins`), `POST http://lakekeeper-opa:8282/v1/data/trino/allow` with
# the person's Keycloak user id as `context.identity.user` (the bridge prefixes
# `oidc~`, which is how access-sync writes role assignees) and the
# operation/resource Trino sends for that statement.
#
# The expectation is NOT a table in this script: it is computed from the live
# Catalog objects and the live group memberships (scripts/lib/catalog-layout.py).
# A person may do a verb when the union of the verbs granted to their groups
# holds it — `write ⇒ select ⇒ browse`, `create ⇒ browse` — and a member of
# `stardelt-admins` may do everything. Ownership is not a data verb. Edit a grant
# in Nova and the next run follows it; no script change.
#
# The question shapes:
#
#   browse  AccessCatalog        <catalog>
#   select  SelectFromColumns    <catalog>.seed.nation
#   write   InsertIntoTable      <catalog>.seed.nation
#   create  CreateSchema         <catalog>.seed_probe
#
# A table question on a table Lakekeeper does not have is answered `false` for
# everyone (`error-on-not-found: false`), which would read as a permission
# denial. So `select`/`write` rows are asked only where `<catalog>.seed.nation`
# exists — `make seed-permission-fixtures YES=1` creates it in finance, product
# and sandbox. The existence check is the admin's own `SelectFromColumns`: an
# admin holds `project_admin`, so `false` can only mean the table is absent.
# Elsewhere only `browse` and `create` rows are asked. On the maintainer layout
# all grants are uniform, the persons are equal, and the oracle says so.
#
# Only Ready Catalogs are asked about: a Catalog that is not Ready is not in the
# bridge's mapping, and `allowUnmanagedCatalogs` would answer `true` regardless
# of its grants.
#
# The probe runs in a throwaway pod labelled like the Trino coordinator, because
# NetworkPolicy `lakekeeper-ingress` admits the bridge on 8282 to that label only;
# the pod is deleted on exit, including on failure. Nothing is written: the
# bridge answers read-only questions from the catalog's OpenFGA store.
#
# Exit 1 on any mismatch, so `make verify-catalog-permissions` is a gate.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
BRIDGE_URL="${BRIDGE_URL:-http://lakekeeper-opa:8282/v1/data/trino/allow}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.10.1}"

USERS=(dev-finops dev-analytics dev-outsider)
ADMIN_GROUP=stardelt-admins
ADMIN_NAME="admin"
VERBS=(browse select write create)
SEED_SCHEMA=seed
SEED_TABLE=nation

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

# The admin API on loopback (scripts/lib/keycloak-admin.sh), for the user ids and
# the group memberships the oracle needs.
# shellcheck disable=SC2034
KC_LOG_PREFIX=verify-catalog-permissions
# shellcheck source=lib/keycloak-admin.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"

kc() { "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$@"; }

# 1. The people: the three seed users and one member of the admin group, each
#    with the Keycloak groups the expectation is computed from.
declare -A SUB=()
person_jsonl="$tmp/principals.jsonl"
: >"$person_jsonl"
add_person() {  # add_person <name> <keycloak-id>
  local person="$1" sub="$2" groups
  [ -n "$sub" ] || fail "no user $person in realm $REALM — run 'make seed-dev-access YES=1' first"
  groups="$(kc "$API/users/$sub/groups" | jq -c '[.[].name]')" \
    || fail "cannot read the groups of $person"
  SUB[$person]="$sub"
  jq -cn --arg name "$person" --arg sub "$sub" --argjson groups "$groups" \
    '{name: $name, sub: $sub, groups: $groups}' >>"$person_jsonl"
}

for user in "${USERS[@]}"; do
  sub="$(kc --get --data-urlencode "username=$user" --data-urlencode 'exact=true' "$API/users" \
    | jq -r '.[0].id // ""')"
  add_person "$user" "$sub"
done

admin_group="$(kc --get --data-urlencode "search=$ADMIN_GROUP" "$API/groups" \
  | jq -r --arg name "$ADMIN_GROUP" '[.[] | select(.name == $name)][0].id // ""')"
[ -n "$admin_group" ] || fail "no group $ADMIN_GROUP in realm $REALM"
admin_sub="$(kc "$API/groups/$admin_group/members" | jq -r '.[0].id // ""')"
add_person "$ADMIN_NAME" "$admin_sub"
jq -s '.' "$person_jsonl" >"$tmp/principals.json"

# 2. The live Catalog objects and the expected answer for every cell.
kubectl -n "$NAMESPACE" get catalogs.stardelt.io -o json >"$tmp/catalogs.json" \
  || fail "cannot list Catalogs in namespace $NAMESPACE"
python3 scripts/lib/catalog-layout.py \
  --catalogs "$tmp/catalogs.json" --principals "$tmp/principals.json" >"$tmp/layout.json" \
  || fail "cannot compute the expectations from the live Catalog objects"
mapfile -t catalogs < <(jq -r '.catalogs[].name' "$tmp/layout.json")
[ "${#catalogs[@]}" -gt 0 ] || fail "no Ready Catalog in namespace $NAMESPACE — install the platform first"
skipped_catalogs="$(jq -r '[.skipped[] | "\(.name) (\(.phase))"] | join(", ")' "$tmp/layout.json")"
[ -z "$skipped_catalogs" ] || echo "› not Ready, not asked: $skipped_catalogs"

# 3. One throwaway pod, labelled like the coordinator so the NetworkPolicy admits
#    the bridge. It stays for the whole table and is deleted by the trap.
pod="qa-catalog-permissions-$RANDOM"
kubectl -n "$NAMESPACE" run "$pod" --image="$PROBE_IMAGE" --restart=Never \
  --labels='app.kubernetes.io/name=trino,app.kubernetes.io/component=coordinator' \
  --command -- sleep 600 >/dev/null \
  || fail "cannot start the probe pod"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null \
  || fail "the probe pod never became ready"

# 4. Ask the bridge one question and print its verdict.
probe() {  # probe <operation> <catalog> <schema> <table> <columns> <user-id>
  local body answer
  body="$(python3 - "$@" <<'PY'
import json, sys
operation, catalog, schema, table, columns, user = sys.argv[1:7]
if operation == "AccessCatalog":
    resource = {"catalog": {"name": catalog}}
elif operation == "CreateSchema":
    resource = {"schema": {"catalogName": catalog, "schemaName": schema, "properties": {}}}
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

# 5. Which catalogs have the table the table-level verbs are asked on.
declare -A table_exists=()
for catalog in "${catalogs[@]}"; do
  answer="$(probe SelectFromColumns "$catalog" "$SEED_SCHEMA" "$SEED_TABLE" n_name "${SUB[$ADMIN_NAME]}")"
  if [ "$answer" = true ]; then
    table_exists[$catalog]=1
  else
    table_exists[$catalog]=0
  fi
done

# 6. The table, one row per (catalog, verb), one column per person. A cell is
#    `PASS` when the bridge allows what the grants allow, `PASS(no)` for a denial
#    the grants require, and `FAIL(want …)` for a mismatch.
printf '%-24s %-8s' "catalog" "verb"
for person in "${USERS[@]}" "$ADMIN_NAME"; do printf ' %-17s' "$person"; done
printf '\n'
failures=0
rows=0
skipped=()
for catalog in "${catalogs[@]}"; do
  for verb in "${VERBS[@]}"; do
    if { [ "$verb" = select ] || [ "$verb" = write ]; } && [ "${table_exists[$catalog]}" != 1 ]; then
      continue
    fi
    case "$verb" in
      browse) operation=AccessCatalog; schema=""; table=""; columns="" ;;
      select) operation=SelectFromColumns; schema="$SEED_SCHEMA"; table="$SEED_TABLE"; columns=n_name ;;
      write) operation=InsertIntoTable; schema="$SEED_SCHEMA"; table="$SEED_TABLE"; columns="" ;;
      create) operation=CreateSchema; schema=seed_probe; table=""; columns="" ;;
    esac
    printf '%-24s %-8s' "$catalog" "$verb"
    for person in "${USERS[@]}" "$ADMIN_NAME"; do
      expected="$(jq -r --arg catalog "$catalog" --arg verb "$verb" --arg person "$person" \
        '.catalogs[] | select(.name == $catalog) | .expect[$person][$verb]' "$tmp/layout.json")"
      [ -n "$expected" ] || fail "no expectation for $person/$catalog/$verb — the layout is incomplete"
      actual="$(probe "$operation" "$catalog" "$schema" "$table" "$columns" "${SUB[$person]}")"
      if [ "$actual" = "$expected" ]; then
        if [ "$actual" = true ]; then
          printf ' %-17s' PASS
        else
          printf ' %-17s' "PASS(no)"
        fi
      else
        printf ' %-17s' "FAIL(want $expected)"
        failures=$((failures + 1))
      fi
    done
    printf '\n'
    rows=$((rows + 1))
  done
done

for catalog in "${catalogs[@]}"; do
  if [ "${table_exists[$catalog]}" != 1 ]; then
    skipped+=("$catalog")
  fi
done
if [ "${#skipped[@]}" -gt 0 ]; then
  echo ""
  echo "› select/write not asked on ${skipped[*]}: no <catalog>.$SEED_SCHEMA.$SEED_TABLE"
  echo "  (a table question on an absent table is false for everyone — 'make seed-permission-fixtures YES=1'"
  echo "   creates it in finance, product and sandbox)"
fi

if [ "$failures" -ne 0 ]; then
  fail "$failures cell(s) disagree with the live Catalog grants — see the table above"
fi
echo ""
echo "verify-catalog-permissions: OK — $rows row(s) PASS for ${USERS[*]} $ADMIN_NAME;"
echo "  expectations computed from the live Catalog objects and Keycloak memberships"
