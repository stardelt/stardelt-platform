#!/usr/bin/env bash
# Give realm `stardelt`'s administrators the user-management roles, and make the
# realm's brute-force protection explicit — on the *live* realm.
#
#   NAMESPACE=stardelt bash scripts/sync-realm-user-management.sh
#
# Why this exists: `curl -L` users are managed in the Keycloak admin console, and
# the console is published again (only realm `stardelt`, see #53 and the Ingress
# paths). A person who can sign in to the console still cannot list or create a
# user unless the group carries the `realm-management` client roles below — the
# group `stardelt-admins` held none, which is why user management was impossible.
# `chart/files/keycloak-realm.json` is only read when the realm is first created
# (`--import-realm` skips an existing realm), so the same grant has to be applied
# to a running realm; this script is that path, in the style of
# scripts/sync-realm-admin.sh and scripts/keycloak-sync-trino-client.sh.
#
# It grants exactly the four roles the Users page needs:
#   view-users, query-users, query-groups, manage-users
# and deliberately not realm-admin / manage-clients / manage-realm: platform
# admins manage people, not the realm's security configuration.
#
# It also sets brute-force protection on realm `stardelt` because the console
# login is reachable from the internet. Thresholds are explicit rather than left
# to Keycloak's defaults, so `GET /admin/realms/stardelt` proves what is active.
#
# Idempotent: role mappings are compared before anything is added, and the realm
# update carries the same values every run. Reaches Keycloak through svc/keycloak
# (port-forward) because the public `/admin` API is closed. Secrets are read into
# files under a mode-0700 temp dir and never printed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
ADMIN_GROUP="${ADMIN_GROUP:-stardelt-admins}"
MANAGEMENT_CLIENT="${MANAGEMENT_CLIENT:-realm-management}"
REALM_ADMIN_SECRET="${REALM_ADMIN_SECRET:-stardelt-realm-admin}"
PROBE_CLIENT="${PROBE_CLIENT:-admin-cli}"

# The Users page: list/search users and groups, and create/update/delete users.
# `view-realm` is intentionally absent — the console's Users page does not need
# it (verified against Keycloak 26.8); adding it would expose realm settings.
GRANT_ROLES=(view-users query-users query-groups manage-users)
# Never grant these. The check at the end fails if they are already present on
# the group, because that is realm ownership rather than user management.
FORBIDDEN_ROLES=(realm-admin manage-clients manage-realm)

# Explicit brute-force protection (Keycloak 26 defaults, `failureFactor` tightened
# from 30 to 10 because this login is internet-facing).
FAILURE_FACTOR="${FAILURE_FACTOR:-10}"
WAIT_INCREMENT_SECONDS="${WAIT_INCREMENT_SECONDS:-60}"
QUICK_LOGIN_CHECK_MILLI_SECONDS="${QUICK_LOGIN_CHECK_MILLI_SECONDS:-1000}"
MINIMUM_QUICK_LOGIN_WAIT_SECONDS="${MINIMUM_QUICK_LOGIN_WAIT_SECONDS:-60}"
MAX_FAILURE_WAIT_SECONDS="${MAX_FAILURE_WAIT_SECONDS:-900}"
MAX_DELTA_TIME_SECONDS="${MAX_DELTA_TIME_SECONDS:-43200}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "sync-realm-user-management: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "sync-realm-user-management: $*" >&2; exit 1; }

