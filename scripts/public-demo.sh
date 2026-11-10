#!/usr/bin/env bash
# The public demo person in one idempotent command (public demo, platform#896).
#
#   make public-demo                       # prints the plan and exits 1
#   make public-demo YES=1                 # converge the person `demo`, its grants and its warehouse
#   make public-demo-off YES=1             # kill switch: disable `demo` and sign it out
#   bash scripts/public-demo.sh --manifest # print the Catalog and SqlWarehouse it applies
#
# A public demo needs somebody to sign in as, and that sign-in is shared: the person
# `demo` with the password `demo` is PUBLIC ON PURPOSE — it is printed by this script and
# it is in this repository, so it protects nothing and is meant to protect nothing. What
# it can reach is the whole of this script: read access to the Catalogs bronze, silver and
# gold, and write access to the playground. Everything else stays closed, because `demo`
# is in the realm group `visitors` only and holds no `default-roles-stardelt` (so it does
# not even get the account console).
#
# In order, and idempotently:
#
#   0.  the Catalogs bronze, silver and gold exist (it never creates a Catalog);
#   0b. the ServicePrincipal pipeline-demo is ready, i.e. `make demo-access YES=1` ran;
#   1.  the realm group `visitors` exists (marked stardelt-managed=public-demo);
#   2.  the person `demo` exists, is enabled, needs no actions and knows the password
#       `demo`; a person `demo` this script did not create is refused;
#   3.  `demo` is a member of `visitors` and of no other group (`stardelt-users` included:
#       the realm's defaultGroups adds every new user to it);
#   4.  `demo` holds no realm role, `default-roles-stardelt` included;
#   5.  the group `visitors` may browse and select bronze, silver and gold;
#   6.  the Catalog `playground` (write for `visitors`) and the SqlWarehouse `demo` (xs);
#   7.  the ConfigMap stardelt-public-demo, which tells Nova that `demo` is shared;
#   8.  one access sync and one catalog convergence (`make catalogs`).
#
# A second run changes nothing and says so per step, except the password reset of step 2.
# The kill switch is `make public-demo-off YES=1`: the person is disabled and signed out,
# and nothing else is deleted.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
YES="${YES:-0}"

GROUP=visitors
PERSON=demo
PASSWORD=demo
OWNER=demo
PUBLIC_CATALOGS=(bronze silver gold)
DEFAULT_GROUP=stardelt-users
DEFAULT_ROLE=default-roles-stardelt
MARK_ATTRIBUTE=stardelt-managed
MARK_VALUE=public-demo
CURL=(curl --fail-with-body --silent --show-error --max-time 30)

fail() { echo "public-demo: $*" >&2; exit 1; }

manifest() {
  cat <<EOF
apiVersion: stardelt.io/v1alpha1
kind: Catalog
metadata: { name: playground, namespace: $NAMESPACE, labels: { stardelt.io/managed-by: public-demo } }
spec:
  lakehouseRef: { name: main }
  displayName: "Playground"
  description: "The public demo's scratch space. Anyone signed in as demo may write here; it is emptied every night at 03:00 UTC."
  owner: $OWNER
  grants:
    - { group: $PERSON, verb: browse }
    - { group: $PERSON, verb: select }
    - { group: $PERSON, verb: write }
    - { group: $PERSON, verb: create }
    - { group: $GROUP, verb: browse }
    - { group: $GROUP, verb: select }
    - { group: $GROUP, verb: write }
    - { group: $GROUP, verb: create }
---
apiVersion: stardelt.io/v1alpha1
kind: SqlWarehouse
metadata: { name: demo, namespace: $NAMESPACE, labels: { stardelt.io/managed-by: public-demo } }
spec:
  lakehouseRef: { name: main }
  displayName: "Public demo"
  size: xs
  concurrency: { running: 2, queued: 10, memoryShare: "10%" }
  grants:
    - { group: $GROUP }
EOF
}

mode=on
case "${1:-}" in
  --manifest) manifest; exit 0 ;;
  --off) mode=off ;;
  "") ;;
  *) fail "unexpected argument '$1' (accepted: --manifest, --off)" ;;
