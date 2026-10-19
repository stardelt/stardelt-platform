#!/usr/bin/env bash
# Converge the live Keycloak realm onto the `trino-group-sync` service-account
# client the continuous group-file sync (platform#167) authenticates as.
#
#   NAMESPACE=stardelt bash scripts/keycloak-sync-trino-group-sync-client.sh
#
# Why this exists: `--import-realm` substitutes
# ${STARDELT_TRINO_GROUP_SYNC_CLIENT_SECRET} once, on the first start that
# creates realm `stardelt`, and never looks at it again — the same snapshot as
# the realm admin (#81) and the app clients (#85). Worse, any realm that
# predates platform#167 has no such client at all. The Secret is the source of
# truth; this script creates the client when missing, re-applies the Secret's
# value when it drifted, and grants the service account exactly one
# realm-management role — `view-users`, the minimum that opens
# `group-by-path` + `groups/{id}/members` (probed live: `query-users` +
# `query-groups` answer 403). A dedicated client rather than an existing
# identity because every existing identity is either broader (the master
# credential owns all realms; the realm admin can manage users) or has no
# admin-API access at all (the app clients) — widening any of them would break
# the ticket's read-only constraint.
#
# Idempotent: the secret is compared before anything is written, the role
# mapping is compared before anything is added, and the run ends by proving the
# grant with the client's own token — a client-credentials grant followed by
# the exact two admin-API reads the CronJob performs. Reaches Keycloak through
# svc/keycloak (port-forward) because the public `/admin` API is closed.
# Secrets are read into files under a mode-0700 temp dir and travel to curl
# only through `--data @file` bodies — never argv, stdout or a log line. The
# only thing printed about the membership is its count.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
ADMIN_GROUP="${ADMIN_GROUP:-stardelt-admins}"
SYNC_CLIENT="${SYNC_CLIENT:-trino-group-sync}"
CLIENTS_SECRET="${CLIENTS_SECRET:-stardelt-oidc-clients}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
MANAGEMENT_CLIENT="${MANAGEMENT_CLIENT:-realm-management}"

# The one role the sync needs. `view-users` is composite (it carries the query
# roles with it) but still read-only: nothing in it creates, updates or deletes.
GRANT_ROLES=(view-users)
# Never grant these. The read-back check fails when any of them is already on
# the service account, because that is broader than the read-only membership
# access this client exists for.
FORBIDDEN_ROLES=(realm-admin manage-realm manage-clients manage-users manage-authorization impersonation create-client)

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "keycloak-sync-trino-group-sync-client: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "keycloak-sync-trino-group-sync-client: $*" >&2; exit 1; }

# 1. Reach the admin API on loopback, through the Service.
local_port=18230
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

# 2. The Secret's value first: it is the source of truth, and without it there
#    is nothing to converge onto.
kubectl -n "$NAMESPACE" get secret "$CLIENTS_SECRET" \
  -o jsonpath="{.data.$SYNC_CLIENT}" 2>/dev/null | base64 -d > "$tmp/client-secret" || true
[ -s "$tmp/client-secret" ] || fail "Secret $CLIENTS_SECRET has no non-empty '$SYNC_CLIENT' key — run scripts/identity-bootstrap.sh"

# 3. Master-realm token. Retry: the Service can accept a connection while Keycloak
#    is still finishing its boot.
kubectl -n "$NAMESPACE" get secret "$MASTER_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/master-pw" \
  || fail "cannot read Secret $MASTER_SECRET — run 'make install-identity'"
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
[ -n "$master_token" ] || fail "the master realm refused the $MASTER_SECRET credential — is Keycloak reachable through svc/keycloak?"
AUTH=(-H "Authorization: Bearer $master_token")
API="$KC/admin/realms/$REALM"

