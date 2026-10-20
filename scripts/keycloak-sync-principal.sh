#!/usr/bin/env bash
# Converge one Keycloak client per ServicePrincipal, owned by a realm group
# (scheduled jobs, decisions D20/D21, platform#244), or one service client per platform
# component that calls the catalog (KIND=service, platform#282).
#
#   NAME=analytics GROUP=analytics make sync-principal
#   NAME=analytics make delete-principal YES=1
#   KIND=service NAME=catalog-trino make sync-catalog-clients
#   KIND=service NAME=catalog-trino make delete-catalog-clients YES=1
#
# A `ServicePrincipal` (stardelt-operator) names a principal `sp-<name>` and the group
# that owns it. Scheduled pipelines run as that client, never as a person and never as
# the shared `pipeline-runner`; the token carries the owner group, so the catalog's
# group policy applies to scheduled work exactly like to a person.
#
# KIND=service names a platform component instead of a person: client and Secret are
# `svc-<name>`, there is no owner group and no `groups` mapper, GROUP is ignored, the
# default audience is `lakekeeper`, and the client carries `stardelt-managed=service`.
# Every caller of the catalog (Trino, Nova, Spark, Airflow task pods, the bootstrap Job)
# gets its own such client, so the catalog can tell them apart and revoke one at a time.
#
# The Secret (`sp-<NAME>` or `svc-<NAME>`) in the namespace is the source of truth for
# the client secret: this script creates client and Secret together when the Secret is
# missing, converges Keycloak onto an existing Secret's value, rotates with ROTATE=1,
# keeps one audience mapper per requested audience (plus a `groups` mapper for a
# principal), makes a principal's service-account user a member of GROUP and of no other
# group, gives a service client no group at all, and refuses a service account with an
# admin-API role. Idempotent. A service client's Secret also carries `token-url` (the
# realm's endpoint) beside `client-id` and `client-secret`, so the consumers that take
# all three from one object — Nova, the Airflow task pods — see them appear and
# disappear together. Reaches Keycloak through svc/keycloak (port-forward)
# because the public `/admin` API is closed. Secrets travel only through files under a
# mode-0700 temp dir and `--data @file` bodies, never argv, stdout or a log line; the
# token claims printed at the end are not secret.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
KIND="${KIND:-principal}"
NAME="${NAME:-}"
GROUP="${GROUP:-}"
AUDIENCES="${AUDIENCES:-}"
ROTATE="${ROTATE:-0}"
YES="${YES:-0}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
MANAGEMENT_CLIENT="${MANAGEMENT_CLIENT:-realm-management}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

fail() { echo "keycloak-sync-principal: $*" >&2; exit 1; }

mode=sync
if [ "${1:-}" = "--delete" ]; then
  mode=delete
  shift
fi
[ "$#" -eq 0 ] || fail "unexpected argument '$1' (only --delete is accepted)"

# Validate every input before the first API call. A ServicePrincipal's name becomes
# part of a client id, a Secret name and a token claim; refuse anything else up front.
case "$KIND" in
  principal|service) ;;
  *) fail "refusing KIND '$KIND': use principal (default) or service" ;;
esac
[ -n "$NAME" ] || fail "NAME is required — pass NAME=<principal name>, for example NAME=analytics"
case "$NAME" in
  ""|*[!a-z0-9-]*|[!a-z]*) fail "refusing NAME '$NAME': use 1 to 40 lower-case letters, digits or dashes, starting with a letter" ;;
esac
[ "${#NAME}" -le 40 ] || fail "refusing NAME '$NAME': it is longer than 40 characters"
if [ "$KIND" = service ]; then
  CLIENT_ID="svc-$NAME"
else
  CLIENT_ID="sp-$NAME"
fi
SECRET_NAME="$CLIENT_ID"

if [ "$mode" = sync ]; then
  # A principal is owned by a group; a service client is not (GROUP is ignored).
  if [ "$KIND" = principal ]; then
    [ -n "$GROUP" ] || fail "GROUP is required — pass GROUP=<existing realm group>"
  fi
  if [ -z "$AUDIENCES" ]; then
    if [ "$KIND" = service ]; then AUDIENCES=lakekeeper; else AUDIENCES=trino; fi
  fi
  aud_list=()
  seen=""
  IFS=',' read -r -a raw_audiences <<<"$AUDIENCES"
  for aud in "${raw_audiences[@]}"; do
    case "$aud" in
      trino|lakekeeper) ;;
      *) fail "refusing AUDIENCES entry '$aud': the allowed audiences are trino and lakekeeper" ;;
    esac
    case " $seen " in
      *" $aud "*) continue ;;
    esac
    aud_list+=("$aud")
    seen="$seen $aud"
  done
  [ "${#aud_list[@]}" -gt 0 ] || fail "AUDIENCES is empty — use a comma list from trino,lakekeeper"
