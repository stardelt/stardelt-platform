#!/usr/bin/env bash
# The public demo person in one idempotent command (public demo, platform#896).
#
#   make public-demo                       # prints the plan and exits 1
#   make public-demo YES=1                 # converge the person `demo`, its grants and its warehouse
#   make public-demo-off YES=1             # kill switch: disable `demo` and sign it out
#   make public-demo-check                 # read-only: what the rollout still misses, and the fix
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
#   1b. the ServicePrincipal pipeline-visitors is ready, and its principal is in the group visitors, not demo;
#   2.  the person `demo` exists, is enabled, needs no actions and knows the password
#       `demo`; a person `demo` this script did not create is refused;
#   3.  `demo` is a member of `visitors` and of no other group (`stardelt-users` included:
#       the realm's defaultGroups adds every new user to it);
#   4.  `demo` holds no realm role, `default-roles-stardelt` included;
#   5.  the group `visitors` may browse and select bronze, silver and gold;
#   6.  the Catalog `playground` (write for `visitors`) and the SqlWarehouse `demo` (xs);
#   7.  the ConfigMap stardelt-public-demo, which tells Nova that `demo` is shared;
#   8.  one access sync and one catalog convergence (`make catalogs`);
#   9.  the shop pipelines name the group $GROUP as a viewer (read-only).
#   10. the Superset dashboard on the shop's gold tables (platform#966).
#   11. the nightly reset's script matches this checkout (it is a ConfigMap copy).
#   12. the nightly reset last succeeded within 26 hours (its CronJob status, not its script).
#
# Step 9 has a footgun: `stardelt bundle deploy` rewrites the whole spec, so a redeploy of the
# shop drops `viewers`. Run `make public-demo YES=1` (or `make public-demo-check`) after one.
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
  --check) mode=check ;;
  "") ;;
  *) fail "unexpected argument '$1' (accepted: --manifest, --off, --check)" ;;
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