# 1. Reach the admin API on loopback, through the Service.
local_port=18210
while (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; do
  local_port=$((local_port + 1))
done
kubectl -n "$NAMESPACE" port-forward svc/keycloak "$local_port:8080" >"$tmp/port-forward.log" 2>&1 &
pf_pid=$!
ready=""
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then ready=1; break; fi
  sleep 0.5
done
[ -n "$ready" ] || fail "port-forward to svc/keycloak never came up — is Keycloak installed in namespace $NAMESPACE?"
KC="http://127.0.0.1:$local_port"

# Keycloak in production mode answers on its public hostname (KC_HOSTNAME), so a
# request to 127.0.0.1 has to say which host it is meant for.
strip_scheme() { printf '%s' "$1" | sed -E 's|https?://||; s|/.*||'; }
KC_HOST="$(strip_scheme "$(kubectl -n "$NAMESPACE" get configmap keycloak-env -o jsonpath='{.data.KC_HOSTNAME}' 2>/dev/null || true)")"
[ -n "$KC_HOST" ] || fail "ConfigMap keycloak-env has no KC_HOSTNAME — run 'make install-identity'"
HEAD=(-H "X-Forwarded-Host: $KC_HOST" -H 'X-Forwarded-Proto: https')

# 2. Master-realm token: the realm admin cannot grant roles to its own group until
#    it has them, so this one step runs as the master admin.
kubectl -n "$NAMESPACE" get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d > "$tmp/master-pw" \
  || fail "cannot read Secret keycloak-admin — run 'make install-identity'"
master_token=""
for _ in $(seq 1 20); do
  master_token="$("${CURL_SOFT[@]}" "${HEAD[@]}" -X POST "$KC/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=admin" --data-urlencode "password@$tmp/master-pw" \
    --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")' 2>/dev/null || true)"
  [ -n "$master_token" ] && break
  sleep 2
done
[ -n "$master_token" ] || fail "the master realm refused the keycloak-admin Secret — is Keycloak reachable through svc/keycloak?"
AUTH=(-H "Authorization: Bearer $master_token")
API="$KC/admin/realms/$REALM"

for _ in $(seq 1 30); do
  status="$("${CURL_SOFT[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$API" || true)"
  [ "$status" = 200 ] && break
  sleep 2
done
[ "$status" = 200 ] || fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"

# 3. Brute-force protection, explicitly. A partial PUT is enough: Keycloak updates
#    the fields present and leaves everything else alone.
python3 - "$tmp/brute-force.json" "$FAILURE_FACTOR" "$WAIT_INCREMENT_SECONDS" \
  "$QUICK_LOGIN_CHECK_MILLI_SECONDS" "$MINIMUM_QUICK_LOGIN_WAIT_SECONDS" \
  "$MAX_FAILURE_WAIT_SECONDS" "$MAX_DELTA_TIME_SECONDS" <<'PY'
import json, sys
path, failure, wait_increment, quick_check, min_quick, max_wait, max_delta = sys.argv[1:]
with open(path, "w") as handle:
    json.dump({
        "bruteForceProtected": True,
        "permanentLockout": False,
        "failureFactor": int(failure),
        "waitIncrementSeconds": int(wait_increment),
        "quickLoginCheckMilliSeconds": int(quick_check),
        "minimumQuickLoginWaitSeconds": int(min_quick),
        "maxFailureWaitSeconds": int(max_wait),
        "maxDeltaTimeSeconds": int(max_delta),
    }, handle)
PY
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -X PUT --data @"$tmp/brute-force.json" "$API" >/dev/null \
  || fail "Keycloak refused the realm update for $REALM"

"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API" | python3 -c '
import json, sys
d = json.load(sys.stdin)
keys = ["bruteForceProtected", "permanentLockout", "failureFactor",
        "waitIncrementSeconds", "quickLoginCheckMilliSeconds",
        "minimumQuickLoginWaitSeconds", "maxFailureWaitSeconds",
        "maxDeltaTimeSeconds"]
missing = [k for k in keys if k not in d]
if missing:
    sys.exit("realm representation is missing: " + ", ".join(missing))
print("› brute-force protection (read back from realm %s):" % d["realm"])
for k in keys:
    print("    %-32s %s" % (k, d[k]))
' || fail "brute-force settings did not read back — the realm update did not stick"

# 4. Grant the user-management client roles to the admin group.
group_json="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/group-by-path/$ADMIN_GROUP")" \
  || fail "realm $REALM has no group '$ADMIN_GROUP' (re-apply the realm import / create it in the console)"
group_id="$(printf '%s' "$group_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
client_id="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$MANAGEMENT_CLIENT" \
  | python3 -c 'import sys,json
clients = json.load(sys.stdin)
if not clients:
    sys.exit("client realm-management is missing")
print(clients[0]["id"])')" \
  || fail "realm $REALM has no client '$MANAGEMENT_CLIENT' — the realm import is incomplete"

"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/groups/$group_id/role-mappings/clients/$client_id/available" > "$tmp/available.json"
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/groups/$group_id/role-mappings/clients/$client_id" > "$tmp/current.json"

python3 - "$tmp/available.json" "$tmp/current.json" "$tmp/grants.json" "${GRANT_ROLES[@]}" <<'PY'
import json, sys
available_path, current_path, grants_path, *wanted = sys.argv[1:]
available = {role["name"]: role for role in json.load(open(available_path))}
current = {role["name"] for role in json.load(open(current_path))}
missing = [name for name in wanted if name not in current]
unknown = [name for name in missing if name not in available]
if unknown:
    sys.exit("Keycloak does not offer these roles on %s: %s" % ("realm-management", ", ".join(unknown)))
with open(grants_path, "w") as handle:
    json.dump([available[name] for name in missing], handle)
PY

if python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])) else 1)' "$tmp/grants.json"; then
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/grants.json" "$API/groups/$group_id/role-mappings/clients/$client_id" >/dev/null \
    || fail "Keycloak refused the role mapping for group '$ADMIN_GROUP'"
  echo "› group $ADMIN_GROUP: granted ${GRANT_ROLES[*]} on client $MANAGEMENT_CLIENT"