for _ in $(seq 1 30); do
  status="$("${CURL_SOFT[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$API" || true)"
  [ "$status" = 200 ] && break
  sleep 2
done
[ "$status" = 200 ] || fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"

# 4. The client itself. Realms that predate platform#167 have none — the import
#    skips an existing realm — so create it in exactly the shape the realm
#    import declares (chart/files/keycloak-realm.json): confidential, service
#    account only, every interactive flow off, no mappers, no redirect URIs.
client_uuid="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$SYNC_CLIENT" \
  | python3 -c 'import sys,json
clients = json.load(sys.stdin)
print(clients[0]["id"] if clients else "")')"
if [ -z "$client_uuid" ]; then
  python3 - "$tmp/client-secret" > "$tmp/client-create.json" <<'PY'
import json, sys
sys.stdout.write(json.dumps({
    "clientId": "trino-group-sync",
    "name": "Trino group sync",
    "description": "Continuous sync of the stardelt-admins group file (platform#167).",
    "enabled": True,
    "protocol": "openid-connect",
    "publicClient": False,
    "clientAuthenticatorType": "client-secret",
    "secret": open(sys.argv[1]).read().rstrip("\n"),
    "standardFlowEnabled": False,
    "implicitFlowEnabled": False,
    "directAccessGrantsEnabled": False,
    "serviceAccountsEnabled": True,
    "attributes": {},
    "protocolMappers": [],
}))
PY
  # SYNC_CLIENT is fixed above (overridable only for tests); the create body
  # names the same client. Reject anything else rather than half-configuring it.
  [ "$SYNC_CLIENT" = "trino-group-sync" ] || fail "refusing to create an unexpected client '$SYNC_CLIENT'"
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/client-create.json" "$API/clients" >/dev/null \
    || fail "Keycloak refused to create client '$SYNC_CLIENT'"
  client_uuid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$SYNC_CLIENT" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "› client $SYNC_CLIENT: created"
else
  echo "› client $SYNC_CLIENT: exists"
fi

# 5. Converge the secret onto the Secret's value. The PUT merges this one field
#    into the client representation — flows, roles and mappers are untouched.
stored_file="$tmp/client.stored"
if "${CURL_SOFT[@]}" -o "$tmp/stored.json" -w '' "${HEAD[@]}" "${AUTH[@]}" \
    "$API/clients/$client_uuid/client-secret" 2>/dev/null \
  && python3 - "$tmp/stored.json" > "$stored_file" <<'PY' 2>/dev/null \
  && cmp -s "$stored_file" "$tmp/client-secret"; then
import json, sys
value = json.load(open(sys.argv[1])).get("value")
if value is None:
    sys.exit(1)
sys.stdout.write(value)
PY
  echo "› client $SYNC_CLIENT: secret matches"
else
  python3 - "$tmp/client-secret" > "$tmp/client-secret-write.json" <<'PY'
import json, sys
sys.stdout.write(json.dumps({"secret": open(sys.argv[1]).read().rstrip("\n")}))
PY
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT --data @"$tmp/client-secret-write.json" "$API/clients/$client_uuid" >/dev/null \
    || fail "Keycloak refused the secret update for client $SYNC_CLIENT — check 'kubectl -n $NAMESPACE logs deploy/keycloak'"
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid/client-secret" \
    > "$tmp/stored-after.json" \
    || fail "cannot read client $SYNC_CLIENT's secret back after the update"
  python3 - "$tmp/stored-after.json" "$tmp/client-secret" "$SYNC_CLIENT" <<'PY' \
    || fail "client $SYNC_CLIENT reads back a different secret than the Secret holds"
import json, sys
stored = json.load(open(sys.argv[1])).get("value")
wanted = open(sys.argv[2]).read()
if stored != wanted:
    sys.exit(1)
print("› client %s: secret updated" % sys.argv[3])
PY
fi

# 6. Grant the service account exactly the read-only role. The account appears
#    as user `service-account-<clientId>` once serviceAccountsEnabled is on.
sa_uid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid/service-account-user" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')" \
  || fail "client $SYNC_CLIENT has no service-account user — is serviceAccountsEnabled on?"
mgmt_uuid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$MANAGEMENT_CLIENT" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')" \
  || fail "realm $REALM has no client '$MANAGEMENT_CLIENT' — the realm import is incomplete"

"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$mgmt_uuid/roles" > "$tmp/roles.json"
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users/$sa_uid/role-mappings/clients/$mgmt_uuid" > "$tmp/current.json"

python3 - "$tmp/roles.json" "$tmp/current.json" "$tmp/grants.json" "${GRANT_ROLES[@]}" <<'PY'
import json, sys
roles_path, current_path, grants_path, *wanted = sys.argv[1:]
available = {role["name"]: role for role in json.load(open(roles_path))}
current = {role["name"] for role in json.load(open(current_path))}
missing = [name for name in wanted if name not in current]
unknown = [name for name in missing if name not in available]
if unknown:
    sys.exit("Keycloak does not offer these roles on realm-management: " + ", ".join(unknown))
with open(grants_path, "w") as handle:
    json.dump([available[name] for name in missing], handle)
PY

if python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])) else 1)' "$tmp/grants.json"; then
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/grants.json" "$API/users/$sa_uid/role-mappings/clients/$mgmt_uuid" >/dev/null \
    || fail "Keycloak refused the role mapping for the $SYNC_CLIENT service account"
  echo "› service account: granted ${GRANT_ROLES[*]} on client $MANAGEMENT_CLIENT"
else
  echo "› service account: ${GRANT_ROLES[*]} already granted"
fi

# Read the mapping back, and refuse to call a broader grant a success.
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users/$sa_uid/role-mappings/clients/$mgmt_uuid" | python3 -c '
import json, sys
roles = {role["name"] for role in json.load(sys.stdin)}
wanted, forbidden = sys.argv[1:2], sys.argv[2:]
missing = [name for name in wanted if name not in roles]
if missing:
    sys.exit("service account is missing roles after the update: " + ", ".join(missing))
present_forbidden = [name for name in forbidden if name in roles]
if present_forbidden:
    sys.exit("service account holds roles this client must not have: " + ", ".join(present_forbidden))
print("› service-account role mapping verified: " + ", ".join(sorted(roles)))
' "${GRANT_ROLES[@]}" "${FORBIDDEN_ROLES[@]}" \
  || fail "the service account's role mappings did not read back as granted"

# 7. Prove it with the client's own token: a client-credentials grant, then the
#    exact two admin-API reads the CronJob performs. Only the count is printed.
cc_token="$("${CURL_SOFT[@]}" "${HEAD[@]}" -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$SYNC_CLIENT" \
  --data-urlencode "client_secret@$tmp/client-secret" 2>/dev/null \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")' 2>/dev/null || true)"
[ -n "$cc_token" ] || fail "the token endpoint refused the $SYNC_CLIENT client credentials — the secret did not stick"
CC_AUTH=(-H "Authorization: Bearer $cc_token")
group_json="$("${CURL[@]}" "${HEAD[@]}" "${CC_AUTH[@]}" "$API/group-by-path/$ADMIN_GROUP")" \
  || fail "client $SYNC_CLIENT cannot resolve group '$ADMIN_GROUP' (HTTP error above) — check its view-users grant"
group_id="$(printf '%s' "$group_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
count="$("${CURL[@]}" "${HEAD[@]}" "${CC_AUTH[@]}" "$API/groups/$group_id/members?briefRepresentation=true" \
  | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"
echo "keycloak-sync-trino-group-sync-client: OK — client $SYNC_CLIENT reads $ADMIN_GROUP ($count member(s)) with ${GRANT_ROLES[*]} only"