fi

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "keycloak-sync-principal: $tool not found" >&2; exit 1; }
done

# A service client's Secret also carries the realm's token endpoint. The consumers of
# these clients (Nova, the Airflow task pods) must see all three keys together: Nova
# refuses to start on a partial configuration (stardelt-nova#222) and a loader must fall
# back to anonymous only when the whole client is absent, and an optional env reference
# cannot make one variable conditional on another. Deriving the URL here is what keeps
# the id, the secret and the endpoint in one object that appears or disappears at once;
# taking it from ConfigMap stardelt-identity would leave "ConfigMap present, Secret
# missing" as a partial state. The issuer is the platform's public one, the value every
# component already validates. ISSUER_URL overrides it (tests, an external IdP).
TOKEN_URL=""
if [ "$KIND" = service ] && [ "$mode" = sync ]; then
  issuer="${ISSUER_URL:-}"
  if [ -z "$issuer" ]; then
    issuer="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity \
      -o jsonpath='{.data.issuerUrl}' 2>/dev/null || true)"
  fi
  case "$issuer" in
    https://*) ;;
    *) fail "no realm issuer: ConfigMap $NAMESPACE/stardelt-identity has no https issuerUrl (run 'make install-identity') and ISSUER_URL is not set" ;;
  esac
  TOKEN_URL="${issuer%/}/protocol/openid-connect/token"
fi

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# 1. Reach the admin API on loopback, through the Service.
local_port=18260
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

for _ in $(seq 1 30); do
  status="$("${CURL_SOFT[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$API" || true)"
  [ "$status" = 200 ] && break
  sleep 2
done
[ "$status" = 200 ] || fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"

# 3. Delete mode: only a client this script created (attribute stardelt-managed equal to
#    KIND) may be deleted, and only with YES=1. Anything else is reported and left alone.
if [ "$mode" = delete ]; then
  client_uuid="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$CLIENT_ID" \
    | python3 -c 'import sys,json
clients = json.load(sys.stdin)
print(clients[0]["id"] if clients else "")')"
  [ -n "$client_uuid" ] || fail "client $CLIENT_ID does not exist in realm $REALM — nothing to delete"
  marker="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid" \
    | python3 -c 'import sys,json
print((json.load(sys.stdin).get("attributes") or {}).get("stardelt-managed", ""))')"
  [ "$marker" = "$KIND" ] \
    || fail "refusing to delete client $CLIENT_ID: it does not carry stardelt-managed=$KIND (not created by this script for KIND=$KIND)"
  if [ "$YES" != 1 ]; then
    echo "would delete client $CLIENT_ID in realm $REALM and Secret $NAMESPACE/$SECRET_NAME — re-run with YES=1"
    exit 1
  fi
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -X DELETE "$API/clients/$client_uuid" >/dev/null \
    || fail "Keycloak refused to delete client $CLIENT_ID"
  kubectl -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found >/dev/null \
    || fail "client $CLIENT_ID was deleted but Secret $NAMESPACE/$SECRET_NAME could not be removed"
  echo "› client $CLIENT_ID: deleted"
  echo "› secret $NAMESPACE/$SECRET_NAME: deleted"
  echo "keycloak-sync-principal: OK — $CLIENT_ID and its Secret are gone"
  exit 0
fi

# 4. The owner group must already exist. Groups are managed by people, not by this
#    script: an unknown group is a typo, and creating it silently would grant a
#    principal rights nobody asked for. A service client has no owner group.
group_id=""
if [ "$KIND" = principal ]; then
  group_json="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" --get \
    --data-urlencode "search=$GROUP" --data-urlencode 'briefRepresentation=true' \
    "$API/groups")" \
    || fail "cannot list groups in realm $REALM"
  group_id="$(python3 -c 'import sys,json
groups = json.load(sys.stdin)
print(next((g["id"] for g in groups if g.get("name") == sys.argv[1]), ""))' "$GROUP" <<<"$group_json")"
  [ -n "$group_id" ] || fail "group $GROUP does not exist in realm $REALM"
fi

# 5. The Secret is the source of truth for the client secret. Read it when present;
#    otherwise (or on ROTATE) generate 40 characters and keep them in the temp dir.
secret_present=""
token_url_updated=""
if kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  secret_present=1
  kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.client-secret}' \
    | base64 -d > "$tmp/client-secret" || true
  [ -s "$tmp/client-secret" ] || fail "Secret $NAMESPACE/$SECRET_NAME has no non-empty client-secret key — delete it and re-run to generate one"
  stored_client_id="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.client-id}' | base64 -d || true)"
  [ "$stored_client_id" = "$CLIENT_ID" ] \
    || fail "Secret $NAMESPACE/$SECRET_NAME has client-id '$stored_client_id', expected '$CLIENT_ID'"
  # Converge the endpoint without touching the secret (so a rerun that changes nothing
  # leaves the Secret's resourceVersion alone). Existing Secrets predate the key.
  if [ -n "$TOKEN_URL" ] && [ "$ROTATE" != 1 ]; then
    stored_token_url="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
      -o jsonpath='{.data.token-url}' | base64 -d || true)"
    if [ "$stored_token_url" != "$TOKEN_URL" ]; then
      kubectl -n "$NAMESPACE" patch secret "$SECRET_NAME" --type=merge \
        -p "{\"stringData\":{\"token-url\":\"$TOKEN_URL\"}}" >/dev/null \
        || fail "Secret $NAMESPACE/$SECRET_NAME cannot be given its token-url"
      token_url_updated=1
    fi
  fi
