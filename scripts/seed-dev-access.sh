#!/usr/bin/env bash
# The dev seed: groups, people, the baseline layout and the opt-in permission
# fixtures (authz 7/8, stardelt-platform#309; layout platform#365).
#
#   make seed-dev-access YES=1            # groups, people, Secret — no Catalog touched
#   SEED_CATALOGS=1 make seed-dev-access YES=1   # also apply dev/seed/catalogs.yaml
#   make unseed-dev-access YES=1          # delete the seed people, groups and Secret
#   make seed-permission-fixtures YES=1   # opt-in: finance/product/sandbox + seed.nation
#   make unseed-permission-fixtures YES=1 # delete exactly those three Catalogs
#
# The three warehouses (`dev/seed/warehouses.yaml`, platform#313) are part of every
# seed run: `small` (the default class, everybody), `medium` (`finops`), `large`
# (`analytics`). They are `SqlWarehouse` objects, so `kubectl apply` is idempotent and
# a second run changes nothing; the class file only changes when a rendered class
# does, and `unseed` keeps `small` and deletes `medium` and `large`.
#
# The baseline is the maintainer's layout: `warehouse`, `shared`, `bronze`,
# `silver`, `gold`, each granted the four data verbs to `stardelt-users`
# (dev/seed/catalogs.yaml). The seed does NOT apply that file unless
# `SEED_CATALOGS=1`, and it never recreates a Catalog that does not exist without
# it: the Catalog objects belong to whoever runs the cluster, and a deleted one
# may be a decision, not drift.
#
# What every seed run does create is cheap and invisible: the realm groups
# `finops` and `analytics`, the people `dev-finops`, `dev-analytics`,
# `dev-outsider` (all also in `stardelt-users`), the existing user `analyst` in
# `analytics`, Secret `dev-seed-users` with their generated passwords, the three
# warehouses of dev/seed/warehouses.yaml, and one access-sync run so the new
# memberships and classes reach Lakekeeper and Trino now, not on the next
# two-minute tick. That sync writes a Catalog status only when it drifted.
#
# Passwords: generated here, 24 random letters and digits, never printed. They
# live only in Secret `dev-seed-users` (one key per user name). Read one with
#
#   kubectl -n stardelt get secret dev-seed-users -o jsonpath='{.data.dev-finops}' | base64 -d
#
# A second run changes nothing: every group, user, membership, Catalog, schema
# and table is created only when absent, and a user that already exists keeps its
# password. The seed is marked in Keycloak with the attribute
# `stardelt-managed=seed`, which is what `unseed` deletes — it never touches a
# user or group it did not create (`analyst`), and it deletes no Catalog.
#
# The permission fixtures are the old three-catalog matrix (finance, product,
# sandbox) with different grants per group, plus the `seed.nation` table (25 rows
# with the old TPCH nation columns, built from `sequence(1, 25)` and no catalog
# read — `tpch` is administrator-only since platform#363) in each: for people who
# want to exercise group differences. They need the seed's people and groups, so
# run `make seed-dev-access YES=1` first; `unseed-permission-fixtures` deletes
# exactly the three Catalogs and never a baseline one. Deleting a Catalog deletes
# no data, so the seed schema stays in the fixture warehouses (orphan warehouses
# to the next sync tick).
#
# Refuses when ConfigMap `stardelt-identity` says `environment: production`: a
# seed of fake people and open catalogs is a development aid, not an install
# step. Every mutating mode needs YES=1.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
YES="${YES:-0}"
SEED_CATALOGS="${SEED_CATALOGS:-0}"

SEED_GROUPS=(finops analytics)
SEED_USERS=(dev-finops dev-analytics dev-outsider)
DEFAULT_GROUP=stardelt-users
SEED_ATTRIBUTE=stardelt-managed
SEED_VALUE=seed
SEED_SECRET=dev-seed-users
CATALOGS_FILE=dev/seed/catalogs.yaml
BASELINE_CATALOGS=(warehouse shared bronze silver gold)
# The seed's three compute classes (platform#313). `small` is the default one and
# stays after `unseed`: the default class is a property of the install, the other
# two are the seed's differentiators.
WAREHOUSES_FILE=dev/seed/warehouses.yaml
SEED_WAREHOUSES=(small medium large)
UNSEED_WAREHOUSES=(medium large)
FIXTURES_FILE=dev/seed/fixtures/permission-fixtures.yaml
FIXTURES_CATALOGS=(finance product sandbox)
SEED_SCHEMA=seed
SEED_TABLE=nation

