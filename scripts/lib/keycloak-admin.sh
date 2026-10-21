#!/usr/bin/env bash
# The Keycloak admin API on loopback, for every script that converges the realm.
#
#   . scripts/lib/keycloak-admin.sh
#
# Not a program: `source` it. It does the four things the realm scripts all need,
# in this order, and nothing else (platform#309):
#
#   1. a port-forward to svc/keycloak on a free loopback port — the public
#      `/admin` API is closed, so this is the only way in;
#   2. the `X-Forwarded-Host`/`X-Forwarded-Proto` headers Keycloak needs in
#      production mode: it answers on its public hostname (KC_HOSTNAME), so a
#      request to 127.0.0.1 has to say which host it is meant for;
#   3. a master-realm token from Secret `keycloak-admin` (MASTER_SECRET),
#      retried while Keycloak finishes its boot;
#   4. a wait until realm `stardelt` exists (the import runs on first boot).
#
# Afterwards a caller has these, all ready to use:
#
#   KC     http://127.0.0.1:<port>
#   HEAD   the forwarded-host headers, as an array for curl
#   AUTH   the bearer header, as an array for curl
#   API    $KC/admin/realms/$REALM
#   KEYCLOAK_ADMIN_TMP  its own mode-0700 temp dir
#
# and MUST call `keycloak_admin_stop` from its own EXIT trap — it kills the
# port-forward and removes that temp dir:
#
#   tmp="$(mktemp -d)"
#   cleanup() { keycloak_admin_stop; rm -rf "$tmp"; }
#   trap cleanup EXIT
#   # shellcheck source=scripts/lib/keycloak-admin.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"
#
# Inputs: NAMESPACE (default `stardelt`), REALM (default `stardelt`),
# MASTER_SECRET (default `keycloak-admin`), KC_LOG_PREFIX (message prefix,
# default `keycloak-admin`; the caller's own name keeps its messages stable).
# The master password and the token travel through files under the temp dir and
# stdin, never argv, stdout or a log line.
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
KC_LOG_PREFIX="${KC_LOG_PREFIX:-keycloak-admin}"

_kc_fail() { echo "$KC_LOG_PREFIX: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || _kc_fail "kubectl not found"
command -v curl >/dev/null 2>&1 || _kc_fail "curl not found"
command -v python3 >/dev/null 2>&1 || _kc_fail "python3 not found"
command -v base64 >/dev/null 2>&1 || _kc_fail "base64 not found"

umask 077
KEYCLOAK_ADMIN_TMP="$(mktemp -d)"
_KC_PF_PID=""

keycloak_admin_stop() {
  if [ -n "${_KC_PF_PID:-}" ]; then
    kill "$_KC_PF_PID" 2>/dev/null || true
    _KC_PF_PID=""
  fi
  [ -z "${KEYCLOAK_ADMIN_TMP:-}" ] || rm -rf "$KEYCLOAK_ADMIN_TMP"
}

_KC_CURL=(curl --silent --show-error --max-time 30)

# 1. Reach the admin API on loopback, through the Service.
_kc_port=18260
while (exec 3<>"/dev/tcp/127.0.0.1/$_kc_port") 2>/dev/null; do
  _kc_port=$((_kc_port + 1))
done
kubectl -n "$NAMESPACE" port-forward svc/keycloak "$_kc_port:8080" >"$KEYCLOAK_ADMIN_TMP/port-forward.log" 2>&1 &
_KC_PF_PID=$!
_kc_ready=""
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$_kc_port") 2>/dev/null; then _kc_ready=1; break; fi
  sleep 0.5
done
[ -n "$_kc_ready" ] || _kc_fail "port-forward to svc/keycloak never came up — is Keycloak installed in namespace $NAMESPACE?"
KC="http://127.0.0.1:$_kc_port"

# Keycloak in production mode answers on its public hostname (KC_HOSTNAME), so a
# request to 127.0.0.1 has to say which host it is meant for.
_kc_strip_scheme() { printf '%s' "$1" | sed -E 's|https?://||; s|/.*||'; }
KC_HOST="$(_kc_strip_scheme "$(kubectl -n "$NAMESPACE" get configmap keycloak-env -o jsonpath='{.data.KC_HOSTNAME}' 2>/dev/null || true)")"
[ -n "$KC_HOST" ] || _kc_fail "ConfigMap keycloak-env has no KC_HOSTNAME — run 'make install-identity'"
HEAD=(-H "X-Forwarded-Host: $KC_HOST" -H 'X-Forwarded-Proto: https')

# 2. Master-realm token. Retry: the Service can accept a connection while Keycloak
#    is still finishing its boot.
kubectl -n "$NAMESPACE" get secret "$MASTER_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$KEYCLOAK_ADMIN_TMP/master-pw" \
  || _kc_fail "cannot read Secret $MASTER_SECRET — run 'make install-identity'"
_kc_master_token=""
for _ in $(seq 1 20); do
  _kc_master_token="$("${_KC_CURL[@]}" "${HEAD[@]}" -X POST "$KC/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=admin" --data-urlencode "password@$KEYCLOAK_ADMIN_TMP/master-pw" \
    --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")' 2>/dev/null || true)"
  [ -n "$_kc_master_token" ] && break
  sleep 2
done
[ -n "$_kc_master_token" ] || _kc_fail "the master realm refused the $MASTER_SECRET credential — is Keycloak reachable through svc/keycloak?"
AUTH=(-H "Authorization: Bearer $_kc_master_token")
API="$KC/admin/realms/$REALM"

for _ in $(seq 1 30); do
  _kc_status="$("${_KC_CURL[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$API" || true)"
  [ "$_kc_status" = 200 ] && break
  sleep 2
done
[ "$_kc_status" = 200 ] || _kc_fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"