fi
if [ -z "$secret_present" ] || [ "$ROTATE" = 1 ]; then
  python3 > "$tmp/client-secret" <<'PY'
import secrets, string, sys
alphabet = string.ascii_letters + string.digits
sys.stdout.write("".join(secrets.choice(alphabet) for _ in range(40)))
PY
fi

# 6. Find or create the client. A client this script creates is confidential,
#    service-account only, has no interactive flow and no redirects, and carries
#    stardelt-managed=principal or =service so delete-principal can recognise it.
client_uuid="$("${CURL_SOFT[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$CLIENT_ID" \
  | python3 -c 'import sys,json
clients = json.load(sys.stdin)
print(clients[0]["id"] if clients else "")')"
if [ -z "$client_uuid" ]; then
  python3 - "$tmp/client-secret" "$CLIENT_ID" "$KIND" "$GROUP" "${aud_list[@]}" > "$tmp/client-create.json" <<'PY'
import json, sys
secret = open(sys.argv[1]).read()
client_id = sys.argv[2]
kind = sys.argv[3]
group = sys.argv[4]
audiences = sys.argv[5:]
mappers = [{
    "name": "aud-" + aud,
    "protocol": "openid-connect",
    "protocolMapper": "oidc-audience-mapper",
    "consentRequired": False,
    "config": {
        "included.custom.audience": aud,
        "id.token.claim": "false",
        "access.token.claim": "true",
        "introspection.token.claim": "true",
    },
} for aud in audiences]
if kind != "service":
    mappers.append({
        "name": "groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "consentRequired": False,
        "config": {
            "claim.name": "groups",
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true",
            "introspection.token.claim": "true",
        },
    })
sys.stdout.write(json.dumps({
    "clientId": client_id,
    "name": ("Service client " if kind == "service" else "Service principal ") + client_id,
    "description": ("Platform service client used by a component, not a person (platform#282)."
                    if kind == "service"
                    else "Service principal owned by group %s (scheduled jobs, D20/D21)." % group),
    "enabled": True,
    "protocol": "openid-connect",
    "publicClient": False,
    "clientAuthenticatorType": "client-secret",
    "secret": secret,
    "standardFlowEnabled": False,
    "implicitFlowEnabled": False,
    "directAccessGrantsEnabled": False,
    "serviceAccountsEnabled": True,
    "redirectUris": [],
    "webOrigins": [],
    "attributes": {"stardelt-managed": kind},
    "protocolMappers": mappers,
}))
PY
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST --data @"$tmp/client-create.json" "$API/clients" >/dev/null \
    || fail "Keycloak refused to create client $CLIENT_ID"
  client_uuid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$CLIENT_ID" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "› client $CLIENT_ID: created"
else
  echo "› client $CLIENT_ID: exists"
fi

# 7. Converge the client's shape and the secret. The Secret wins; a drifted Keycloak
#    is updated to its value, and ROTATE writes the new value to Keycloak first, then
#    to the Secret, so a failed run never leaves the Secret ahead of the realm.
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid" > "$tmp/client.json"
python3 - "$tmp/client.json" "$tmp/client-update.json" "$KIND" <<'PY'
import json, sys
client = json.load(open(sys.argv[1]))
kind = sys.argv[3]
update = {}
if client.get("enabled") is not True:
    update["enabled"] = True
if client.get("protocol") != "openid-connect":
    update["protocol"] = "openid-connect"
if client.get("publicClient") is not False:
    update["publicClient"] = False
if client.get("clientAuthenticatorType") != "client-secret":
    update["clientAuthenticatorType"] = "client-secret"
for key in ("standardFlowEnabled", "implicitFlowEnabled", "directAccessGrantsEnabled"):
    if client.get(key) is not False:
        update[key] = False
if client.get("serviceAccountsEnabled") is not True:
    update["serviceAccountsEnabled"] = True
if client.get("redirectUris"):
    update["redirectUris"] = []
if client.get("webOrigins"):
    update["webOrigins"] = []
attributes = dict(client.get("attributes") or {})
if attributes.get("stardelt-managed") != kind:
    attributes["stardelt-managed"] = kind
    update["attributes"] = attributes
if update:
    json.dump(update, open(sys.argv[2], "w"))
PY
if [ -s "$tmp/client-update.json" ]; then
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT --data @"$tmp/client-update.json" "$API/clients/$client_uuid" >/dev/null \
    || fail "Keycloak refused the shape update for client $CLIENT_ID"
  echo "› client $CLIENT_ID: shape converged"
else
  echo "› client $CLIENT_ID: shape matches"
fi

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
  echo "› client $CLIENT_ID: secret matches"
else
  python3 - "$tmp/client-secret" > "$tmp/client-secret-write.json" <<'PY'
import json, sys
sys.stdout.write(json.dumps({"secret": open(sys.argv[1]).read()}))
PY
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT --data @"$tmp/client-secret-write.json" "$API/clients/$client_uuid" >/dev/null \
    || fail "Keycloak refused the secret update for client $CLIENT_ID — check 'kubectl -n $NAMESPACE logs deploy/keycloak'"
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid/client-secret" \
    > "$tmp/stored-after.json" \
    || fail "cannot read client $CLIENT_ID's secret back after the update"
  python3 - "$tmp/stored-after.json" "$tmp/client-secret" "$CLIENT_ID" <<'PY' \
    || fail "client $CLIENT_ID reads back a different secret than the Secret holds"
import json, sys
stored = json.load(open(sys.argv[1])).get("value")
wanted = open(sys.argv[2]).read()
if stored != wanted:
    sys.exit(1)
print("› client %s: secret updated" % sys.argv[3])
PY
fi

# 8. Persist the Secret when it was created here or when ROTATE asked for a new value.
#    The value travels through a file, never argv; a mode-0700 temp dir holds it.
if [ -z "$secret_present" ] || [ "$ROTATE" = 1 ]; then
  secret_args=(--from-literal="client-id=$CLIENT_ID" --from-file="client-secret=$tmp/client-secret")
  [ -z "$TOKEN_URL" ] || secret_args+=(--from-literal="token-url=$TOKEN_URL")
  kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    "${secret_args[@]}" \
    --dry-run=client -o json > "$tmp/secret.json"
  python3 - "$tmp/secret.json" "$tmp/secret-final.json" "$NAME" <<'PY'
import json, sys
secret = json.load(open(sys.argv[1]))
secret.setdefault("metadata", {})["labels"] = {
    "app.kubernetes.io/part-of": "stardelt",
    "stardelt.io/principal": sys.argv[3],
}
json.dump(secret, open(sys.argv[2], "w"))
PY
  kubectl -n "$NAMESPACE" apply -f "$tmp/secret-final.json" >/dev/null \
    || fail "client $CLIENT_ID was converged but Secret $NAMESPACE/$SECRET_NAME could not be written"
  if [ -z "$secret_present" ]; then
    echo "› secret $NAMESPACE/$SECRET_NAME: created"
  else
    echo "› secret $NAMESPACE/$SECRET_NAME: rotated"
  fi
fi
if [ -n "$token_url_updated" ]; then
  echo "› secret $NAMESPACE/$SECRET_NAME: token-url converged"
fi

# 9. One audience mapper per requested audience, and — for a principal — a groups mapper
#    so the token carries the owner group. Audience mappers for audiences no longer
#    requested are removed, and a service client carries no groups mapper at all;
#    nothing else is touched.
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid" > "$tmp/client-mappers.json"
python3 - "$tmp/client-mappers.json" "$tmp" "$tmp/mapper-plan" "$KIND" "${aud_list[@]}" <<'PY'
import json, os, sys
client = json.load(open(sys.argv[1]))
outdir = sys.argv[2]
plan_path = sys.argv[3]
kind = sys.argv[4]
audiences = sys.argv[5:]
desired = [{
    "name": "aud-" + aud,
    "protocol": "openid-connect",
    "protocolMapper": "oidc-audience-mapper",
    "consentRequired": False,
    "config": {
        "included.custom.audience": aud,
        "id.token.claim": "false",
        "access.token.claim": "true",
        "introspection.token.claim": "true",
    },
} for aud in audiences]
groups_mapper = {
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "consentRequired": False,
    "config": {
        "claim.name": "groups",
        "full.path": "false",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "introspection.token.claim": "true",
    },
}
if kind != "service":
    desired.append(groups_mapper)
existing = {m.get("name"): m for m in client.get("protocolMappers") or []}
plan = []
for mapper in desired:
    found = existing.get(mapper["name"])
    path = os.path.join(outdir, "mapper-" + mapper["name"] + ".json")
    if found is None:
        json.dump(mapper, open(path, "w"))
        plan.append(("add", mapper["name"], ""))
        continue
    same = found.get("protocolMapper") == mapper["protocolMapper"] and all(
        (found.get("config") or {}).get(key) == value
        for key, value in mapper["config"].items())
    if same:
        plan.append(("present", mapper["name"], ""))
    else:
        mapper["id"] = found["id"]
        json.dump(mapper, open(path, "w"))
        plan.append(("update", mapper["name"], found["id"]))
wanted = {mapper["name"] for mapper in desired}
for name, mapper in existing.items():
    remove = name.startswith("aud-") and name not in wanted
    if kind == "service" and name == "groups":
        remove = True
    if remove:
        plan.append(("remove", name, mapper["id"]))
with open(plan_path, "w") as handle:
    for action, name, mapper_id in plan:
        handle.write("%s\t%s\t%s\n" % (action, name, mapper_id))
PY
while IFS=$'\t' read -r action mapper_name mapper_id; do
  [ -n "$mapper_name" ] || continue
  mapper_file="$tmp/mapper-$mapper_name.json"
  case "$action" in
    present)
      echo "› mapper $mapper_name: present"
      ;;
    add)
      "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
        -X POST --data @"$mapper_file" "$API/clients/$client_uuid/protocol-mappers/models" >/dev/null \
        || fail "Keycloak refused mapper $mapper_name for client $CLIENT_ID"
      echo "› mapper $mapper_name: added"
      ;;
    update)
      "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
        -X PUT --data @"$mapper_file" "$API/clients/$client_uuid/protocol-mappers/models/$mapper_id" >/dev/null \
        || fail "Keycloak refused to update mapper $mapper_name for client $CLIENT_ID"
      echo "› mapper $mapper_name: updated"
      ;;
    remove)
      "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -X DELETE \
        "$API/clients/$client_uuid/protocol-mappers/models/$mapper_id" >/dev/null \
        || fail "Keycloak refused to remove mapper $mapper_name from client $CLIENT_ID"
      echo "› mapper $mapper_name: removed (no longer wanted)"
      ;;
    *)
      fail "internal error: unknown mapper action '$action'"
      ;;
  esac
