#!/usr/bin/env bash
# Converge the live Keycloak realm onto the public client `stardelt-mcp` that an MCP-capable agent
# signs in with (stardelt-nova#112, stardelt-operator#69): PKCE to a loopback address and the
# device grant, no secret, no service account. Its tokens carry the audience `<nova publicUrl>/mcp`
# and the `groups` claim and nothing else that grants data access — the token is for the `/mcp`
# endpoint only. The engine (catalog/Trino) token is minted server-side by the token exchange
# (platform#174); an agent holding an engine-audience token could run SQL directly and bypass the
# read-only tool surface (`design/agent-access.md` §4).
#
#   NAMESPACE=stardelt bash scripts/keycloak-sync-mcp-client.sh
#   MCP_AUDIENCE=https://nova.example.com/mcp NAMESPACE=stardelt bash scripts/keycloak-sync-mcp-client.sh
#
# Why a script: `--import-realm` creates the client on a fresh realm only. This one creates it
# when missing, brings drifted settings back (enabled, flows, redirect addresses, PKCE, device
# grant), restores missing mappers, proves the stored client carries the MCP audience, and proves
# the result against the realm's own endpoints: the device endpoint answers, a loopback redirect
# with any port is accepted and a redirect to a foreign host is refused. Idempotent. Reaches
# Keycloak through svc/keycloak (port-forward) because the public `/admin` API is closed; secrets
# travel only through files under a mode-0700 temp dir and `--data @file` bodies.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
MCP_CLIENT="${MCP_CLIENT:-stardelt-mcp}"
READ_SCOPE="${READ_SCOPE:-stardelt:read}"
MCP_AUDIENCE="${MCP_AUDIENCE:-}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64 openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "keycloak-sync-mcp-client: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "keycloak-sync-mcp-client: $*" >&2; exit 1; }

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
HEAD=(-H "X-Forwarded-Host: $KC_HOST" -H 'X-Forwarded-Proto: https')

# 2. The audience. It is the Nova origin (ConfigMap stardelt-identity `publicUrl`), not the Keycloak
#    host: Nova's /mcp endpoint validates the token against the same value (NOVA_MCP_AUDIENCE).
if [ -z "$MCP_AUDIENCE" ]; then
  public_url="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath='{.data.publicUrl}' 2>/dev/null || true)"
  [ -n "$public_url" ] || fail "ConfigMap stardelt-identity has no publicUrl — run 'make install-identity' first, or set MCP_AUDIENCE"
  MCP_AUDIENCE="${public_url%/}/mcp"
fi
echo "› client $MCP_CLIENT: audience $MCP_AUDIENCE"

[ -n "$KC_HOST" ] || fail "ConfigMap keycloak-env has no KC_HOSTNAME — run 'make install-identity'"

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

# 4. The client. Realms that predate it have none (the import skips an existing realm), so it is
#    created in exactly the shape the realm import declares (chart/files/keycloak-realm.json).
case "$MCP_CLIENT" in
  *[!a-z0-9-]*|"") fail "refusing a client named '$MCP_CLIENT' (lower-case letters, digits and dashes only)" ;;
esac

python3 - "$MCP_CLIENT" "$MCP_AUDIENCE" > "$tmp/desired.json" <<'PY'
import json, sys
client, audience = sys.argv[1], sys.argv[2]
json.dump({
    "clientId": client,
    "name": "MCP agents",
    "description": "Public client for MCP-capable agents (stardelt-nova#112): PKCE to a loopback address and the device grant. Tokens carry the audience <nova host>/mcp only; the engine token is minted by exchange (platform#174).",
    "enabled": True,
    "protocol": "openid-connect",
    "publicClient": True,
    "standardFlowEnabled": True,
    "implicitFlowEnabled": False,
    "directAccessGrantsEnabled": False,
    "serviceAccountsEnabled": False,
    "fullScopeAllowed": False,
    "redirectUris": ["http://127.0.0.1/*", "http://localhost/*"],
    "webOrigins": [],
    "attributes": {"oauth2.device.authorization.grant.enabled": "true", "pkce.code.challenge.method": "S256"},
    "protocolMappers": [
        {"name": "aud-mcp", "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
         "consentRequired": False,
         "config": {"included.custom.audience": audience, "id.token.claim": "false",
                    "access.token.claim": "true", "introspection.token.claim": "true"}},
        {"name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
         "consentRequired": False,
         "config": {"claim.name": "groups", "full.path": "false", "id.token.claim": "true",
                    "access.token.claim": "true", "userinfo.token.claim": "true",
                    "introspection.token.claim": "true"}},
    ],
}, sys.stdout)
PY

client_uuid="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$MCP_CLIENT" \
  | python3 -c 'import sys,json