esac

for tool in kubectl curl jq python3 base64 make; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done

umask 077
tmp="$(mktemp -d)"
cleanup() {
  if declare -F keycloak_admin_stop >/dev/null; then keycloak_admin_stop; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# The Keycloak admin API (a port-forward and a token) is opened only when something is
# written, so the plan and the kill switch's own plan need no cluster at all.
start_keycloak() {
  # shellcheck disable=SC2034
  KC_LOG_PREFIX=public-demo
  # shellcheck source=lib/keycloak-admin.sh disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"
}

kc() { "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$@"; }

groups_json="$tmp/groups.json"
read_groups() {
  kc --get --data-urlencode 'max=500' --data-urlencode 'briefRepresentation=false' "$API/groups" >"$groups_json" \
    || fail "cannot list the groups of realm $REALM"
}
group_id() { jq -r --arg name "$1" 'map(select(.name == $name))[0].id // ""' "$groups_json"; }
user_id() { # user_id <username> -> the Keycloak id, empty when absent
  kc --get --data-urlencode "username=$1" --data-urlencode 'exact=true' "$API/users" | jq -r '.[0].id // ""'
}

# The kill switch.
if [ "$mode" = off ]; then
  if [ "$YES" != 1 ]; then
    echo "would: disable demo and sign it out — re-run with YES=1"
    exit 1
  fi
  start_keycloak
  uid="$(user_id "$PERSON")"
  [ -n "$uid" ] || fail "user $PERSON does not exist in realm $REALM"
  printf '{"enabled":false}' >"$tmp/off.json"
  kc -H 'Content-Type: application/json' -X PUT --data @"$tmp/off.json" "$API/users/$uid" >/dev/null \
    || fail "Keycloak refused to disable user $PERSON"
  kc -X POST "$API/users/$uid/logout" >/dev/null || fail "user $PERSON is disabled but Keycloak refused to sign it out"
  echo "public-demo: OFF — demo is disabled and signed out"
  exit 0
fi

# 0. The catalogs the demo may read, before anything is changed.
missing=()
for catalog in "${PUBLIC_CATALOGS[@]}"; do
  kubectl -n "$NAMESPACE" get catalogs.stardelt.io "$catalog" >/dev/null 2>&1 || missing+=("$catalog")
done
[ "${#missing[@]}" -eq 0 ] \
  || fail "the Catalogs ${missing[*]} do not exist in namespace $NAMESPACE; run make public-demo-catalogs YES=1 first (nothing was changed)"
echo "› catalogs ${PUBLIC_CATALOGS[*]}: present"

# 0b. The pipeline principal the demo's catalogs come from.
principal_ready="$(kubectl -n "$NAMESPACE" get serviceprincipals.stardelt.io pipeline-demo -o jsonpath='{.status.ready}' 2>/dev/null || true)"
[ "$principal_ready" = true ] \
  || fail "ServicePrincipal pipeline-demo is not ready in namespace $NAMESPACE; run make demo-access YES=1 first (nothing was changed)"
echo "› ServicePrincipal pipeline-demo: ready"

if [ "$YES" != 1 ]; then
  cat <<EOF
would: create the realm group $GROUP (marked $MARK_ATTRIBUTE=$MARK_VALUE)
would: create the person $PERSON with the password $PASSWORD (public on purpose) and reset it
would: make $PERSON a member of $GROUP and of no other group, $DEFAULT_GROUP included
would: remove the realm role $DEFAULT_ROLE from $PERSON
would: grant $GROUP browse and select on ${PUBLIC_CATALOGS[*]}
would: apply the Catalog playground and the SqlWarehouse demo (xs)
would: create the ConfigMap stardelt-public-demo (sharedAccounts=$PERSON) and restart Nova if it is new
would: run one access sync and converge the catalogs (make catalogs)
EOF
  echo "WARNING: EVERY SCHEMA IN bronze, silver AND gold BECOMES READABLE BY ANYONE ON THE INTERNET"
  echo "public-demo: nothing was changed — re-run with YES=1"
  exit 1
fi

start_keycloak

# 1. The group.
read_groups
if [ -n "$(group_id "$GROUP")" ]; then
  echo "› group $GROUP: unchanged — exists"
else
  printf '{"name":"%s","attributes":{"%s":["%s"]}}' "$GROUP" "$MARK_ATTRIBUTE" "$MARK_VALUE" >"$tmp/group.json"
  kc -H 'Content-Type: application/json' -X POST --data @"$tmp/group.json" "$API/groups" >/dev/null \
    || fail "Keycloak refused to create group $GROUP"
  echo "› group $GROUP: created"
  read_groups
fi
gid="$(group_id "$GROUP")"
[ -n "$gid" ] || fail "group $GROUP is not in the realm after creating it"

# 2. The person. It belongs to this script: a `demo` without the mark is somebody else's.
user_json="$tmp/user.json"
kc --get --data-urlencode "username=$PERSON" --data-urlencode 'exact=true' "$API/users" >"$user_json" \
  || fail "cannot look for user $PERSON in realm $REALM"
uid="$(jq -r '.[0].id // ""' "$user_json")"
if [ -z "$uid" ]; then
  printf '{"username":"%s","enabled":true,"emailVerified":true,"email":"demo@example.invalid","firstName":"Demo","lastName":"Visitor","requiredActions":[],"attributes":{"%s":["%s"]}}' \
    "$PERSON" "$MARK_ATTRIBUTE" "$MARK_VALUE" >"$tmp/create-user.json"
  kc -H 'Content-Type: application/json' -X POST --data @"$tmp/create-user.json" "$API/users" >/dev/null \
    || fail "Keycloak refused to create user $PERSON"
  uid="$(kc --get --data-urlencode "username=$PERSON" --data-urlencode 'exact=true' "$API/users" | jq -r '.[0].id // ""')"
  [ -n "$uid" ] || fail "user $PERSON is not in the realm after creating it"
  echo "› user $PERSON: created"
else
  mark="$(jq -r --arg a "$MARK_ATTRIBUTE" '(.[0].attributes // {})[$a] // [] | join(",")' "$user_json")"
  [ "$mark" = "$MARK_VALUE" ] || fail "a user $PERSON exists that this script did not create (no $MARK_ATTRIBUTE=$MARK_VALUE); nothing was changed"
  echo "› user $PERSON: unchanged — exists"
fi
printf '{"enabled":true,"requiredActions":[]}' >"$tmp/enable.json"
kc -H 'Content-Type: application/json' -X PUT --data @"$tmp/enable.json" "$API/users/$uid" >/dev/null \
  || fail "Keycloak refused to enable user $PERSON"
printf '{"type":"password","value":"%s","temporary":false}' "$PASSWORD" >"$tmp/password.json"
kc -H 'Content-Type: application/json' -X PUT --data @"$tmp/password.json" "$API/users/$uid/reset-password" >/dev/null \
  || fail "Keycloak refused to set the password of user $PERSON"
kc -X DELETE "$API/attack-detection/brute-force/users/$uid" >/dev/null \
  || fail "Keycloak refused to clear the brute-force lock of user $PERSON"
echo "  password of $PERSON reset (public on purpose)"

# 3. Group memberships: in $GROUP, in nothing else (defaultGroups adds new users to $DEFAULT_GROUP).
current_json="$tmp/memberships.json"
kc "$API/users/$uid/groups" >"$current_json" || fail "cannot read the groups of user $PERSON"
in_group=0
left=""
while read -r other_id other_name; do
  [ -n "$other_name" ] || continue
  if [ "$other_name" = "$GROUP" ]; then
    in_group=1
    continue
  fi
  kc -X DELETE "$API/users/$uid/groups/$other_id" >/dev/null || fail "cannot remove user $PERSON from group $other_name"
  left="$left $other_name"
done < <(jq -r '.[] | "\(.id) \(.name)"' "$current_json")
if [ "$in_group" -eq 1 ] && [ -z "$left" ]; then
  echo "› groups of $PERSON: unchanged — in $GROUP only"
else
  if [ "$in_group" -eq 0 ]; then
    kc -X PUT "$API/users/$uid/groups/$gid" >/dev/null || fail "cannot add user $PERSON to group $GROUP"
  fi
  echo "› groups of $PERSON: changed — in $GROUP${left:+, left$left}"
fi

# 4. Realm roles: none, $DEFAULT_ROLE included (it is what shows the account console).
roles_json="$tmp/roles.json"
kc "$API/users/$uid/role-mappings/realm" >"$roles_json" || fail "cannot read the realm roles of user $PERSON"
if jq -e --arg role "$DEFAULT_ROLE" 'any(.[]; .name == $role)' "$roles_json" >/dev/null; then
  jq -c --arg role "$DEFAULT_ROLE" '[.[] | select(.name == $role)]' "$roles_json" >"$tmp/role.json"
  kc -H 'Content-Type: application/json' -X DELETE --data @"$tmp/role.json" "$API/users/$uid/role-mappings/realm" >/dev/null \
    || fail "cannot remove the realm role $DEFAULT_ROLE from user $PERSON"
  echo "› realm role $DEFAULT_ROLE: removed"
else
  echo "› realm role $DEFAULT_ROLE: unchanged — not held"
fi

# 5. Read access to the public catalogs, one group grant per verb.
for catalog in "${PUBLIC_CATALOGS[@]}"; do
  added=()
  for verb in browse select; do
    if kubectl -n "$NAMESPACE" get catalogs.stardelt.io "$catalog" -o json \
      | jq -e --arg group "$GROUP" --arg verb "$verb" 'any(.spec.grants[]?; .group == $group and .verb == $verb)' >/dev/null; then
      continue
    fi
    kubectl -n "$NAMESPACE" patch catalogs.stardelt.io "$catalog" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/grants/-\",\"value\":{\"group\":\"$GROUP\",\"verb\":\"$verb\"}}]" >/dev/null \
      || fail "cannot add the grant $GROUP/$verb to Catalog $catalog"
    added+=("$GROUP/$verb")
  done
  if [ "${#added[@]}" -eq 0 ]; then
    echo "› catalog $catalog: unchanged — $GROUP may browse and select"
  else
    echo "› catalog $catalog: changed — added ${added[*]}"
  fi
done

# 6. The playground and the warehouse.
apply_out="$(manifest | kubectl -n "$NAMESPACE" apply -f -)" || fail "cannot apply the playground Catalog and the SqlWarehouse demo"
state=changed
if printf '%s\n' "$apply_out" | grep -q ' unchanged$'; then state=unchanged; fi
if printf '%s\n' "$apply_out" | grep -q ' created$'; then state=created; fi
echo "› Catalog playground and SqlWarehouse demo: $state"

# 7. What tells Nova that the account is shared.
configmap_existed=0
if kubectl -n "$NAMESPACE" get configmap stardelt-public-demo >/dev/null 2>&1; then configmap_existed=1; fi
kubectl -n "$NAMESPACE" create configmap stardelt-public-demo --from-literal="sharedAccounts=$PERSON" \
  --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f - >/dev/null \
  || fail "cannot apply ConfigMap stardelt-public-demo"
echo "› ConfigMap stardelt-public-demo: sharedAccounts=$PERSON"
if [ "$configmap_existed" -eq 0 ]; then
  kubectl -n "$NAMESPACE" rollout restart deploy/nova >/dev/null || fail "cannot restart Nova"
  echo "› nova restarted (everyone signed in to Nova signs in again)"
fi

# 8. The memberships and the new Catalog reach Lakekeeper and Trino now, not on the next tick.
NAMESPACE="$NAMESPACE" make --no-print-directory access-sync-now
NAMESPACE="$NAMESPACE" make --no-print-directory catalogs

echo ""
echo "public-demo: OK — sign in as demo / demo"