done < "$tmp/mapper-plan"

# 10. A principal's service-account user belongs to the owner group and to no other
#     group; a service client has no group membership at all (it is not owned by a group).
sa_uid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$client_uuid/service-account-user" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')" \
  || fail "client $CLIENT_ID has no service-account user — is serviceAccountsEnabled on?"
if [ "$KIND" = service ]; then
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users/$sa_uid/groups" > "$tmp/user-groups.json"
  group_plan="$(python3 - "$tmp/user-groups.json" <<'PY'
import json, sys
groups = json.load(open(sys.argv[1]))
for group in groups:
    print("%s\t%s" % (group["id"], group.get("name", group["id"])))
PY
)"
  if [ -z "$group_plan" ]; then
    echo "› service account: no group membership"
  else
    printf '%s\n' "$group_plan" | while IFS=$'\t' read -r extra_id extra_name; do
      "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -X DELETE \
        "$API/users/$sa_uid/groups/$extra_id" >/dev/null \
        || fail "Keycloak refused to remove the service account from group $extra_name"
      echo "› service account: removed from $extra_name (a service client has no group)"
    done
  fi
else
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users/$sa_uid/groups" > "$tmp/user-groups.json"
  group_plan="$(python3 - "$tmp/user-groups.json" "$group_id" <<'PY'