CURL=(curl --fail-with-body --silent --show-error --max-time 30)

fail() { echo "seed-dev-access: $*" >&2; exit 1; }

mode=seed
case "${1:-}" in
  "") ;;
  --unseed) mode=unseed ;;
  --fixtures) mode=fixtures ;;
  --unseed-fixtures) mode=unseed-fixtures ;;
  *) fail "unexpected argument '$1' (accepted: --unseed, --fixtures, --unseed-fixtures)" ;;
esac

for tool in kubectl curl jq python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "seed-dev-access: $tool not found" >&2; exit 1; }
done

# The production guard runs before the credential guards: on a production
# cluster the answer is "no", whatever YES says.
environment="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath='{.data.environment}' 2>/dev/null || true)"
[ "$environment" != production ] \
  || fail "refusing: ConfigMap $NAMESPACE/stardelt-identity says environment=production — the dev seed is not for this cluster"

if [ "$YES" != 1 ]; then
  case "$mode" in
    unseed)
      echo "would delete the seed users and groups (attribute $SEED_ATTRIBUTE=$SEED_VALUE), the warehouses ${UNSEED_WAREHOUSES[*]} (keeping small) and Secret $NAMESPACE/$SEED_SECRET (no Catalog is deleted) — re-run with YES=1" ;;
    fixtures)
      echo "would apply $FIXTURES_FILE (Catalogs ${FIXTURES_CATALOGS[*]}) and create $SEED_SCHEMA.$SEED_TABLE in them — re-run with YES=1" ;;
    unseed-fixtures)
      echo "would delete the Catalogs ${FIXTURES_CATALOGS[*]} (never a baseline one) — re-run with YES=1" ;;
    *)
      if [ "$SEED_CATALOGS" = 1 ]; then
        echo "would create the groups ${SEED_GROUPS[*]}, the users ${SEED_USERS[*]}, Secret $NAMESPACE/$SEED_SECRET, apply $WAREHOUSES_FILE (${SEED_WAREHOUSES[*]}) and $CATALOGS_FILE (SEED_CATALOGS=1) — re-run with YES=1"
      else
        echo "would create the groups ${SEED_GROUPS[*]}, the users ${SEED_USERS[*]}, Secret $NAMESPACE/$SEED_SECRET and apply $WAREHOUSES_FILE (${SEED_WAREHOUSES[*]}); no Catalog would be touched (set SEED_CATALOGS=1 to apply $CATALOGS_FILE) — re-run with YES=1"
      fi ;;
  esac
  exit 1
fi

