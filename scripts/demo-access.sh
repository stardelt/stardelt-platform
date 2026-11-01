#!/usr/bin/env bash
# The prerequisites of the first pipeline: a group, its pipeline principal and the
# ServicePrincipal resource Nova looks for (demo plan, stardelt-platform#469).
#
#   make demo-access                      # prints the plan and exits 1
#   make demo-access YES=1                # converge group `demo` and principal `pipeline-demo`
#   make demo-access YES=1 GROUP=shop MEMBERS=ada,bo
#   bash scripts/demo-access.sh --manifest   # print the ServicePrincipal manifest, change nothing
#
# A person can publish a pipeline for a group only when that group has a *ready*
# principal named `pipeline-<group>`. Without it `stardelt bundle plan` refuses late with
# "No principal for this group yet". This script does what that sentence asks an
# administrator to do, in one idempotent command, and checks the layer catalogs first:
#
#   0. the Catalogs bronze, silver and gold exist (it never creates a Catalog: they belong
#      to whoever runs the cluster; the check happens before anything is changed);
#   1. the realm group GROUP exists (marked stardelt-managed=demo-access);
#   2. every name in MEMBERS is a member of it (users must exist; it never creates users);
#   3. `make sync-principal NAME=pipeline-GROUP GROUP=GROUP` converges the Keycloak client
#      and the Secret sp-pipeline-GROUP;
#   4. the ServicePrincipal resource pipeline-GROUP (ownerGroup GROUP) is applied;
#   5. it waits until the operator reports it ready (the Secret holds client-id and
#      client-secret), at most 90 seconds;
#   6. one access sync, so the memberships reach Lakekeeper and Trino now.
#
# A second run changes nothing and says so per step. It deletes nothing. It is an install
# step, not a development aid: it has no production guard, and it needs YES=1 to change
# anything. Passwords and secrets never appear in output.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
GROUP="${GROUP:-demo}"
MEMBERS="${MEMBERS:-}"
YES="${YES:-0}"

LAYER_CATALOGS=(bronze silver gold)
DEFAULT_GROUP=stardelt-users
MARK_ATTRIBUTE=stardelt-managed
MARK_VALUE=demo-access
CURL=(curl --fail-with-body --silent --show-error --max-time 30)

fail() { echo "demo-access: $*" >&2; exit 1; }