import json, sys
groups = json.load(open(sys.argv[1]))
target = sys.argv[2]
ids = {group["id"] for group in groups}
print("add" if target not in ids else "present")
for group in groups:
    if group["id"] != target:
        print("remove\t%s\t%s" % (group["id"], group.get("name", group["id"])))
PY
)"
  group_action="$(printf '%s\n' "$group_plan" | head -n 1)"
  if [ "$group_action" = add ]; then
    "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -X PUT \
      "$API/users/$sa_uid/groups/$group_id" >/dev/null \
      || fail "Keycloak refused to add the service account to group $GROUP"
    echo "› service account: added to $GROUP"
  else
    echo "› service account: member of $GROUP"
  fi
  printf '%s\n' "$group_plan" | while IFS=$'\t' read -r action extra_id extra_name; do
    [ "$action" = remove ] || continue
    "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -X DELETE \
      "$API/users/$sa_uid/groups/$extra_id" >/dev/null \
      || fail "Keycloak refused to remove the service account from group $extra_name"
    echo "› service account: removed from $extra_name"
  done
fi

# 11. The service account must hold no admin-API role. A ServicePrincipal reads and
#     writes data through the engine; it never manages the identity provider.
mgmt_uuid="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$MANAGEMENT_CLIENT" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')" \
  || fail "realm $REALM has no client '$MANAGEMENT_CLIENT' — the realm import is incomplete"
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users/$sa_uid/role-mappings/clients/$mgmt_uuid" | python3 -c '
import json, sys
roles = sorted(role["name"] for role in json.load(sys.stdin))
if roles:
    sys.exit("the service account holds admin-API roles it must not have: " + ", ".join(roles))
