#!/usr/bin/env bash
# Prove that the realm-admin credential the README documents still opens realm
# `stardelt` — i.e. that Secret `stardelt-realm-admin` and the live Keycloak do
# not disagree (stardelt-platform#81).
#
#   NAMESPACE=stardelt bash scripts/verify-realm-admin.sh
#
# Three checks:
#   1. realm `stardelt` and the user the Secret names exist and are enabled;
#   2. a real password grant with the Secret's value is accepted — this is the
#      check that would have caught #81, and the only way to test a password
#      (Keycloak never returns a stored one, so an admin-API-only check would
#      prove the master admin instead);
#   3. the user is still in group `stardelt-admins`, so signing in actually is
#      the platform-admin login the Secret is documented to be.
#
# The grant runs inside the cluster (`kubectl port-forward svc/keycloak`) with
# client `admin-cli`: Keycloak creates it in every realm with direct access
# grants enabled, and `kcadm` depends on it. The app clients (`nova`, `trino`,
# `superset`, …) keep direct grants off on purpose and are not touched.
#
# Exits non-zero with the recovery command when the grant is rejected. Secrets
# are read into files under a mode-0700 temp dir and never printed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
REALM_ADMIN_SECRET="${REALM_ADMIN_SECRET:-stardelt-realm-admin}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
PROBE_CLIENT="${PROBE_CLIENT:-admin-cli}"
ADMIN_GROUP="${ADMIN_GROUP:-stardelt-admins}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify-realm-admin: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "verify-realm-admin: $*" >&2; exit 1; }

local_port=18170
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

strip_scheme() { printf '%s' "$1" | sed -E 's|https?://||; s|/.*||'; }
KC_HOST="$(strip_scheme "$(kubectl -n "$NAMESPACE" get configmap keycloak-env -o jsonpath='{.data.KC_HOSTNAME}' 2>/dev/null || true)")"
[ -n "$KC_HOST" ] || fail "ConfigMap keycloak-env has no KC_HOSTNAME — run 'make install-identity'"
HEAD=(-H "X-Forwarded-Host: $KC_HOST" -H 'X-Forwarded-Proto: https')

kubectl -n "$NAMESPACE" get secret "$MASTER_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/master-pw" \
  || fail "cannot read Secret $MASTER_SECRET"
kubectl -n "$NAMESPACE" get secret "$REALM_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/realm-pw" \
  || fail "cannot read Secret $REALM_ADMIN_SECRET"
[ -s "$tmp/realm-pw" ] || fail "Secret $REALM_ADMIN_SECRET has an empty password"
realm_admin="$(kubectl -n "$NAMESPACE" get secret "$REALM_ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || true)"
realm_admin="${realm_admin:-admin}"

echo "› 1/3 realm $REALM and user '$realm_admin' exist and are enabled (master token)"
master_token="$("${CURL[@]}" "${HEAD[@]}" -X POST "$KC/realms/master/protocol/openid-connect/token" \
  --data-urlencode "username=admin" --data-urlencode "password@$tmp/master-pw" \
  --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')" \
  || fail "the master realm refused Secret $MASTER_SECRET — cannot inspect realm $REALM"
AUTH=(-H "Authorization: Bearer $master_token")
API="$KC/admin/realms/$REALM"
user_json="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users?username=$realm_admin&exact=true")" \
  || fail "realm $REALM is missing — run 'make install-identity' and check 'kubectl -n $NAMESPACE logs deploy/keycloak'"
printf '%s' "$user_json" | python3 -c 'import sys,json
users = json.load(sys.stdin)
if len(users) != 1:
    sys.exit("expected one user, found %d" % len(users))
if not users[0].get("enabled", False):
    sys.exit("user is disabled")' \
  || fail "realm $REALM has no single enabled user '$realm_admin'"
user_id="$(printf '%s' "$user_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
echo "  realm present, user present and enabled"

echo "› 2/3 password grant as '$realm_admin' through client $PROBE_CLIENT (inside the cluster)"
code="$("${CURL_SOFT[@]}" -o "$tmp/grant.json" -w '%{http_code}' "${HEAD[@]}" \
  -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode "username=$realm_admin" --data-urlencode "password@$tmp/realm-pw" \
  --data-urlencode "client_id=$PROBE_CLIENT" --data-urlencode "grant_type=password" || true)"
case "$code" in
  200)
    python3 -c 'import sys,json
d = json.load(open(sys.argv[1]))
if not d.get("access_token"):
    sys.exit("no access_token in the response")
print("  HTTP 200: an access token was issued (expires_in=%s)" % d.get("expires_in"))' "$tmp/grant.json" \
      || fail "the token endpoint answered 200 without a token — check the keycloak log"
    ;;
  400)
    error="$(python3 -c 'import sys,json;d=json.load(open(sys.argv[1]));print(d.get("error") or "unknown")' "$tmp/grant.json" 2>/dev/null || echo unknown)"
    description="$(python3 -c 'import sys,json;d=json.load(open(sys.argv[1]));print(d.get("error_description") or "")' "$tmp/grant.json" 2>/dev/null || true)"
    if [ "$error" = invalid_grant ]; then
      fail "the password in Secret $REALM_ADMIN_SECRET is not the realm's password for user '$realm_admin' ($description).
  Realm $REALM is healthy, so this is exactly the #81 drift: the realm imported an older value.
  Fix: make sync-realm-admin   # re-applies the Secret's current value, idempotent"
    elif [ "$error" = unauthorized_client ]; then
      fail "client $PROBE_CLIENT in realm $REALM refuses direct access grants ($description), so this password cannot be
  proven non-interactively. It is Keycloak's per-realm default client and kcadm's own client; enable direct
  access grants on it, or verify by signing in interactively at the realm's account console."
    else
      fail "the password grant was rejected: $error $description"
    fi
    ;;
  ""|000)
    fail "Keycloak did not answer the token request — check 'kubectl -n $NAMESPACE get pods' and the keycloak log"
    ;;
  *)
    fail "the token endpoint answered HTTP $code: $(head -c 200 "$tmp/grant.json")"
    ;;
esac

echo "› 3/3 '$realm_admin' is still in group '$ADMIN_GROUP' (what makes the login an admin)"
groups="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users/$user_id/groups" \
  | python3 -c 'import sys,json;print(",".join(sorted(g["name"] for g in json.load(sys.stdin))))')"
case ",$groups," in
  *",$ADMIN_GROUP,"*) echo "  groups: $groups" ;;
  *) fail "user '$realm_admin' exists and the password works, but it is not in '$ADMIN_GROUP' (groups: ${groups:-none}).
  It would sign in without platform-admin rights; re-apply the realm's group membership in the Keycloak admin console." ;;
esac

echo "verify-realm-admin: OK — Secret $REALM_ADMIN_SECRET opens realm $REALM as '$realm_admin' and that user is an admin"
