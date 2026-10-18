#!/usr/bin/env bash
# Converge the live Keycloak realm onto the realm-admin credential that Secret
# `stardelt-realm-admin` holds.
#
#   NAMESPACE=stardelt bash scripts/sync-realm-admin.sh
#
# Why this exists (stardelt-platform#81): `--import-realm` substitutes
# ${STARDELT_REALM_ADMIN_PASSWORD} *once*, on the first start that creates realm
# `stardelt`, and never looks at it again. The Secret, however, can be
# regenerated later — delete it to rotate, or re-run scripts/identity-bootstrap.sh
# after a re-provision — and nothing re-imports the realm, so the documented way
# in keeps failing with "Invalid username or password" while every other signal
# (analyst login, Superset, Airflow, Nova) stays green. The Secret is the source
# of truth; this script re-applies its current value through the master-realm
# admin API, so the install path can heal that drift instead of reporting it.
#
# Idempotent and safe on every install: it first performs a real password grant
# with the Secret's value and does nothing at all when that already works.
# Reaches Keycloak through svc/keycloak (port-forward), because the id. ingress
# publishes no /admin on purpose (stardelt-platform#53). Secrets are read into
# files under a mode-0700 temp dir and never printed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
REALM_ADMIN_SECRET="${REALM_ADMIN_SECRET:-stardelt-realm-admin}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
# The per-realm client Keycloak creates in every realm with direct access grants
# on; the realm file never touches it. The probe needs it — see verify-realm-admin.sh.
PROBE_CLIENT="${PROBE_CLIENT:-admin-cli}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "sync-realm-admin: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "sync-realm-admin: $*" >&2; exit 1; }

# 1. Reach the admin API on loopback, through the Service.
local_port=18150
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

# 2. The two credentials, into files (never argv, never stdout).
kubectl -n "$NAMESPACE" get secret "$MASTER_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/master-pw" \
  || fail "cannot read Secret $MASTER_SECRET — run 'make install-identity'"
kubectl -n "$NAMESPACE" get secret "$REALM_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/realm-pw" \
  || fail "cannot read Secret $REALM_ADMIN_SECRET — run 'make install-identity'"
[ -s "$tmp/realm-pw" ] || fail "Secret $REALM_ADMIN_SECRET has an empty password"
realm_admin="$(kubectl -n "$NAMESPACE" get secret "$REALM_ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || true)"
realm_admin="${realm_admin:-admin}"

# 3. Master-realm token. Retry: the Service can accept a connection while Keycloak
#    is still finishing its boot (the install calls this right after rollout).
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
[ -n "$master_token" ] || fail "the master realm refused the $MASTER_SECRET credential — Keycloak is not reachable through svc/keycloak, or that Secret drifted too"
AUTH=(-H "Authorization: Bearer $master_token")
API="$KC/admin/realms/$REALM"

# 4. The realm may not exist yet on the very first boot (import runs during
#    startup); wait for it rather than resetting a credential into nothing.
for _ in $(seq 1 30); do
  status="$("${CURL_SOFT[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$API" || true)"
  [ "$status" = 200 ] && break
  sleep 2
done
[ "$status" = 200 ] || fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"

# try_grant: 0 = the Secret opens the realm, 1 = rejected, 2 = cannot tell
# (client forbids direct grants, or Keycloak answered something unexpected).
try_grant() {
  local code
  code="$("${CURL_SOFT[@]}" -o "$tmp/grant.json" -w '%{http_code}' "${HEAD[@]}" \
    -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode "username=$realm_admin" --data-urlencode "password@$tmp/realm-pw" \
    --data-urlencode "client_id=$PROBE_CLIENT" --data-urlencode "grant_type=password" || true)"
  if [ "$code" = 200 ]; then
    return 0
  elif [ "$code" = 400 ] && grep -q '"invalid_grant"' "$tmp/grant.json"; then
    return 1
  else
    return 2
  fi
}

if try_grant; then
  echo "› realm $REALM user '$realm_admin': already opens with Secret $REALM_ADMIN_SECRET — nothing to do"
  exit 0
fi

# 5. Find the user and reset its password to the Secret's value. `temporary:
#    false` on purpose: an operator reading the Secret out of the cluster must
#    not be forced through a password-change screen.
user_json="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/users?username=$realm_admin&exact=true")" \
  || fail "cannot list users of realm $REALM — check that the master admin still works: 'make verify-realm-admin'"
user_id="$(printf '%s' "$user_json" | python3 -c 'import sys,json
users = json.load(sys.stdin)
if len(users) != 1:
    sys.exit("expected exactly one user, found %d" % len(users))
print(users[0]["id"])')" \
  || fail "realm $REALM has no single user '$realm_admin' — the realm import did not complete; check 'kubectl -n $NAMESPACE logs deploy/keycloak'"

python3 - "$tmp/realm-pw" > "$tmp/reset-password.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    value = handle.read().rstrip("\n")
print(json.dumps({"type": "password", "value": value, "temporary": False}))
PY
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -X PUT --data @"$tmp/reset-password.json" "$API/users/$user_id/reset-password" >/dev/null \
  || fail "Keycloak refused the password reset for user '$realm_admin' — check 'kubectl -n $NAMESPACE logs deploy/keycloak'"

# 6. Prove it. A reset that Keycloak accepted but that does not authenticate is
#    the failure this script exists to prevent, so never report success blind.
grant_status=0
try_grant || grant_status=$?
case "$grant_status" in
  0)
    echo "› realm $REALM user '$realm_admin': password reset to the value in Secret $REALM_ADMIN_SECRET"
    ;;
  1)
    fail "reset was accepted but the password grant still fails — Secret $REALM_ADMIN_SECRET and realm $REALM disagree; check 'kubectl -n $NAMESPACE logs deploy/keycloak'"
    ;;
  *)
    grant_reason="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("error_description") or d.get("error") or "unknown")' "$tmp/grant.json" 2>/dev/null || echo "no response")"
    echo "› realm $REALM user '$realm_admin': password reset to the value in Secret $REALM_ADMIN_SECRET"
    echo "  (grant not checked: $PROBE_CLIENT answered '$grant_reason' — direct access grants are off on it;"
    echo "   run 'make verify-realm-admin' once a client allows them, or sign in interactively)"
    ;;
esac
