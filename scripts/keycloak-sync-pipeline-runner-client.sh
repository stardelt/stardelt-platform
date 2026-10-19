#!/usr/bin/env bash
# Converge the live Keycloak realm onto the `pipeline-runner` service-account client that
# scheduled pipelines run as (scheduled jobs phase J0, stardelt-platform#118).
#
#   NAMESPACE=stardelt bash scripts/keycloak-sync-pipeline-runner-client.sh
#
# The pipeline loader (stardelt-demos, dags/pipeline_loader.py) fetches a client-credentials
# token for this client and runs each `sql` task on the query engine with it, so the
# catalog's policies apply to scheduled work exactly like to a person. The engine accepts
# the token because it carries the audience `trino` (mapper `aud-trino`).
#
# Why this exists: `--import-realm` substitutes ${STARDELT_PIPELINE_RUNNER_CLIENT_SECRET}
# once, on the first start that creates the realm, and never looks at it again; a realm that
# predates this client has none at all. The Secret (`stardelt-oidc-clients`, key
# `pipeline-runner`) is the source of truth. This script creates the client when missing,
# re-applies the Secret's value when it drifted, makes sure the audience mapper is present,
# and proves the result with the client's own token. The service account is granted NO
# admin-API role: the script fails when it finds one. Idempotent. Reaches Keycloak through
# svc/keycloak (port-forward) because the public `/admin` API is closed. Secrets travel
# only through files under a mode-0700 temp dir and `--data @file` bodies, never argv,
# stdout or a log line; the token claims printed at the end are not secret.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
RUNNER_CLIENT="${RUNNER_CLIENT:-pipeline-runner}"
CLIENTS_SECRET="${CLIENTS_SECRET:-stardelt-oidc-clients}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
MANAGEMENT_CLIENT="${MANAGEMENT_CLIENT:-realm-management}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "keycloak-sync-pipeline-runner-client: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "keycloak-sync-pipeline-runner-client: $*" >&2; exit 1; }

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
  -o jsonpath="{.data.$RUNNER_CLIENT}" 2>/dev/null | base64 -d > "$tmp/client-secret" || true
[ -s "$tmp/client-secret" ] || fail "Secret $CLIENTS_SECRET has no non-empty '$RUNNER_CLIENT' key — run scripts/identity-bootstrap.sh"

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

# 4. The client itself. Realms that predate this client have none (the import skips an
#    existing realm), so create it in exactly the shape the realm import declares
#    (chart/files/keycloak-realm.json): confidential, service account only, every
#    interactive flow off, no redirect URIs, one audience mapper.
client_uuid="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$RUNNER_CLIENT" \
  | python3 -c 'import sys,json
clients = json.load(sys.stdin)
print(clients[0]["id"] if clients else "")')"
if [ -z "$client_uuid" ]; then
  python3 - "$tmp/client-secret" "$RUNNER_CLIENT" > "$tmp/client-create.json" <<'PY'
import json, sys
sys.stdout.write(json.dumps({
    "clientId": sys.argv[2],
    "name": "Pipeline runner",
    "description": "Service principal scheduled pipelines run as (scheduled jobs J0).",
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
    "protocolMappers": [{
        "name": "aud-trino",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-audience-mapper",
        "consentRequired": False,
        "config": {
            "included.client.audience": "trino",
            "id.token.claim": "false",
            "access.token.claim": "true",
            "introspection.token.claim": "true",
        },
    }],
}))
PY
  case "$RUNNER_CLIENT" in
    *[!a-z0-9-]*|"") fail "refusing to create a client named '$RUNNER_CLIENT' (lower-case letters, digits and dashes only)" ;;
  esac
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/client-create.json" "$API/clients" >/dev/null \
    || fail "Keycloak refused to create client '$RUNNER_CLIENT'"
  client_uuid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$RUNNER_CLIENT" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "› client $RUNNER_CLIENT: created"
else
  echo "› client $RUNNER_CLIENT: exists"
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
  echo "› client $RUNNER_CLIENT: secret matches"
else
  python3 - "$tmp/client-secret" > "$tmp/client-secret-write.json" <<'PY'