# --check (platform#940): the read-only report of what the rollout still misses.
#
# One line per row, in rollout order, each row a check_<id> function that only reads
# (kubectl get, the Keycloak admin API, git, command -v). render prints PASS, or MISSING
# with the command that fixes it, and the script exits 1 while anything is missing. It
# changes nothing; the Keycloak port-forward is opened once and only when a realm row is
# read; a Secret is read for its key names only, never for a value.
if [ "$mode" = check ]; then
  check_rows=0
  check_ok=0

  render() { # render <id> — run the row's check and print PASS or MISSING
    local id="$1" rc=0
    check_msg=""
    check_fix=""
    case "$id" in
      0a) check_0a || rc=1 ;;
      0b) check_0b || rc=1 ;;
      0) check_0 || rc=1 ;;
      0c) check_0c || rc=1 ;;
      1) check_1 || rc=1 ;;
      1b) check_1b || rc=1 ;;
      2) check_2 || rc=1 ;;
      3) check_3 || rc=1 ;;
      4) check_4 || rc=1 ;;
      5) check_5 || rc=1 ;;
      6) check_6 || rc=1 ;;
      7) check_7 || rc=1 ;;
      8) check_8 || rc=1 ;;
      9) check_9 || rc=1 ;;
      10) check_10 || rc=1 ;;
      11) check_11 || rc=1 ;;
      12) check_12 || rc=1 ;;
      13) check_13 || rc=1 ;;
      *) check_msg="unknown row $id"; check_fix="this is a bug in scripts/public-demo.sh"; rc=1 ;;
    esac
    check_rows=$((check_rows + 1))
    if [ "$rc" -eq 0 ]; then
      check_ok=$((check_ok + 1))
      printf 'PASS     %-2s  %s\n' "$id" "$check_msg"
    else
      printf 'MISSING  %-2s  %s — %s\n' "$id" "$check_msg" "$check_fix"
    fi
  }

  # The realm rows share one Keycloak admin session, opened on the first of them.
  check_kc=""
  kc_prepare() {
    case "$check_kc" in
      up) return 0 ;;
      down) return 1 ;;
    esac
    if ! kubectl -n "$NAMESPACE" get configmap keycloak-env >/dev/null 2>&1 \
      || ! kubectl -n "$NAMESPACE" get secret keycloak-admin >/dev/null 2>&1; then
      check_kc=down
      return 1
    fi
    start_keycloak
    check_kc=up
    read_groups
  }
  kc_down() {
    check_msg="the Keycloak realm cannot be read (ConfigMap keycloak-env or Secret keycloak-admin is missing)"
    check_fix="make install-identity"
  }

  has_grant() { # has_grant <catalog> <group> <verb>
    kubectl -n "$NAMESPACE" get catalogs.stardelt.io "$1" -o json 2>/dev/null \
      | jq -e --arg g "$2" --arg v "$3" 'any(.spec.grants[]?; .group == $g and .verb == $v)' >/dev/null 2>&1
  }

  # 0a. The checkout the rollout runs from is not behind origin/main.
  check_0a() {
    local behind
    behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || true)"
    if [ -z "$behind" ]; then
      check_msg="cannot read origin/main in this checkout"
      check_fix="git fetch origin main"
      return 1
    fi
    if [ "$behind" -gt 0 ]; then
      check_msg="the checkout is $behind commit(s) behind origin/main"
      check_fix="git pull --ff-only"
      return 1
    fi
    check_msg="checkout at origin/main"
  }

  # 0b. The CLI the rollout steps call.
  check_0b() {
    if command -v stardelt >/dev/null 2>&1 && stardelt --version >/dev/null 2>&1; then
      check_msg="the stardelt CLI is on PATH"
      return 0
    fi
    check_msg="the stardelt CLI is not on PATH"
    check_fix="python3 -m venv ~/.local/venvs/stardelt-cli && ~/.local/venvs/stardelt-cli/bin/pip install 'stardelt==0.2.1'"
    return 1
  }

  # 0. The Catalogs the demo reads (never created here).
  check_0() {
    local missing=() catalog owner
    for catalog in "${PUBLIC_CATALOGS[@]}"; do
      owner="$(kubectl -n "$NAMESPACE" get catalogs.stardelt.io "$catalog" -o jsonpath='{.spec.owner}' 2>/dev/null || true)"
      [ "$owner" = "$OWNER" ] || missing+=("$catalog")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      check_msg="the Catalogs ${missing[*]} (owner $OWNER) are missing"
      check_fix="make public-demo-catalogs YES=1"
      return 1
    fi
    check_msg="catalogs ${PUBLIC_CATALOGS[*]}"
  }

  # 0c. The pipeline principal and the Secret its client lives in (key names only).
  check_0c() {
    local ready
    ready="$(kubectl -n "$NAMESPACE" get serviceprincipals.stardelt.io pipeline-demo -o jsonpath='{.status.ready}' 2>/dev/null || true)"
    if [ "$ready" != true ]; then
      check_msg="ServicePrincipal pipeline-demo is not ready"
      check_fix="make demo-access YES=1 GROUP=demo MEMBERS=<you>"
      return 1
    fi
    if ! kubectl -n "$NAMESPACE" get secret sp-pipeline-demo -o json 2>/dev/null \
      | jq -e '(.data // {}) | has("client-id") and has("client-secret")' >/dev/null 2>&1; then
      check_msg="Secret sp-pipeline-demo is missing or has no client-id/client-secret"
      check_fix="make demo-access YES=1 GROUP=demo MEMBERS=<you>"
      return 1
    fi
    check_msg="ServicePrincipal pipeline-demo and Secret sp-pipeline-demo"
  }

  # 1. The realm group.
  check_1() {
    kc_prepare || { kc_down; return 1; }
    if [ -z "$(group_id "$GROUP")" ]; then
      check_msg="the realm group $GROUP is missing"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="realm group $GROUP"
  }

  # 1b. The principal a visitor's pipeline runs as, ready, and owned by `visitors`.
  check_1b() {
    local ready owner
    ready="$(kubectl -n "$NAMESPACE" get serviceprincipals.stardelt.io pipeline-visitors -o jsonpath='{.status.ready}' 2>/dev/null || true)"
    if [ "$ready" != true ]; then
      check_msg="ServicePrincipal pipeline-visitors is not ready (.status.ready=${ready:-missing})"
      check_fix="make public-demo YES=1"
      return 1
    fi
    owner="$(kubectl -n "$NAMESPACE" get serviceprincipals.stardelt.io pipeline-visitors -o jsonpath='{.spec.ownerGroup}' 2>/dev/null || true)"
    if [ "$owner" != visitors ]; then
      check_msg="pipeline-visitors is owned by '$owner', not 'visitors' — a pipeline there could rewrite the shop"
      check_fix="kubectl -n $NAMESPACE delete serviceprincipal pipeline-visitors && make public-demo YES=1"
      return 1
    fi
    check_msg="ServicePrincipal pipeline-visitors is ready and owned by visitors"
  }

  # 2. The person: exists, enabled, no required action left.
  check_2() {
    kc_prepare || { kc_down; return 1; }
    local user_json actions
    if ! user_json="$(kc --get --data-urlencode "username=$PERSON" --data-urlencode 'exact=true' "$API/users")"; then
      check_msg="cannot read the person $PERSON from realm $REALM"
      check_fix="make public-demo YES=1"
      return 1
    fi
    if [ "$(jq -r 'length' <<<"$user_json")" = 0 ]; then
      check_msg="the person $PERSON does not exist"
      check_fix="make public-demo YES=1"
      return 1
    fi
    if [ "$(jq -r '.[0].enabled // false' <<<"$user_json")" != true ]; then
      check_msg="the person $PERSON is disabled"
      check_fix="make public-demo YES=1"
      return 1
    fi
    actions="$(jq -r '[(.[0].requiredActions // [])[]] | join(", ")' <<<"$user_json")"
    if [ -n "$actions" ]; then
      check_msg="the person $PERSON still has required actions: $actions"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="person $PERSON, enabled, no required actions"
  }

  # 3. Group memberships: in $GROUP, in nothing else.
  check_3() {
    kc_prepare || { kc_down; return 1; }
    local uid groups_json others
    uid="$(user_id "$PERSON")"
    if [ -z "$uid" ]; then
      check_msg="the person $PERSON does not exist"
      check_fix="make public-demo YES=1"
      return 1
    fi
    if ! groups_json="$(kc "$API/users/$uid/groups")"; then
      check_msg="cannot read the groups of $PERSON"
      check_fix="make public-demo YES=1"
      return 1
    fi
    if ! jq -e --arg g "$GROUP" 'any(.[]; .name == $g)' <<<"$groups_json" >/dev/null; then
      check_msg="$PERSON is not a member of $GROUP"
      check_fix="make public-demo YES=1"
      return 1
    fi
    others="$(jq -r --arg g "$GROUP" '[.[] | select(.name != $g) | .name] | join(", ")' <<<"$groups_json")"
    if [ -n "$others" ]; then
      check_msg="$PERSON is in $GROUP and also in $others"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="$PERSON is in $GROUP only"
  }

  # 4. Realm roles: none, $DEFAULT_ROLE included.
  check_4() {
    kc_prepare || { kc_down; return 1; }
    local uid roles_json names
    uid="$(user_id "$PERSON")"
    if [ -z "$uid" ]; then
      check_msg="the person $PERSON does not exist"
      check_fix="make public-demo YES=1"
      return 1
    fi
    if ! roles_json="$(kc "$API/users/$uid/role-mappings/realm")"; then
      check_msg="cannot read the realm roles of $PERSON"
      check_fix="make public-demo YES=1"
      return 1
    fi
    names="$(jq -r '[.[].name] | join(", ")' <<<"$roles_json")"
    if [ -n "$names" ]; then
      check_msg="$PERSON holds the realm role(s) $names"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="$PERSON holds no realm role"
  }

  # 5. The group's read access to the three Catalogs.
  check_5() {
    local missing=() catalog verb
    for catalog in "${PUBLIC_CATALOGS[@]}"; do
      for verb in browse select; do
        has_grant "$catalog" "$GROUP" "$verb" || missing+=("$catalog/$verb")
      done
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      check_msg="$GROUP lacks ${missing[*]}"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="$GROUP may browse and select ${PUBLIC_CATALOGS[*]}"
  }

  # 6. The playground and the warehouse.
  check_6() {
    local missing=() verb size
    for verb in write create; do
      has_grant playground "$GROUP" "$verb" || missing+=("Catalog playground $GROUP/$verb")
    done
    size="$(kubectl -n "$NAMESPACE" get sqlwarehouses.stardelt.io demo -o jsonpath='{.spec.size}' 2>/dev/null || true)"
    [ "$size" = xs ] || missing+=("SqlWarehouse demo (size xs)")
    if [ "${#missing[@]}" -gt 0 ]; then
      check_msg="missing ${missing[*]}"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="Catalog playground and SqlWarehouse demo (xs)"
  }

  # 7. What tells Nova that the account is shared.
  check_7() {
    if ! kubectl -n "$NAMESPACE" get configmap stardelt-public-demo >/dev/null 2>&1; then
      check_msg="ConfigMap stardelt-public-demo is missing"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="ConfigMap stardelt-public-demo"
  }

  # 8. The nightly reset, and that it has run at least once.
  check_8() {
    local last
    if ! kubectl -n "$NAMESPACE" get cronjobs.batch demo-reset >/dev/null 2>&1; then
      check_msg="CronJob demo-reset is missing"
      check_fix="make demo-reset-install"
      return 1
    fi
    last="$(kubectl -n "$NAMESPACE" get cronjobs.batch demo-reset -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)"
    if [ -z "$last" ]; then
      check_msg="CronJob demo-reset has not completed a run"
      check_fix="make demo-reset-now"
      return 1
    fi
    check_msg="CronJob demo-reset, last success ${last%%.*}"
  }

  # 9. The shop pipelines are readable by the visitors (epic#895 decision 12).
  check_9() {
    local total unshared
    total="$(kubectl -n "$NAMESPACE" get pipelines.stardelt.io -l stardelt.io/bundle=shop -o json 2>/dev/null | jq '.items | length' 2>/dev/null || echo 0)"
    if [ "${total:-0}" -eq 0 ]; then
      check_msg="no shop pipelines in the cluster (the shop bundle is not deployed)"
      check_fix="deploy the shop (epic#895 rollout step 2), then make public-demo YES=1"
      return 1
    fi
    unshared="$(kubectl -n "$NAMESPACE" get pipelines.stardelt.io -l stardelt.io/bundle=shop -o json \
      | jq --arg g "$GROUP" '[.items[] | select(((.spec.viewers // []) | index($g)) == null)] | length')"
    if [ "${unshared:-0}" -ne 0 ]; then
      check_msg="$unshared of $total shop pipelines do not name $GROUP as a viewer"
      check_fix="make public-demo YES=1"
      return 1
    fi
    check_msg="all $total shop pipelines name $GROUP as a viewer"
  }

  # 10. The shop dashboard exists and is handed to the visitors (platform#966). The sync
  # gives a published dashboard to every group role that may read the database its charts
  # read, so "visitors may see it" is the same sentence as "visitors may read gold".
  check_10() {
    local out roles
    out="$(kubectl -n "$NAMESPACE" exec -i deploy/superset -- python - <<'PY' 2>&1
from superset.app import create_app

app = create_app()
with app.app_context():
    from superset import db
    from superset.models.dashboard import Dashboard

    dashboard = db.session.query(Dashboard).filter_by(slug="public-demo-shop").first()
    if dashboard is None:
        print("stardelt-check-10: missing")
    elif not dashboard.roles:
        print("stardelt-check-10: nobody")
    else:
        print("stardelt-check-10: " + ",".join(sorted(role.name for role in dashboard.roles)))
PY
)" || out=""
    roles="$(printf '%s\n' "$out" | sed -n 's/^stardelt-check-10: //p' | tail -n 1)"
    if [ -z "$roles" ]; then
      check_msg="the shop dashboard cannot be read from Superset (the pod answered nothing)"
      check_fix="make public-demo YES=1"
      return 1
    fi
    if [ "$roles" = missing ]; then
      check_msg="the dashboard slug public-demo-shop is not imported"
      check_fix="make public-demo YES=1"
      return 1
    fi
    case ",$roles," in
      *",stardelt-group-$GROUP,"*) : ;;
      *)
        check_msg="the dashboard slug public-demo-shop is visible to '${roles:-nobody}', not stardelt-group-$GROUP"
        check_fix="make public-demo YES=1"
        return 1
        ;;
    esac
    check_msg="dashboard slug public-demo-shop, roles $roles"
  }

  # 11. The nightly reset runs this checkout's script (platform#1283): the CronJob mounts a
  # ConfigMap copy, so a merged change is dark until it is re-applied.
  check_11() {
    local live want
    live="$(kubectl -n "$NAMESPACE" get configmap demo-reset-script -o jsonpath='{.data.job\.py}' 2>/dev/null | sha256sum | cut -d' ' -f1)"
    want="$(sha256sum scripts/demo-reset-job.py | cut -d' ' -f1)"
    if [ "$live" != "$want" ]; then
      check_msg="CronJob demo-reset's script ConfigMap does not match scripts/demo-reset-job.py"
      check_fix="make demo-reset-sync"
      return 1
    fi
    check_msg="CronJob demo-reset runs this checkout's scripts/demo-reset-job.py"
  }

  # 12. The nightly reset runs and succeeds (platform#1294 follow-up). Row 11 proves the
  # CronJob mounts this checkout's script; this row proves it actually completes. 26 hours
  # leaves one late evening + one night before it reports.
  check_12() {
    local last epoch now
    last="$(kubectl -n "$NAMESPACE" get cronjob demo-reset \
      -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)"
    if [ -z "$last" ]; then
      check_msg="CronJob demo-reset has no successful run recorded"
      check_fix="make demo-reset-now   # runs it once and prints the log; it exits non-zero on failure"
      return 1
    fi
    epoch="$(date -u -d "$last" +%s 2>/dev/null || true)"
    now="$(date -u +%s)"
    if [ -z "$epoch" ] || [ $((now - epoch)) -gt 93600 ]; then
      check_msg="the last successful demo reset was $last"
      check_fix="kubectl -n $NAMESPACE logs -l job-name=demo-reset-<newest>   # then make demo-reset-now"
      return 1
    fi
    check_msg="the nightly reset last succeeded at $last"
  }

  # 13. The reset principal may drop in the playground (platform#1310). Since platform#1130 a
  # `write` grant is Lakekeeper `write`, not `modify`, so the nightly reset needs a
  # warehouse-scoped `modify` on playground, assigned to the user `service-account-sp-pipeline-demo`
  # — a role grant would be removed by access-sync on its next tick.
  check_13() {
    local out
    out="$(NAMESPACE="$NAMESPACE" bash scripts/demo-reset-grant.sh --check 2>&1)" || {
      check_msg="the reset principal cannot drop in playground: $(printf '%s' "$out" | tail -1)"
      check_fix="make demo-reset-grant"
      return 1
    }
    check_msg="the reset principal holds playground's warehouse modify"
  }

  render 0a
  render 0b
  render 0
  render 0c
  render 1
  render 1b
  render 2
  render 3
  render 4
  render 5
  render 6
  render 7
  render 8
  render 9
  render 10
  render 11
  render 12
  render 13

  echo ""
  if [ "$check_ok" -eq "$check_rows" ]; then
    echo "$check_ok of $check_rows ready — the public demo rollout is complete"
    exit 0
  fi
  echo "$check_ok of $check_rows ready — run the fixes above, then make public-demo-check again"
  exit 1