clients = json.load(sys.stdin)
print(clients[0]["id"] if clients else "")')"
if [ -z "$client_uuid" ]; then
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/desired.json" "$API/clients" >/dev/null \
    || fail "Keycloak refused to create client '$MCP_CLIENT'"
  client_uuid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$MCP_CLIENT" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "› client $MCP_CLIENT: created"
else
  echo "› client $MCP_CLIENT: exists"
fi

# 5. Converge the settings. Read the stored representation, change only what drifted, PUT it back.
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid" > "$tmp/current.json"
python3 - "$tmp/current.json" "$tmp/desired.json" "$tmp/merged.json" <<'PY' > "$tmp/drift.txt"
import json, sys
current, desired = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
drift = []
for key in ("enabled", "publicClient", "standardFlowEnabled", "implicitFlowEnabled",
            "directAccessGrantsEnabled", "serviceAccountsEnabled", "fullScopeAllowed"):
    if current.get(key) != desired[key]:
        drift.append(key); current[key] = desired[key]
if sorted(current.get("redirectUris") or []) != sorted(desired["redirectUris"]):
    drift.append("redirectUris"); current["redirectUris"] = desired["redirectUris"]
attrs = current.setdefault("attributes", {})
for key, value in desired["attributes"].items():
    if attrs.get(key) != value:
        drift.append("attributes." + key); attrs[key] = value
json.dump(current, open(sys.argv[3], "w"))
print(" ".join(drift))
PY
if [ -n "$(tr -d '[:space:]' < "$tmp/drift.txt")" ]; then
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT --data @"$tmp/merged.json" "$API/clients/$client_uuid" >/dev/null \
    || fail "Keycloak refused the settings update for client $MCP_CLIENT"
  echo "› client $MCP_CLIENT: settings restored ($(cat "$tmp/drift.txt"))"
else
  echo "› client $MCP_CLIENT: settings match"
fi

# 5b. Mappers, by name; a missing one is added.
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid" > "$tmp/current.json"
python3 - "$tmp/current.json" "$tmp/desired.json" "$tmp" <<'PY' > "$tmp/missing.txt"
import json, sys, os
current, desired, tmp = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
have = {m["name"] for m in current.get("protocolMappers") or []}
missing = [m for m in desired["protocolMappers"] if m["name"] not in have]
for i, mapper in enumerate(missing):
    json.dump(mapper, open(os.path.join(tmp, "mapper-%d.json" % i), "w"))
print(len(missing))
PY
n_missing="$(cat "$tmp/missing.txt")"
for i in $(seq 0 $((n_missing - 1))); do
  [ "$n_missing" -gt 0 ] || break
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/mapper-$i.json" "$API/clients/$client_uuid/protocol-mappers/models" >/dev/null \
    || fail "Keycloak refused a mapper for client $MCP_CLIENT"
done
if [ "$n_missing" -gt 0 ]; then echo "› client $MCP_CLIENT: $n_missing mapper(s) added"; else echo "› client $MCP_CLIENT: mappers present"; fi

# 5c. Read the stored client back: the audience mapper must be the one this Nova host expects, and
#     the token must not carry an engine audience (that one is minted by the exchange, platform#174).
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid" > "$tmp/after.json"
python3 - "$tmp/after.json" "$MCP_AUDIENCE" <<'PY' || fail "the stored client does not carry the MCP audience mapper"
import json, sys
client = json.load(open(sys.argv[1]))
audience = sys.argv[2]
m = {x["name"]: x for x in client.get("protocolMappers") or []}
assert m.get("aud-mcp", {}).get("config", {}).get("included.custom.audience") == audience, "aud-mcp audience drifted"
assert "groups" in m, "the groups mapper is missing"
assert "aud-trino" not in m, "the MCP token must not carry the engine audience"
print("› client %s: aud-mcp=%s, groups" % (client["clientId"], audience))
PY

# 5d. The read scope. `/mcp` requires `stardelt:read`; the realm import only runs on a fresh
#     realm, so a realm that predates the client gets the scope here. It is a **default**
#     client scope: every token carries it without a `scope` parameter, which is what an MCP
#     client sends.
scope_id="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/client-scopes" \
  | python3 -c "import sys,json; print(next((s['id'] for s in json.load(sys.stdin) if s['name'] == '$READ_SCOPE'), ''))")"
if [ -z "$scope_id" ]; then
  python3 - > "$tmp/scope.json" <<'PY'
import json, sys
json.dump({"name": "stardelt:read",
           "description": "Read-only agent access through Nova's /mcp endpoint.",
           "protocol": "openid-connect",
           "attributes": {"include.in.token.scope": "true",
                          "display.on.consent.screen": "false"}}, sys.stdout)