import json, sys
sys.stdout.write(json.dumps({"secret": open(sys.argv[1]).read().rstrip("\n")}))
PY
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT --data @"$tmp/client-secret-write.json" "$API/clients/$client_uuid" >/dev/null \
    || fail "Keycloak refused the secret update for client $RUNNER_CLIENT — check 'kubectl -n $NAMESPACE logs deploy/keycloak'"
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid/client-secret" \
    > "$tmp/stored-after.json" \
    || fail "cannot read client $RUNNER_CLIENT's secret back after the update"
  python3 - "$tmp/stored-after.json" "$tmp/client-secret" "$RUNNER_CLIENT" <<'PY' \
    || fail "client $RUNNER_CLIENT reads back a different secret than the Secret holds"
import json, sys
stored = json.load(open(sys.argv[1])).get("value")
wanted = open(sys.argv[2]).read()
if stored != wanted:
    sys.exit(1)
print("› client %s: secret updated" % sys.argv[3])
PY
fi

# 5b. The audience mapper. A client created by an older version of this script, or by hand,
#     may lack it, and the engine refuses a token without the audience `trino`.
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid" > "$tmp/client.json"
if python3 -c 'import json,sys
names = {m["name"] for m in json.load(open(sys.argv[1])).get("protocolMappers") or []}
sys.exit(0 if "aud-trino" in names else 1)' "$tmp/client.json"; then
  echo "› client $RUNNER_CLIENT: audience mapper present"
else
  cat > "$tmp/mapper.json" <<'JSON'
{"name":"aud-trino","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","consentRequired":false,"config":{"included.client.audience":"trino","id.token.claim":"false","access.token.claim":"true","introspection.token.claim":"true"}}
JSON
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/mapper.json" "$API/clients/$client_uuid/protocol-mappers/models" >/dev/null \
    || fail "Keycloak refused the audience mapper for client $RUNNER_CLIENT"
  echo "› client $RUNNER_CLIENT: audience mapper added"
fi

# 6. The service account must hold no admin-API role. A pipeline principal reads and writes
#    data through the engine; it never manages the identity provider.
sa_uid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid/service-account-user" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')" \
  || fail "client $RUNNER_CLIENT has no service-account user — is serviceAccountsEnabled on?"
mgmt_uuid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$MANAGEMENT_CLIENT" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')" \
  || fail "realm $REALM has no client '$MANAGEMENT_CLIENT' — the realm import is incomplete"
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users/$sa_uid/role-mappings/clients/$mgmt_uuid" | python3 -c '
import json, sys
roles = sorted(role["name"] for role in json.load(sys.stdin))
if roles:
    sys.exit("the service account holds admin-API roles it must not have: " + ", ".join(roles))
print("› service account holds no admin-API role")
' || fail "client $RUNNER_CLIENT's service account is too powerful — remove its $MANAGEMENT_CLIENT roles"

# 7. Prove it with the client's own token: a client-credentials grant, then the claims the
#    engine relies on. Only non-secret claims are printed.
cc_token="$("${CURL_SOFT[@]}" "${HEAD[@]}" -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$RUNNER_CLIENT" \
  --data-urlencode "client_secret@$tmp/client-secret" 2>/dev/null \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")' 2>/dev/null || true)"
[ -n "$cc_token" ] || fail "the token endpoint refused the $RUNNER_CLIENT client credentials — the secret did not stick"
printf '%s' "$cc_token" > "$tmp/cc-token"
python3 - "$tmp/cc-token" "$RUNNER_CLIENT" <<'PY' || fail "the $RUNNER_CLIENT token does not carry what the engine needs"
import base64, json, sys
payload = open(sys.argv[1]).read().split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
client = sys.argv[2]
audiences = claims.get("aud") if isinstance(claims.get("aud"), list) else [claims.get("aud")]
problems = []
if "trino" not in audiences:
    problems.append("audience lacks trino (aud=%s)" % audiences)
if claims.get("azp") != client:
    problems.append("azp is %r" % claims.get("azp"))
if claims.get("preferred_username") != "service-account-" + client:
    problems.append("preferred_username is %r" % claims.get("preferred_username"))
if problems:
    sys.exit("; ".join(problems))
print("› token claims ok: aud=%s azp=%s preferred_username=%s" % (audiences, claims["azp"], claims["preferred_username"]))
PY
echo "keycloak-sync-pipeline-runner-client: OK — client $RUNNER_CLIENT issues tokens for the query engine and holds no admin role"