fi

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
would: let $GROUP read the shop pipelines (viewers, never run)
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

# 1b. The principal a visitor's pipeline runs as (epic#895 decision 11). In `visitors`, never
# in `demo`: a pipeline reaches exactly what `visitors` reaches — read the shop, write the
# playground — and the group that owns the shop tables stays out of it.
principal=pipeline-visitors
NAMESPACE="$NAMESPACE" REALM="$REALM" make --no-print-directory sync-principal \
  NAME="$principal" GROUP="$GROUP" \
  || fail "make sync-principal failed for $principal"
cat >"$tmp/principal.yaml" <<YAML
apiVersion: stardelt.io/v1alpha1
kind: ServicePrincipal
metadata:
  name: $principal
  namespace: $NAMESPACE
  labels:
    stardelt.io/public-demo: "true"
spec:
  ownerGroup: $GROUP
  purpose: pipeline
  audiences: [trino, lakekeeper]
YAML
kubectl apply -f "$tmp/principal.yaml" >/dev/null || fail "cannot apply ServicePrincipal $principal"
echo "› ServicePrincipal $principal: applied"
for _ in $(seq 1 45); do
  ready="$(kubectl -n "$NAMESPACE" get serviceprincipals.stardelt.io "$principal" -o jsonpath='{.status.ready}' 2>/dev/null || true)"
  [ "$ready" = true ] && break
  sleep 2