PY
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/scope.json" "$API/client-scopes" >/dev/null \
    || fail "Keycloak refused to create the client scope $READ_SCOPE"
  scope_id="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/client-scopes" \
    | python3 -c "import sys,json; print(next(s['id'] for s in json.load(sys.stdin) if s['name'] == '$READ_SCOPE'))")"
  echo "› client $MCP_CLIENT: scope $READ_SCOPE created"
fi
if "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid/default-client-scopes" \
  | python3 -c "import sys,json; sys.exit(0 if any(s['name'] == '$READ_SCOPE' for s in json.load(sys.stdin)) else 1)"; then
  echo "› client $MCP_CLIENT: scope $READ_SCOPE assigned"
else
  "${CURL[@]}" -o /dev/null "${HEAD[@]}" "${AUTH[@]}" -X PUT \
    "$API/clients/$client_uuid/default-client-scopes/$scope_id" \
    || fail "Keycloak refused to assign scope $READ_SCOPE to $MCP_CLIENT"
  echo "› client $MCP_CLIENT: scope $READ_SCOPE assigned"
fi

# 6. Prove it against the realm's own endpoints. Nothing here completes a sign-in (that needs a person).
OIDC="$KC/realms/$REALM/protocol/openid-connect"
# PKCE is required on this client, for the device grant as well: every request carries a challenge.
challenge="$(printf 'stardelt-mcp-check-verifier-0123456789-abcdefghijk' | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
device_status="$("${CURL_SOFT[@]}" "${HEAD[@]}" -o "$tmp/device.json" -w '%{http_code}' -X POST "$OIDC/auth/device" \
  --data-urlencode "client_id=$MCP_CLIENT" --data-urlencode "scope=openid" \
  --data-urlencode "code_challenge=$challenge" --data-urlencode "code_challenge_method=S256" 2>/dev/null || true)"
python3 - "$tmp/device.json" "$device_status" <<'PY' || fail "the device endpoint did not hand out a code for $MCP_CLIENT"
import json, sys
status = sys.argv[2]
try:
    body = json.load(open(sys.argv[1]))
except ValueError:
    body = {}
if status != "200" or not all(k in body for k in ("device_code", "user_code", "verification_uri_complete")):
    sys.exit("HTTP %s: %s %s" % (status, body.get("error", "no JSON body"), body.get("error_description", "")))
print("› device endpoint: hands out a code (expires in %ss, polling every %ss)" % (body.get("expires_in"), body.get("interval", 5)))
PY
auth_url() { printf '%s/auth?client_id=%s&response_type=code&scope=openid&state=x&code_challenge=%s&code_challenge_method=S256&redirect_uri=%s' "$OIDC" "$MCP_CLIENT" "$challenge" "$1"; }
ok_code="$("${CURL_SOFT[@]}" "${HEAD[@]}" -o /dev/null -w '%{http_code}' "$(auth_url 'http%3A%2F%2F127.0.0.1%3A54321%2Fcallback')" || true)"
bad_code="$("${CURL_SOFT[@]}" "${HEAD[@]}" -o /dev/null -w '%{http_code}' "$(auth_url 'https%3A%2F%2Fevil.example.com%2Fcb')" || true)"
[ "$ok_code" = 200 ] || fail "a loopback redirect with a port was not accepted (HTTP $ok_code)"
[ "$bad_code" != 200 ] || fail "a redirect to a foreign host was accepted — the redirect list is too wide"
echo "› redirects: loopback with a port accepted, foreign host refused (HTTP $bad_code)"

# The scope must be in the token the realm would mint, not only stored on the client.
user_id="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users?max=20" | python3 -c 'import sys,json
users = [u for u in json.load(sys.stdin) if u.get("enabled") and not u.get("username", "").startswith("service-account-")]
print(users[0]["id"] if users else "")')"
if [ -z "$user_id" ]; then
  echo "› no user in realm $REALM yet: $READ_SCOPE is assigned, the example token could not be checked"
else
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" \
    "$API/clients/$client_uuid/evaluate-scopes/generate-example-access-token?scope=openid&userId=$user_id" \
    > "$tmp/example-scope.json" \
    || fail "Keycloak could not evaluate the example access token for $MCP_CLIENT"
  python3 - "$tmp/example-scope.json" "$READ_SCOPE" "$MCP_CLIENT" <<'PY' || fail "the example access token of $MCP_CLIENT does not carry the scope $READ_SCOPE"
import json, sys
scope = json.load(open(sys.argv[1])).get("scope") or ""
if sys.argv[2] not in scope.split():
    sys.exit("scope is %r" % scope)
print("› client %s: example access token carries scope %s" % (sys.argv[3], sys.argv[2]))
PY
fi
echo "keycloak-sync-mcp-client: OK — client $MCP_CLIENT is enabled"