# A Kubernetes name: the principal is `pipeline-<group>`, so the group is lower case.
[[ "$GROUP" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] \
  || fail "GROUP must be 1 to 40 lower-case letters, digits and dashes (got '$GROUP')"
members=()
if [ -n "$MEMBERS" ]; then
  IFS=',' read -r -a members <<<"$MEMBERS"
  for member in "${members[@]}"; do
    [[ "$member" =~ ^[A-Za-z0-9._@-]+$ ]] || fail "MEMBERS must be a comma-separated list of user names (got '$member')"
  done
fi
principal="pipeline-$GROUP"

manifest() {
  cat <<EOF
apiVersion: stardelt.io/v1alpha1
kind: ServicePrincipal
metadata:
  name: $principal
  namespace: $NAMESPACE
  labels:
    stardelt.io/demo-access: "true"
spec:
  ownerGroup: $GROUP
  purpose: pipeline
EOF
}

if [ "${1:-}" = "--manifest" ]; then
  manifest
  exit 0
fi
[ -z "${1:-}" ] || fail "unexpected argument '$1' (accepted: --manifest)"

for tool in kubectl curl jq python3 base64 make; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done

# 0. The layer catalogs, before anything is changed.
missing=()
for catalog in "${LAYER_CATALOGS[@]}"; do
  kubectl -n "$NAMESPACE" get catalogs.stardelt.io "$catalog" >/dev/null 2>&1 || missing+=("$catalog")
done
[ "${#missing[@]}" -eq 0 ] \
  || fail "the Catalogs ${missing[*]} do not exist in namespace $NAMESPACE; apply the baseline layout (dev/seed/catalogs.yaml) or ask whoever runs the cluster; nothing was changed"
echo "› catalogs ${LAYER_CATALOGS[*]}: present"

if [ "$YES" != 1 ]; then
  echo "would: ensure group $GROUP, add members (${MEMBERS:-none}), converge principal $principal (make sync-principal), apply ServicePrincipal $principal, wait until ready, run one access sync — re-run with YES=1"
  exit 1
fi

umask 077
tmp="$(mktemp -d)"
cleanup() {
  if declare -F keycloak_admin_stop >/dev/null; then keycloak_admin_stop; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck disable=SC2034
KC_LOG_PREFIX=demo-access
# shellcheck source=lib/keycloak-admin.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"

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

# 1. The group.
read_groups
if [ -n "$(group_id "$GROUP")" ]; then
  echo "› group $GROUP: exists"
else
  printf '{"name":"%s","attributes":{"%s":["%s"]}}' "$GROUP" "$MARK_ATTRIBUTE" "$MARK_VALUE" >"$tmp/group.json"
  kc -H 'Content-Type: application/json' -X POST --data @"$tmp/group.json" "$API/groups" >/dev/null \
    || fail "Keycloak refused to create group $GROUP"
  echo "› group $GROUP: created"
  read_groups
fi
gid="$(group_id "$GROUP")"
[ -n "$gid" ] || fail "group $GROUP is not in the realm after creating it"
default_gid="$(group_id "$DEFAULT_GROUP")"

# 2. The members: people who must already exist.
for member in "${members[@]}"; do
  uid="$(user_id "$member")"
  [ -n "$uid" ] || fail "user $member does not exist in realm $REALM; create the person first (this script never creates users)"
  current="$(kc "$API/users/$uid/groups" | jq -r '.[].name')"
  if printf '%s\n' "$current" | grep -qx "$GROUP"; then
    echo "› user $member: member of $GROUP"
  else
    kc -X PUT "$API/users/$uid/groups/$gid" >/dev/null || fail "cannot add user $member to group $GROUP"
    echo "› user $member: added to $GROUP"
  fi
  if [ -n "$default_gid" ] && ! printf '%s\n' "$current" | grep -qx "$DEFAULT_GROUP"; then
    echo "  note: $member is not in $DEFAULT_GROUP, so the layer catalogs stay closed to them"
  fi
done

# 3. The client and the Secret.
NAMESPACE="$NAMESPACE" REALM="$REALM" make --no-print-directory sync-principal NAME="$principal" GROUP="$GROUP" \
  || fail "make sync-principal failed for $principal"
echo "› principal $principal: client and Secret sp-$principal converged"

# 4. The resource Nova reads.
manifest >"$tmp/principal.yaml"
kubectl apply -f "$tmp/principal.yaml" >/dev/null || fail "cannot apply ServicePrincipal $principal"
echo "› ServicePrincipal $principal: applied"

# 5. Ready means the operator found the Secret.
ready=""
for _ in $(seq 1 45); do
  ready="$(kubectl -n "$NAMESPACE" get serviceprincipals.stardelt.io "$principal" -o jsonpath='{.status.ready}' 2>/dev/null || true)"
  [ "$ready" = true ] && break
  sleep 2
done
[ "$ready" = true ] \
  || fail "ServicePrincipal $principal is not ready after 90 seconds: kubectl -n $NAMESPACE describe serviceprincipals.stardelt.io $principal"
echo "› ServicePrincipal $principal: ready"

# 6. The memberships reach Lakekeeper and Trino now, not on the next tick.
NAMESPACE="$NAMESPACE" make --no-print-directory access-sync-now

echo ""
echo "demo-access: OK — group $GROUP, principal $principal${MEMBERS:+, members $MEMBERS}"
echo "  a member can now publish: stardelt bundle plan . -t prod  (bundle ownerGroup: $GROUP, runAs: $principal)"