else
  echo "› group $ADMIN_GROUP: ${GRANT_ROLES[*]} already granted"
fi

# 5. Read the mappings back, and refuse to call a broader grant a success.
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/groups/$group_id/role-mappings/clients/$client_id" | python3 -c '
import json, sys
roles = {role["name"] for role in json.load(sys.stdin)}
wanted, forbidden = sys.argv[1:5], sys.argv[5:]
missing = [name for name in wanted if name not in roles]
if missing:
    sys.exit("group is missing roles after the update: " + ", ".join(missing))
present_forbidden = [name for name in forbidden if name in roles]
if present_forbidden:
    sys.exit("group holds roles this script must not grant: " + ", ".join(present_forbidden))
print("› group role mapping verified: " + ", ".join(sorted(roles)))
' "${GRANT_ROLES[@]}" "${FORBIDDEN_ROLES[@]}" \
  || fail "the group's role mappings did not read back as granted"

# 6. Prove it with the realm admin's own token: not the master admin, and not by
#    reading configuration. A user-management role must open the users endpoint.
kubectl -n "$NAMESPACE" get secret "$REALM_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/realm-pw" \
  || fail "cannot read Secret $REALM_ADMIN_SECRET — run 'make install-identity'"
realm_admin="$(kubectl -n "$NAMESPACE" get secret "$REALM_ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || true)"
realm_admin="${realm_admin:-admin}"
realm_token="$("${CURL_SOFT[@]}" "${HEAD[@]}" -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode "username=$realm_admin" --data-urlencode "password@$tmp/realm-pw" \
  --data-urlencode "client_id=$PROBE_CLIENT" --data-urlencode "grant_type=password" 2>/dev/null \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")' 2>/dev/null || true)"
[ -n "$realm_token" ] || fail "realm $REALM refused the $REALM_ADMIN_SECRET credential — run 'make sync-realm-admin' first"

users_code="$("${CURL_SOFT[@]}" -o "$tmp/users.json" -w '%{http_code}' "${HEAD[@]}" \
  -H "Authorization: Bearer $realm_token" "$API/users?briefRepresentation=true")"
[ "$users_code" = 200 ] || fail "realm admin '$realm_admin' still cannot list users (HTTP $users_code) — check the group role mapping in the console"
python3 -c '
import json, sys
users = json.load(open(sys.argv[1]))
print("› realm admin %r can list users: HTTP 200, %d user(s): %s" % (
    sys.argv[2], len(users), ", ".join(sorted(user["username"] for user in users))))
' "$tmp/users.json" "$realm_admin" \
  || fail "the users endpoint answered 200 without a user list"

echo "sync-realm-user-management: OK — $ADMIN_GROUP can manage users in realm $REALM; brute force is on"
