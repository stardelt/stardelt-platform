#!/usr/bin/env bash
# Prove every confidential client's secret in Secret `stardelt-oidc-clients`
# still authenticates at the live realm (stardelt-platform#85).
#
#   NAMESPACE=stardelt bash scripts/verify-oidc-clients.sh
#
# The check that would have caught the 2026-10-18 outage before a user did: that
# day all four app sign-ins failed while every /health returned 200, because the
# Secret had been regenerated after Keycloak had already imported the realm and
# nothing re-applied the new values.
#
# Per client (CLIENTS, default the four app clients + trino):
#   1. the client exists in realm `stardelt` (a missing client is a different
#      failure — its creation belongs to the realm import);
#   2. a real client-credentials request to the token endpoint: an
#      authorization-code grant with a bogus code. Keycloak authenticates the
#      client *before* it looks at the code, so the right secret answers 400
#      invalid_grant and a wrong one 401 unauthorized_client. No user, no
#      browser — and the same endpoint a real browser sign-in hits;
#   3. the secret the realm stores (admin API) equals the one in the Secret, so a
#      failure says "drift" rather than a symptom.
#
# Exits non-zero naming every client that disagrees, with the fix in the
# message. Reaches Keycloak through svc/keycloak (the id. ingress publishes no
# /admin, stardelt-platform#53). Secrets are read into files under a mode-0700
# temp dir and travel to curl only through `-K` config files; never argv, never
# stdout.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
CLIENTS_SECRET="${CLIENTS_SECRET:-stardelt-oidc-clients}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
CLIENTS="${CLIENTS:-nova superset airflow jupyterhub trino}"
# Never followed: the code is bogus, so Keycloak rejects it before any redirect.
PROBE_REDIRECT="${PROBE_REDIRECT:-http://127.0.0.1:9/oidc-probe}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify-oidc-clients: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "verify-oidc-clients: $*" >&2; exit 1; }

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

strip_scheme() { printf '%s' "$1" | sed -E 's|https?://||; s|/.*||'; }
KC_HOST="$(strip_scheme "$(kubectl -n "$NAMESPACE" get configmap keycloak-env -o jsonpath='{.data.KC_HOSTNAME}' 2>/dev/null || true)")"
[ -n "$KC_HOST" ] || fail "ConfigMap keycloak-env has no KC_HOSTNAME — run 'make install-identity'"
HEAD=(-H "X-Forwarded-Host: $KC_HOST" -H 'X-Forwarded-Proto: https')

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
[ -n "$master_token" ] || fail "the master realm refused the $MASTER_SECRET credential — Keycloak is not reachable through svc/keycloak, or that Secret drifted too"
# The bearer token is a credential too: file-backed curl config, not argv.
printf 'header = "Authorization: Bearer %s"\n' "$master_token" > "$tmp/auth.curlrc"
AUTH=(-K "$tmp/auth.curlrc")

status=""
for _ in $(seq 1 30); do
  status="$("${CURL_SOFT[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$KC/admin/realms/$REALM" || true)"
  [ "$status" = 200 ] && break
  sleep 2
done
[ "$status" = 200 ] || fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"
API="$KC/admin/realms/$REALM"

json_field() {
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
except Exception: print("")' "$1" "$2" 2>/dev/null || true
}

client_uuid() {
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$1" \
    | python3 -c 'import sys,json
clients = json.load(sys.stdin)
if not clients: sys.exit(1)
print(clients[0]["id"])' 2>/dev/null
}

# read_realm_secret UUID FILE -> the secret the realm stores (no trailing
# newline); non-zero when the admin API did not return one.
read_realm_secret() {
  local uuid="$1" file="$2" code
  code="$("${CURL_SOFT[@]}" -o "$tmp/client-secret.json" -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" \
    "$API/clients/$uuid/client-secret" || true)"
  [ "$code" = 200 ] || return 1
  python3 - "$tmp/client-secret.json" > "$file" <<'PY' || return 1
import json, sys
value = json.load(open(sys.argv[1])).get("value")
if value is None:
    sys.exit(1)
sys.stdout.write(value)
PY
}

# try_client_secret CLIENT SECRET-FILE -> 0 accepted (invalid_grant on the bogus
# code), 1 rejected (unauthorized_client/invalid_client), 2 cannot tell.
PROBE_HTTP=""
PROBE_ERROR=""
PROBE_DESCRIPTION=""
try_client_secret() {
  local client="$1" secret_file="$2" code error
  printf 'user = "%s:%s"\n' "$client" "$(cat "$secret_file")" > "$tmp/probe.curlrc"
  code="$("${CURL_SOFT[@]}" -o "$tmp/probe.json" -w '%{http_code}' -K "$tmp/probe.curlrc" "${HEAD[@]}" \
    -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=verify-oidc-clients-probe" \
    --data-urlencode "redirect_uri=$PROBE_REDIRECT" || true)"
  error="$(json_field "$tmp/probe.json" error)"
  PROBE_HTTP="$code"
  PROBE_ERROR="$error"
  PROBE_DESCRIPTION="$(json_field "$tmp/probe.json" error_description)"
  case "$code:$error" in
    400:invalid_grant) return 0 ;;
    *:invalid_client | *:unauthorized_client) return 1 ;;
    *) return 2 ;;
  esac
}