print("› service account holds no admin-API role")
' || fail "client $CLIENT_ID's service account is too powerful — remove its $MANAGEMENT_CLIENT roles"

# 12. Prove it with the client's own token: a client-credentials grant, then the claims
#     the catalog and engines rely on. Only non-secret claims are printed.
cc_token="$("${CURL_SOFT[@]}" "${HEAD[@]}" -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret@$tmp/client-secret" 2>/dev/null \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")' 2>/dev/null || true)"
[ -n "$cc_token" ] || fail "the token endpoint refused the $CLIENT_ID client credentials — the secret did not stick"
printf '%s' "$cc_token" > "$tmp/cc-token"
python3 - "$tmp/cc-token" "$CLIENT_ID" "$KIND" "$GROUP" "${aud_list[@]}" <<'PY' \
  || fail "the $CLIENT_ID token does not carry what the client needs"
import base64, json, sys
payload = open(sys.argv[1]).read().split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
client, kind, group, wanted = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
audiences = claims.get("aud") if isinstance(claims.get("aud"), list) else [claims.get("aud")]
groups = claims.get("groups") or []
problems = []
if claims.get("azp") != client:
    problems.append("azp is %r" % claims.get("azp"))
for audience in wanted:
    if audience not in audiences:
        problems.append("audience lacks %s (aud=%s)" % (audience, audiences))
if kind == "service":
    if groups:
        problems.append("groups is %r (a service client has no group)" % groups)
else:
    if sorted(groups) != [group]:
        problems.append("groups is %r (expected [%s])" % (groups, group))
if claims.get("preferred_username") != "service-account-" + client:
    problems.append("preferred_username is %r" % claims.get("preferred_username"))
if problems:
    sys.exit("; ".join(problems))
lifetime = claims.get("exp", 0) - claims.get("iat", 0)
if kind == "service":
    print("› token claims: azp=%s aud=%s" % (claims["azp"], audiences))
else:
    print("› token claims: azp=%s aud=%s groups=%s preferred_username=%s exp-iat=%s" % (
        claims["azp"], audiences, groups, claims["preferred_username"], lifetime))
PY
if [ "$KIND" = service ]; then
  echo "keycloak-sync-principal: OK — $CLIENT_ID is a confidential service client with audiences [${aud_list[*]}], no group membership and no admin role"
else
  echo "keycloak-sync-principal: OK — $CLIENT_ID is confidential, owned by group $GROUP, with audiences [${aud_list[*]}] and no admin role"
fi