umask 077
tmp="$(mktemp -d)"
cleanup() {
  # `unseed-fixtures` never sources the Keycloak helper, so the function is
  # not defined in every mode.
  if declare -F keycloak_admin_stop >/dev/null; then keycloak_admin_stop; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# unseed-fixtures — no Keycloak needed: delete exactly the fixture Catalogs,
# then converge Trino and the bridge so they forget the removed names.
# ---------------------------------------------------------------------------
converge_catalogs() {
  NAMESPACE="$NAMESPACE" make --no-print-directory catalogs
  # `make catalogs` rolls the coordinator and the worker when the catalog set
  # changed, and Helm's --wait returns before the worker listens again: a
  # statement in that window dies with "too many errors talking to a worker
  # node". Wait for both.
  for deployment in trino-coordinator trino-worker; do
    kubectl -n "$NAMESPACE" rollout status "deploy/$deployment" --timeout=5m >/dev/null \
      || fail "Trino deployment $deployment did not become ready"
  done
}

report_catalog_phases() {
  local phases
  phases="$(kubectl -n "$NAMESPACE" get catalogs.stardelt.io -o json \
    | jq -r '[.items[] | "\(.metadata.name) \(.status.phase // "Pending")"] | join(", ")')"
  echo "› catalogs: $phases"
}

if [ "$mode" = unseed-fixtures ]; then
  kubectl -n "$NAMESPACE" delete catalog "${FIXTURES_CATALOGS[@]}" --ignore-not-found \
    || fail "cannot delete the fixture Catalogs ${FIXTURES_CATALOGS[*]}"
  converge_catalogs
  report_catalog_phases
  echo "› kept: the baseline Catalogs, every Lakekeeper warehouse and the $SEED_SCHEMA schema"
  echo "  with its $SEED_TABLE tables — deleting a Catalog deletes no data."
  echo "seed-dev-access: OK — the permission fixtures ${FIXTURES_CATALOGS[*]} are gone"
  exit 0
fi

# 1. The admin API on loopback: port-forward, forwarded headers, master token and
#    the realm check (scripts/lib/keycloak-admin.sh). Leaves KC/HEAD/AUTH/API.
# shellcheck disable=SC2034
KC_LOG_PREFIX=seed-dev-access
# shellcheck source=lib/keycloak-admin.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"

kc() { "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$@"; }

# The groups the matrix is about, by name -> id. One read, every mode uses it.
groups_json="$tmp/groups.json"
kc --get --data-urlencode 'max=500' --data-urlencode 'briefRepresentation=false' "$API/groups" >"$groups_json" \
  || fail "cannot list the groups of realm $REALM"

group_id() { jq -r --arg name "$1" 'map(select(.name == $name))[0].id // ""' "$groups_json"; }

# The users carrying the seed attribute, with the id each probe needs.
seed_users_json() {
  kc --get --data-urlencode 'max=1000' --data-urlencode 'briefRepresentation=false' "$API/users" \
    | jq --arg attr "$SEED_ATTRIBUTE" --arg value "$SEED_VALUE" \
        'map(select((.attributes // {})[$attr] // [] | index($value)))'
}

user_id() { # user_id <username> -> the Keycloak id, empty when absent
  kc --get --data-urlencode "username=$1" --data-urlencode 'exact=true' "$API/users" \
    | jq -r '.[0].id // ""'
}

# ---------------------------------------------------------------------------
# unseed — the people, their groups and the Secret. The Catalogs stay: the
# baseline is the maintainer's layout and the fixtures have their own target.
# ---------------------------------------------------------------------------
if [ "$mode" = unseed ]; then
  users="$(seed_users_json)"
  count="$(printf '%s' "$users" | jq 'length')"
  if [ "$count" = 0 ]; then
    echo "› seed users: none"
  else
    printf '%s' "$users" | jq -r '.[] | "\(.id)\t\(.username)"' | while IFS=$'\t' read -r id username; do
      kc -X DELETE "$API/users/$id" >/dev/null || fail "Keycloak refused to delete user $username"
      echo "› user $username: deleted"
    done
  fi

  # Groups by the same attribute, so a group a person made and named `finops` is
  # reported and left alone instead of being deleted under them.
  seed_groups="$(jq --arg attr "$SEED_ATTRIBUTE" --arg value "$SEED_VALUE" \
    'map(select((.attributes // {})[$attr] // [] | index($value)))' "$groups_json")"
  if [ "$(printf '%s' "$seed_groups" | jq 'length')" = 0 ]; then
    echo "› seed groups: none"
  else
    printf '%s' "$seed_groups" | jq -r '.[] | "\(.id)\t\(.name)"' \
      | while IFS=$'\t' read -r id name; do
          kc -X DELETE "$API/groups/$id" >/dev/null || fail "Keycloak refused to delete group $name"
          echo "› group $name: deleted"
        done
  fi

  # The seed's differentiator classes (platform#313). `small` stays: it is the default
  # class of the install (a principal that matches no group lands there), the two
  # others only exist for the seed's people.
  for warehouse in "${UNSEED_WAREHOUSES[@]}"; do
    kubectl -n "$NAMESPACE" delete sqlwarehouse "$warehouse" --ignore-not-found >/dev/null \
      || fail "cannot delete SqlWarehouse $warehouse"
    echo "› warehouse $warehouse: deleted (small kept — it is the default class)"
  done

  kubectl -n "$NAMESPACE" delete secret "$SEED_SECRET" --ignore-not-found >/dev/null \
    || fail "cannot delete Secret $NAMESPACE/$SEED_SECRET"
  echo "› secret $NAMESPACE/$SEED_SECRET: deleted (its passwords belonged to deleted users)"

  # The removed objects reach the engine through the next tick; run one now so the
  # rendered file is up to date when this script returns. A changed resource-group file
  # restarts the coordinator (it loads the file once, platform#313) — the restart drops
  # running queries, so it is not awaited here, only reported.
  if kubectl -n "$NAMESPACE" get cronjob access-sync >/dev/null 2>&1; then
    NAMESPACE="$NAMESPACE" make --no-print-directory access-sync-now
    echo "› coordinator: restarts when the rendered class file changed (running queries end)"
    echo "  watch it with: kubectl -n $NAMESPACE rollout status deploy/trino-coordinator"
  else
    echo "› warehouses: CronJob access-sync is not installed here, so the rendered classes"
    echo "  follow with the next engine install"
  fi

  echo "› kept: the default warehouse small, every Catalog (the baseline ${BASELINE_CATALOGS[*]}, and the fixtures if applied),"
  echo "  every Lakekeeper warehouse and every table — deleting a Catalog deletes no data anyway."
  echo "  The existing user analyst is not a seed object and is left alone."
  echo "seed-dev-access: OK — the dev seed people are gone"
  exit 0
fi

# ---------------------------------------------------------------------------
# fixtures — the opt-in three catalogs. They reference the seed's groups and
# the probe asks as the seed's people, so both must already exist.
# ---------------------------------------------------------------------------
if [ "$mode" = fixtures ]; then
  missing=()
  for group in "${SEED_GROUPS[@]}"; do
    [ -n "$(group_id "$group")" ] || missing+=("group $group")
  done
  for user in "${SEED_USERS[@]}"; do
    [ -n "$(user_id "$user")" ] || missing+=("user $user")
  done
  [ "${#missing[@]}" -eq 0 ] \
    || fail "the permission fixtures need the dev seed's people and groups (missing: ${missing[*]}) — run 'make seed-dev-access YES=1' first"

  [ -f "$FIXTURES_FILE" ] || fail "$FIXTURES_FILE is missing"
  kubectl apply -f "$FIXTURES_FILE"
  converge_catalogs

  # The data the probe reads: schema `seed`, table `nation` (25 rows with the
  # TPCH nation columns) in every fixture catalog, through the Trino service
  # account. The rows come from `sequence(1, 25)`, not from `tpch.tiny.nation`:
  # the engine's sample catalogs are administrator-only since platform#363, and
  # the service account is not an administrator.
  kubectl -n "$NAMESPACE" get secret trino-password-db -o jsonpath='{.data.superset-password}' | base64 -d >"$tmp/superset-pw"
  [ -s "$tmp/superset-pw" ] || fail "Secret $NAMESPACE/trino-password-db has no superset-password — run 'make install-identity'"

  public_url="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath='{.data.publicUrl}' 2>/dev/null || true)"
  TRINO_URL="${TRINO_URL:-https://trino.${public_url#https://}}"
  [ -n "${TRINO_URL#https://trino.}" ] || TRINO_URL="https://trino.alpha.dev.stardelt.io"

  # Runs one statement as `superset` and prints its rows as JSON.
  trino_statement() {
    python3 - "$TRINO_URL" "$tmp/superset-pw" "$1" <<'PY'
import base64, json, sys, urllib.error, urllib.request
url, password_file, sql = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
password = open(password_file).read().strip()
auth = "Basic " + base64.b64encode(("superset:" + password).encode()).decode()
headers = {"Authorization": auth, "Content-Type": "text/plain"}


def call(endpoint, data=None):
    request = urllib.request.Request(endpoint, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit("HTTP %s from Trino: %s" % (error.code, error.read().decode()[:300]))


body = call(url + "/v1/statement", sql.encode())
rows = list(body.get("data") or [])
while True:
    if body.get("error"):
        sys.exit("Trino: " + str(body["error"].get("message", ""))[:300])
    if not body.get("nextUri"):
        break
    body = call(body["nextUri"])
    rows.extend(body.get("data") or [])
print(json.dumps(rows))
PY
  }

  # Runs a statement, retrying a window in which a Trino pod is still coming back.
  trino_retry() {  # trino_retry <sql>
    local attempt=1 output
    while :; do
      if output="$(trino_statement "$1")"; then
        printf '%s' "$output"
        return 0
      fi
      if [ "$attempt" -ge 6 ]; then
        fail "Trino refused this statement 6 times — the last error is above: $1"
      fi
      attempt=$((attempt + 1))
      sleep 10
    done
  }

  for catalog in "${FIXTURES_CATALOGS[@]}"; do
    trino_retry "CREATE SCHEMA IF NOT EXISTS $catalog.$SEED_SCHEMA" >/dev/null
    trino_retry "CREATE TABLE IF NOT EXISTS $catalog.$SEED_SCHEMA.$SEED_TABLE AS
SELECT nationkey, 'nation-' || CAST(nationkey AS varchar) AS name,
       nationkey % 5 AS regionkey, CAST('seed row' AS varchar) AS comment
FROM UNNEST(sequence(0, 24)) AS t(nationkey)" >/dev/null
    rows="$(trino_retry "SELECT count(*) AS rows FROM $catalog.$SEED_SCHEMA.$SEED_TABLE")"
    count="$(printf '%s' "$rows" | jq -r '.[0][0] // ""')"
    [ "$count" = 25 ] || fail "$catalog.$SEED_SCHEMA.$SEED_TABLE has $rows rows, expected 25"
    echo "› table $catalog.$SEED_SCHEMA.$SEED_TABLE: 25 rows"
  done

  report_catalog_phases
  echo ""
  echo "seed-dev-access: OK — permission fixtures ${FIXTURES_CATALOGS[*]} with differentiated grants"
  echo "  the baseline Catalogs are untouched; the marker $SEED_ATTRIBUTE=$SEED_VALUE applies to Keycloak only"
  echo "  prove the live objects: make verify-catalog-permissions"
  echo "  remove them: make unseed-permission-fixtures YES=1"
  exit 0
fi

# ---------------------------------------------------------------------------
# seed — 1. groups
# ---------------------------------------------------------------------------
for group in "${SEED_GROUPS[@]}"; do
  if [ -n "$(group_id "$group")" ]; then
    echo "› group $group: exists"
    continue
  fi
  printf '{"name":"%s","attributes":{"%s":["%s"]}}' "$group" "$SEED_ATTRIBUTE" "$SEED_VALUE" >"$tmp/group-$group.json"
  kc -H 'Content-Type: application/json' -X POST --data @"$tmp/group-$group.json" "$API/groups" >/dev/null \
    || fail "Keycloak refused to create group $group"
  echo "› group $group: created"
  kc --get --data-urlencode 'max=500' --data-urlencode 'briefRepresentation=false' "$API/groups" >"$groups_json"
done

default_group_id="$(group_id "$DEFAULT_GROUP")"
[ -n "$default_group_id" ] || fail "realm $REALM has no group $DEFAULT_GROUP — the realm import is incomplete"

# ---------------------------------------------------------------------------
# seed — 2. the Secret is the only copy of a password
# ---------------------------------------------------------------------------
mkdir -p "$tmp/secret"
if kubectl -n "$NAMESPACE" get secret "$SEED_SECRET" >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" get secret "$SEED_SECRET" -o json \
    | jq -r '.data // {} | to_entries[] | "\(.key)\t\(.value)"' \
    | while IFS=$'\t' read -r key value; do
        printf '%s' "$value" | base64 -d >"$tmp/secret/$key"
      done
  # Every value loaded; a user whose key is missing gets a fresh password below.
  for user in "${SEED_USERS[@]}"; do
    [ -s "$tmp/secret/$user" ] || rm -f "$tmp/secret/$user"
  done
fi

new_password() {
  python3 >"$tmp/secret/$1" <<'PY'
import secrets, string, sys
alphabet = string.ascii_letters + string.digits
sys.stdout.write("".join(secrets.choice(alphabet) for _ in range(24)))
PY
}

# The Secret is written once at the end, with every key it should hold.
apply_seed_secret() {
  [ "$(find "$tmp/secret" -type f | wc -l)" -gt 0 ] || return 0
  local args=()
  local file
  for file in "$tmp/secret"/*; do
    args+=("--from-file=$(basename "$file")=$file")
  done
  kubectl -n "$NAMESPACE" create secret generic "$SEED_SECRET" "${args[@]}" \
    --dry-run=client -o json >"$tmp/secret.json"
  python3 - "$tmp/secret.json" >"$tmp/secret-final.json" <<'PY'
import json, sys
secret = json.load(open(sys.argv[1]))
labels = secret.setdefault("metadata", {}).setdefault("labels", {})
labels["app.kubernetes.io/part-of"] = "stardelt"
labels["stardelt.io/seed"] = "dev-access"
json.dump(secret, sys.stdout)
PY
  kubectl -n "$NAMESPACE" apply -f "$tmp/secret-final.json"
}

# ---------------------------------------------------------------------------
# seed — 3. the three people
# ---------------------------------------------------------------------------
# Keycloak 24+ keeps only the attributes its user profile declares, and on a fresh
# realm an undeclared one is dropped silently (unmanagedAttributePolicy unset) —
# the seed marker would never stick. ADMIN_EDIT is the narrowest policy that lets
# this script (admin API) write it: people still see and edit no extra attribute.
# The realm has no field for it, only the user profile; round-trip that document
# rather than send a partial one (a partial PUT would drop the attribute rules).
kc "$API/users/profile" >"$tmp/user-profile.json" \
  || fail "cannot read the realm's user profile"
profile_policy="$(jq -r '.unmanagedAttributePolicy // ""' "$tmp/user-profile.json")"
if [ "$profile_policy" = ENABLED ] || [ "$profile_policy" = ADMIN_EDIT ]; then
  echo "› realm user profile: unmanaged attributes $profile_policy"
else
  python3 - "$tmp/user-profile.json" >"$tmp/user-profile-updated.json" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
profile["unmanagedAttributePolicy"] = "ADMIN_EDIT"
json.dump(profile, sys.stdout)
PY
  kc -H 'Content-Type: application/json' -X PUT --data @"$tmp/user-profile-updated.json" \
    "$API/users/profile" >/dev/null \
    || fail "Keycloak refused unmanagedAttributePolicy=ADMIN_EDIT on the realm's user profile"
  echo "› realm user profile: unmanaged attributes ADMIN_EDIT (the seed marker needs it)"
fi
# Each seed user is in `stardelt-users` (so the baseline catalogs keep working
# for them) plus its domain group. `dev-outsider` gets no domain: it is the row
# of FALSE in the permission fixtures.
user_groups() {
  case "$1" in
    dev-finops) echo "$DEFAULT_GROUP finops" ;;
    dev-analytics) echo "$DEFAULT_GROUP analytics" ;;
    *) echo "$DEFAULT_GROUP" ;;
  esac
}

for user in "${SEED_USERS[@]}"; do
  uid="$(user_id "$user")"
  if [ -z "$uid" ]; then
    [ -f "$tmp/secret/$user" ] || new_password "$user"
    python3 - "$tmp/secret/$user" "$user" "$SEED_ATTRIBUTE" "$SEED_VALUE" >"$tmp/user-$user.json" <<'PY'
import json, sys
password = open(sys.argv[1]).read()
username, attribute, value = sys.argv[2:]
json.dump({
    "username": username,
    "enabled": True,
    "email": username + "@dev.stardelt.io",
    "emailVerified": True,
    "firstName": "Dev",
    "lastName": username.replace("dev-", "").capitalize(),
    "attributes": {attribute: [value]},
    "requiredActions": [],
    "credentials": [{"type": "password", "value": password, "temporary": False}],
}, sys.stdout)
PY
    kc -H 'Content-Type: application/json' -X POST --data @"$tmp/user-$user.json" "$API/users" >/dev/null \
      || fail "Keycloak refused to create user $user"
    uid="$(user_id "$user")"
    [ -n "$uid" ] || fail "user $user was created but cannot be read back"
    echo "› user $user: created"
  else
    # A user of that name that this seed did not create is somebody's account:
    # never reset its password, never rewrite its attributes.
    managed="$(kc "$API/users/$uid" \
      | jq -r --arg attr "$SEED_ATTRIBUTE" --arg value "$SEED_VALUE" \
          '((.attributes // {})[$attr] // [] | index($value)) // ""')"
    [ -n "$managed" ] \
      || fail "refusing to touch user $user: it exists and does not carry $SEED_ATTRIBUTE=$SEED_VALUE"
    if [ -f "$tmp/secret/$user" ]; then
      echo "› user $user: exists"
    else
      # The user exists but its password is not in the Secret (Secret deleted by
      # hand): set a new one, because the seed owes the matrix a working login.
      new_password "$user"
      python3 - "$tmp/secret/$user" >"$tmp/reset-$user.json" <<'PY'
import json, sys
json.dump({"type": "password", "value": open(sys.argv[1]).read(), "temporary": False}, sys.stdout)
PY
      kc -H 'Content-Type: application/json' -X PUT --data @"$tmp/reset-$user.json" \
        "$API/users/$uid/reset-password" >/dev/null || fail "cannot reset the password of user $user"
      echo "› user $user: exists (password regenerated into Secret $NAMESPACE/$SEED_SECRET)"
    fi
  fi

  # Converge the membership of the declared groups; other memberships stay.
  current="$(kc "$API/users/$uid/groups" | jq -r '.[].name')"
  for group in $(user_groups "$user"); do
    gid="$(group_id "$group")"
    [ -n "$gid" ] || fail "group $group does not exist (created above?)"
    if printf '%s\n' "$current" | grep -qx "$group"; then
      echo "› user $user: member of $group"
    else
      kc -X PUT "$API/users/$uid/groups/$gid" >/dev/null || fail "cannot add user $user to group $group"
      echo "› user $user: added to $group"
    fi
  done
done

# ---------------------------------------------------------------------------
# seed — 4. the existing user `analyst` joins analytics (ADR: the matrix has a
# person whose login predates the seed)
# ---------------------------------------------------------------------------
analyst_id="$(user_id analyst)"
[ -n "$analyst_id" ] || fail "the realm has no user analyst — the realm import is incomplete"
if kc "$API/users/$analyst_id/groups" | jq -r '.[].name' | grep -qx analytics; then
  echo "› existing user analyst: already a member of analytics"
else
  kc -X PUT "$API/users/$analyst_id/groups/$(group_id analytics)" >/dev/null \
    || fail "cannot add user analyst to group analytics"
  echo "› existing user analyst: added to group analytics (an existing person, not a seed user)"
fi

apply_seed_secret

# ---------------------------------------------------------------------------
# seed — 5. the three warehouses (platform#313)
# ---------------------------------------------------------------------------
# `small` is the default class everybody lands in, `medium` is `finops`, `large` is
# `analytics`. The objects, not this script, decide who is in which class: the group
# is the identity the resource-group selectors read. The rendered file follows on the
# next access-sync tick (or the one section 6 runs); the coordinator restarts for it.
[ -f "$WAREHOUSES_FILE" ] || fail "$WAREHOUSES_FILE is missing"
kubectl apply -f "$WAREHOUSES_FILE"

# ---------------------------------------------------------------------------
# seed — 6. the baseline Catalogs, only when asked
# ---------------------------------------------------------------------------
if [ "$SEED_CATALOGS" = 1 ]; then
  [ -f "$CATALOGS_FILE" ] || fail "$CATALOGS_FILE is missing"
  kubectl apply -f "$CATALOGS_FILE"
  converge_catalogs
  report_catalog_phases
else
  # The people and their roles still have to reach Lakekeeper now, not on the
  # next two-minute tick. The sync patches a Catalog status only when it drifted.
  NAMESPACE="$NAMESPACE" make --no-print-directory access-sync-now
  echo "› catalogs: not touched — the baseline layout is the maintainer's (${BASELINE_CATALOGS[*]});"
  echo "  set SEED_CATALOGS=1 to apply $CATALOGS_FILE"
  echo "› warehouses: ${SEED_WAREHOUSES[*]} applied (small is the default class); the coordinator"
  echo "  restarts once when the rendered file changed — kubectl -n $NAMESPACE rollout status deploy/trino-coordinator"
fi

echo ""
echo "seed-dev-access: OK — groups ${SEED_GROUPS[*]}, users ${SEED_USERS[*]}, Secret $NAMESPACE/$SEED_SECRET"
echo "  warehouses: ${SEED_WAREHOUSES[*]} (small is the default class, medium is finops, large is analytics)"
echo "  passwords are only in Secret $NAMESPACE/$SEED_SECRET (one key per user name); read one with:"
echo "    kubectl -n $NAMESPACE get secret $SEED_SECRET -o jsonpath='{.data.dev-finops}' | base64 -d"
echo "  the permissions: make verify-catalog-permissions (expectations from the live Catalog objects)"
if [ "$SEED_CATALOGS" = 1 ]; then
  echo "  the baseline Catalogs ${BASELINE_CATALOGS[*]} were applied from $CATALOGS_FILE"
else
  echo "  no Catalog was created, changed or deleted"
fi
echo "  group differences to exercise: make seed-permission-fixtures YES=1"
echo "  remove the people: make unseed-dev-access YES=1"