echo "› realm $REALM through svc/keycloak — Secret $CLIENTS_SECRET against the live clients"
checked=0
failed=0
failures=""
for client in $CLIENTS; do
  checked=$((checked + 1))
  secret_file="$tmp/$client.secret"
  kubectl -n "$NAMESPACE" get secret "$CLIENTS_SECRET" -o jsonpath="{.data.$client}" 2>/dev/null | base64 -d > "$secret_file" || true
  if [ ! -s "$secret_file" ]; then
    printf '  %-12s FAIL — Secret %s has no non-empty %s key\n' "$client" "$CLIENTS_SECRET" "'$client'"
    failed=$((failed + 1))
    failures="${failures}  $client: missing from Secret $CLIENTS_SECRET (run scripts/identity-bootstrap.sh)
"
    continue
  fi

  uuid="$(client_uuid "$client")" || {
    printf '  %-12s FAIL — no such client in realm %s\n' "$client" "$REALM"
    failed=$((failed + 1))
    failures="${failures}  $client: not in realm $REALM — the realm import creates clients; sign-in with it fails with 'Client not found'
"
    continue
  }

  probe=0
  try_client_secret "$client" "$secret_file" || probe=$?

  stored_file="$tmp/$client.stored"
  stored_read=""
  if read_realm_secret "$uuid" "$stored_file"; then stored_read=1; fi
  stored_rel=""
  if [ -n "$stored_read" ]; then
    if cmp -s "$stored_file" "$secret_file"; then
      stored_rel="the realm stores the same value"
    else
      stored_rel="the realm stores a different value"
    fi
  else
    stored_rel="the realm's stored value could not be read"
  fi

  case "$probe" in
    0)
      if [ -n "$stored_read" ] && ! cmp -s "$stored_file" "$secret_file"; then
        printf '  %-12s FAIL — the token endpoint accepts the Secret value but %s (admin API)\n' "$client" "$stored_rel"
        failed=$((failed + 1))
        failures="${failures}  $client: token endpoint accepts it, but $stored_rel — report this; it should not be possible
"
      else
        printf '  %-12s ok — token endpoint authenticates it; %s\n' "$client" "$stored_rel"
      fi
      ;;
    1)
      printf '  %-12s FAIL — token endpoint refused the Secret value (HTTP %s %s: %s); %s\n' \
        "$client" "$PROBE_HTTP" "${PROBE_ERROR:-error}" "${PROBE_DESCRIPTION:-no error_description}" "$stored_rel"
      failed=$((failed + 1))
      failures="${failures}  $client: refused (${PROBE_ERROR:-HTTP $PROBE_HTTP}: ${PROBE_DESCRIPTION:-no error_description}); $stored_rel
"
      ;;
    *)
      printf '  %-12s FAIL — no usable answer from the token endpoint (HTTP %s); %s\n' "$client" "$PROBE_HTTP" "$stored_rel"
      failed=$((failed + 1))
      failures="${failures}  $client: token endpoint answered HTTP $PROBE_HTTP ${PROBE_ERROR:+($PROBE_ERROR) }${PROBE_DESCRIPTION:-(no error body)}; $stored_rel
"
      ;;
  esac
done

echo ""
if [ "$failed" != 0 ]; then
  echo "verify-oidc-clients: FAILED — $failed of $checked client(s) disagree with Secret $CLIENTS_SECRET:" >&2
  printf '%s' "$failures" >&2
  echo "Every app signing in through these clients fails while its /health stays green (#85)." >&2
  echo "Fix: make sync-oidc-clients   # re-applies each client's Secret value, idempotent" >&2
  exit 1
fi

echo "verify-oidc-clients: OK — all $checked client secret(s) in Secret $CLIENTS_SECRET authenticate at realm $REALM"