done
[ "$ready" = true ] || fail "ServicePrincipal $principal is not ready after 90 seconds: kubectl -n $NAMESPACE describe serviceprincipals.stardelt.io $principal"
echo "› ServicePrincipal $principal: ready"

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

# 9. The shop pipelines are readable by the visitors (epic#895 decision 12). Run, pause and
# delete stay with the owning group (`demo`); `viewers` only removes the wall in front of the
# list, the detail page and the runs. The shop is deployed by the rollout, not by this script,
# so a cluster without it says so and changes nothing.
read -r -a names <<<"$(kubectl -n "$NAMESPACE" get pipelines.stardelt.io \
  -l stardelt.io/bundle=shop -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ "${#names[@]}" -gt 0 ]; then
  # `kubectl patch` takes one object name; there is no `-l` on it. Patch each pipeline by
  # name, the way step 6 patches its Catalog.
  for name in "${names[@]}"; do
    kubectl -n "$NAMESPACE" patch pipelines.stardelt.io "$name" --type merge \
      -p "{\"spec\":{\"viewers\":[\"$GROUP\"]}}" >/dev/null \
      || fail "cannot add viewers=[$GROUP] to pipeline $name"
  done
  echo "› shop pipelines: viewers=[$GROUP] on ${#names[@]}"
else
  echo "› shop pipelines: none yet — deploy the shop bundle, then run make public-demo again"
fi

# 10. The shop dashboard (platform#966): imported from superset/bundles/public-demo-shop.
# Datasets come from the listed columns, so the import reads nothing from Trino and the
# service account needs no grant. The sync gives the published dashboard to the roles
# that may read Trino Gold.
#
# The bundle names its database by the UUID the sync gives that row (platform#967): the
# importer looks it up by UUID and leaves an existing row untouched, so the guard below is
# what stops a not-yet-converged cluster from creating a second `Trino Gold`.
dashboard_db="$(kubectl -n "$NAMESPACE" exec -i deploy/superset -- python - <<'PY' 2>&1
from superset.app import create_app

app = create_app()
with app.app_context():
    from superset import db
    from superset.models.core import Database

    row = db.session.query(Database).filter_by(uuid="bbb03e90-0c81-5c87-838a-0497064b6381").first()
    print("stardelt-step-10:", "present" if row else "missing")
PY
)" || true
if printf '%s\n' "$dashboard_db" | grep -q '^stardelt-step-10: present$'; then
  python3 -m zipfile -c "$tmp/shop.zip" superset/bundles/public-demo-shop \
    || fail "cannot build the shop dashboard bundle"
  kubectl -n "$NAMESPACE" exec -i deploy/superset -- sh -c 'cat > /tmp/public-demo-shop.zip' <"$tmp/shop.zip" \
    || fail "cannot copy the shop dashboard bundle into the Superset pod"
  kubectl -n "$NAMESPACE" exec deploy/superset -- superset import-dashboards -p /tmp/public-demo-shop.zip -u admin \
    || fail "cannot import the shop dashboard"
  # The sync runs every 5 minutes; run it now so the dashboard is handed to the group roles
  # that may read gold before this script returns.
  sync_job="superset-group-roles-demo-$(date +%s)"
  kubectl -n "$NAMESPACE" create job --from=cronjob/superset-group-roles "$sync_job" >/dev/null \
    || fail "cannot start the Superset role sync"
  kubectl -n "$NAMESPACE" wait --for=condition=complete --timeout=300s "job/$sync_job" >/dev/null \
    || fail "the Superset role sync did not complete within 300 seconds"
  echo "› shop dashboard: imported (slug public-demo-shop)"
else
  echo "› shop dashboard: Trino Gold not converged yet — wait 5 minutes (superset-group-roles), then run make public-demo YES=1 again"
fi

# 11. The nightly reset's script is a ConfigMap copy (platform#1283): refresh it here, without
# running a reset — a mid-day reset would throw away what a visitor is doing.
kubectl -n "$NAMESPACE" create configmap demo-reset-script --from-file=job.py=scripts/demo-reset-job.py \
  --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f - >/dev/null \
  || fail "cannot refresh the demo-reset script ConfigMap"
kubectl apply -f manifests/demo-reset.yaml >/dev/null || fail "cannot apply manifests/demo-reset.yaml"
echo "› demo-reset: script and CronJob applied (no reset run)"

echo ""
echo "public-demo: OK — sign in as demo / demo"
