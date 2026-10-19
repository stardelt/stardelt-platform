#!/usr/bin/env bash
# Converge the live Keycloak realm so the tokens that reach the secret store carry its audience
# (platform#160, decision D27). The store's JWT sign-in accepts a token only when `aud` contains
# `openbao`; the clients whose users read or write connections — Nova, the notebook hub and the
# developer client — get an audience mapper named `aud-openbao`.
#
#   NAMESPACE=stardelt bash scripts/keycloak-sync-store-audience.sh
#
# Why a script: `--import-realm` creates a client's mappers on a fresh realm only. This one adds the
# mapper where it is missing, brings a drifted one back, and proves the result with Keycloak's own
# "evaluate" call (an example access token for a real user, no password involved). Idempotent.
# The mapper uses `included.custom.audience`: the `included.client.audience` variant emits nothing
# when no client of that name exists, and no client is called `openbao`. Reaches Keycloak through
# svc/keycloak (port-forward) because the public `/admin` API is closed; secrets travel only through
# files under a mode-0700 temp dir.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
STORE_AUDIENCE="${STORE_AUDIENCE:-openbao}"
STORE_CLIENTS="${STORE_CLIENTS:-nova jupyterhub stardelt-dev}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "keycloak-sync-store-audience: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "keycloak-sync-store-audience: $*" >&2; exit 1; }

case "$STORE_AUDIENCE" in
  *[!a-z0-9-]*|"") fail "refusing an audience named '$STORE_AUDIENCE' (lower-case letters, digits and dashes only)" ;;
esac

# 1. Reach the admin API on loopback, through the Service.
local_port=18240
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

# 2. Master-realm token. Retry: the Service can accept a connection while Keycloak
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

status=""
for _ in $(seq 1 30); do
  status="$("${CURL_SOFT[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$API" || true)"
  [ "$status" = 200 ] && break
  sleep 2
done
[ "$status" = 200 ] || fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"

# 3. The mapper, per client. By name: missing is added, a different audience or claim flag is restored.
MAPPER="aud-$STORE_AUDIENCE"
python3 - "$MAPPER" "$STORE_AUDIENCE" > "$tmp/mapper.json" <<'PY'
import json, sys
json.dump({"name": sys.argv[1], "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
           "consentRequired": False,
           "config": {"included.custom.audience": sys.argv[2], "id.token.claim": "false",
                      "access.token.claim": "true", "introspection.token.claim": "true"}}, sys.stdout)
PY

uuids=""
for client in $STORE_CLIENTS; do
  case "$client" in *[!a-z0-9-]*|"") fail "refusing a client named '$client'" ;; esac
  uuid="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$client" \
    | python3 -c 'import sys,json
clients = json.load(sys.stdin)
print(clients[0]["id"] if clients else "")')"
  [ -n "$uuid" ] || fail "client $client does not exist in realm $REALM — run 'make install-identity'"
  uuids="$uuids $client=$uuid"

  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$uuid/protocol-mappers/models" > "$tmp/mappers.json"
  action="$(python3 - "$tmp/mappers.json" "$tmp/mapper.json" "$tmp/put.json" <<'PY'
import json, sys
have = {m["name"]: m for m in json.load(open(sys.argv[1]))}
want = json.load(open(sys.argv[2]))
current = have.get(want["name"])
if current is None:
    print("create")
elif (current.get("protocolMapper") != want["protocolMapper"]
        or any((current.get("config") or {}).get(k) != v for k, v in want["config"].items())
        or (current.get("config") or {}).get("included.client.audience")):
    # Keycloak adds keys of its own to a stored config, so only ours are compared. A stray
    # `included.client.audience` next to the custom one makes Keycloak emit nothing: drop it.
    config = {k: v for k, v in (current.get("config") or {}).items() if k != "included.client.audience"}
    config.update(want["config"])
    current["protocolMapper"] = want["protocolMapper"]
    current["config"] = config
    json.dump(current, open(sys.argv[3], "w"))
    print("update")
else:
    print("unchanged")
PY
)"
  case "$action" in
    create)
      "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' -X POST \
        --data @"$tmp/mapper.json" "$API/clients/$uuid/protocol-mappers/models" >/dev/null \
        || fail "Keycloak refused the mapper for client $client"
      echo "› client $client: mapper $MAPPER created" ;;
    update)
      mapper_id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$tmp/put.json")"
      "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' -X PUT \
        --data @"$tmp/put.json" "$API/clients/$uuid/protocol-mappers/models/$mapper_id" >/dev/null \
        || fail "Keycloak refused the mapper update for client $client"
      echo "› client $client: mapper $MAPPER restored" ;;
    *) echo "› client $client: mapper $MAPPER present" ;;
  esac
done

# 4. Prove it: ask Keycloak for the example access token of a real user on each client.
user_id="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users?max=20" | python3 -c 'import sys,json
users = [u for u in json.load(sys.stdin) if u.get("enabled") and not u.get("username", "").startswith("service-account-")]
print(users[0]["id"] if users else "")')"
if [ -z "$user_id" ]; then
  echo "› no user in realm $REALM yet: the mappers are in place, the example token could not be checked"
else
  for pair in $uuids; do
    client="${pair%%=*}"; uuid="${pair#*=}"
    "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" \
      "$API/clients/$uuid/evaluate-scopes/generate-example-access-token?scope=openid&userId=$user_id" > "$tmp/example.json" \
      || fail "Keycloak could not evaluate the example token for client $client"
    python3 - "$tmp/example.json" "$STORE_AUDIENCE" "$client" <<'PY' || fail "the example token of client $client has no audience '$STORE_AUDIENCE'"
import json, sys
aud = json.load(open(sys.argv[1])).get("aud")
aud = [aud] if isinstance(aud, str) else (aud or [])
if sys.argv[2] not in aud:
    sys.exit("aud is %r" % aud)
print("› client %s: example access token carries aud %s" % (sys.argv[3], sys.argv[2]))
PY
  done
fi
echo "keycloak-sync-store-audience: OK — clients ${STORE_CLIENTS// /, } issue tokens for audience $STORE_AUDIENCE"
