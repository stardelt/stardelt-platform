#!/usr/bin/env bash
# Converge the live Keycloak realm onto the OIDC client secrets that Secret
# `stardelt-oidc-clients` holds (stardelt-platform#85).
#
#   NAMESPACE=stardelt bash scripts/sync-oidc-clients.sh
#
# Why this exists — the same import-time snapshot as the realm admin (#81), with
# a worse failure mode: `--import-realm` substitutes ${STARDELT_<CLIENT>_CLIENT_SECRET}
# *once*, on the first start that creates realm `stardelt`, and never looks at it
# again. Regenerating the Secret — deleting it to rotate, or re-running
# scripts/identity-bootstrap.sh after a re-provision — therefore leaves the app
# clients authenticating with a value nobody holds. On 2026-10-18 that took out
# human sign-in for nova, superset, airflow and jupyterhub at once, while every
# /health stayed 200. The Secret is the source of truth; this script re-applies
# its current values through the admin API, so the install path heals the drift
# instead of leaving it for a failed login to reveal.
#
# Per client (CLIENTS, default the four app clients):
#   1. probe the token endpoint through svc/keycloak with the Secret's value. A
#      client-credentials authorization-code request with a bogus code is
#      authenticated before the code is looked at: the right secret answers
#      invalid_grant, a wrong one unauthorized_client. No user, no browser.
#   2. when the probe already accepts the value, nothing is written at all —
#      this is what makes a re-run a no-op;
#   3. otherwise write the Secret's value, read the stored value back, and probe
#      again; only a read-back that matches the Secret counts as updated;
#   4. a client missing from the realm fails the run: creating clients is the
#      realm import's job — or keycloak-sync-trino-client.sh's for `trino` — and
#      a half-configured client would be worse than the drift.
#
# Client `trino` is not duplicated here: scripts/keycloak-sync-trino-client.sh
# already re-applies its secret along with the token settings its OAuth2 flow
# needs, so this script delegates to it (SYNC_TRINO=0 skips that). The redirect
# URIs, roles, mappers and realm-admin handling are untouched — the admin API PUT
# below merges exactly one field, `secret`.
#
# Reaches Keycloak through svc/keycloak (port-forward): the id. ingress
# publishes no /admin on purpose (stardelt-platform#53). Secrets are read into
# files under a mode-0700 temp dir and travel to curl only through `-K` config
# files and `--data @file` bodies — never argv, stdout or a log line.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
# One key per client, same names as the realm's clientIds (see scripts/identity-bootstrap.sh).
CLIENTS_SECRET="${CLIENTS_SECRET:-stardelt-oidc-clients}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
CLIENTS="${CLIENTS:-nova superset airflow jupyterhub}"
# Delegate the trino client to its own script (make install-identity calls both
# this and that one, and setting SYNC_TRINO=0 keeps the install from syncing it
# twice).
SYNC_TRINO="${SYNC_TRINO:-1}"
TRINO_PUBLIC_URL="${TRINO_PUBLIC_URL:-}"
# The probe's redirect target is never followed — the code is bogus, so Keycloak
# rejects it before any redirect. Deliberately unroutable.
PROBE_REDIRECT="${PROBE_REDIRECT:-http://127.0.0.1:9/oidc-probe}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
# Same, but a 4xx body is data rather than an error (the probe below answers
# 400 invalid_grant when the client credentials are right).
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "sync-oidc-clients: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "sync-oidc-clients: $*" >&2; exit 1; }

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

# 2. The master credential, into a file (never argv, never stdout).
kubectl -n "$NAMESPACE" get secret "$MASTER_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/master-pw" \
  || fail "cannot read Secret $MASTER_SECRET — run 'make install-identity'"

# 3. Master-realm token. Retry: the Service can accept a connection while Keycloak
#    is still finishing its boot (install-identity calls this right after rollout).
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
# The bearer token is a credential too: it goes into a mode-0600 curl config
# rather than onto the command line. (Same for the API calls below.)
printf 'header = "Authorization: Bearer %s"\n' "$master_token" > "$tmp/auth.curlrc"
AUTH=(-K "$tmp/auth.curlrc")

# 4. The realm may not exist yet on the very first boot (import runs during
#    startup); wait for it rather than writing a secret into nothing.
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

# client_uuid CLIENT -> prints the client's internal id; fails (non-zero) when
# the realm has no such client.
client_uuid() {
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=$1" \
    | python3 -c 'import sys,json
clients = json.load(sys.stdin)
if not clients: sys.exit(1)
print(clients[0]["id"])' 2>/dev/null
}

# read_realm_secret UUID FILE -> writes the secret the realm stores for that
# client into FILE (no trailing newline). Non-zero when the admin API did not
# return one, so callers never mistake a failed read for a mismatch.
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

# try_client_secret CLIENT SECRET-FILE
#   0 = the token endpoint authenticated the client with this value (the bogus
#       code is then rejected with invalid_grant)
#   1 = the value was rejected (unauthorized_client / invalid_client)
#   2 = cannot tell (unexpected status or body)
# Sets PROBE_HTTP and PROBE_DESCRIPTION for the failure messages.
PROBE_HTTP=""
PROBE_ERROR=""
PROBE_DESCRIPTION=""
try_client_secret() {
  local client="$1" secret_file="$2" code error
  # The secret reaches curl through a mode-0600 config file (-K), not argv.
  printf 'user = "%s:%s"\n' "$client" "$(cat "$secret_file")" > "$tmp/probe.curlrc"
  code="$("${CURL_SOFT[@]}" -o "$tmp/probe.json" -w '%{http_code}' -K "$tmp/probe.curlrc" "${HEAD[@]}" \
    -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=sync-oidc-clients-probe" \
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

# 5. One client at a time: probe, compare, write only on a real disagreement.
updated=0
checked=0
for client in $CLIENTS; do
  secret_file="$tmp/$client.secret"
  kubectl -n "$NAMESPACE" get secret "$CLIENTS_SECRET" -o jsonpath="{.data.$client}" 2>/dev/null | base64 -d > "$secret_file" || true
  [ -s "$secret_file" ] || fail "Secret $CLIENTS_SECRET has no non-empty '$client' key — run scripts/identity-bootstrap.sh (or set CLIENTS= to the clients this cluster has)"
  uuid="$(client_uuid "$client")" \
    || fail "client '$client' does not exist in realm $REALM.
  The realm import creates the platform's clients (keycloak-sync-trino-client.sh owns trino);
  syncing a secret onto a missing client would leave it half-configured, so this run stops here.
  Restore the client first, then re-run. (The import only runs for a realm that does not exist yet:
  'make install-identity' on an existing realm skips it.)"
  checked=$((checked + 1))

  probe=0
  try_client_secret "$client" "$secret_file" || probe=$?

  if [ "$probe" = 0 ]; then
    echo "› client $client: matches"
    continue
  fi

  # The Secret's value did not authenticate. Before writing anything, read the
  # realm's stored value: when it already equals the Secret, this is not the
  # import-time drift and rewriting the same value would change nothing.
  stored_file="$tmp/$client.stored"
  stored_read=""
  if read_realm_secret "$uuid" "$stored_file"; then stored_read=1; fi
  if [ -n "$stored_read" ] && cmp -s "$stored_file" "$secret_file"; then
    fail "client $client: the realm already stores exactly the value in Secret $CLIENTS_SECRET — read back through the admin API —
  yet the token endpoint refused the client credentials (HTTP $PROBE_HTTP ${PROBE_ERROR:-error}: ${PROBE_DESCRIPTION:-no error_description}).
  That is not the import-time drift (#85) this script repairs. Check that client $client is enabled,
  still uses the 'client-secret' authenticator, and has standard flow on; then sign in again."
  fi

  # Write the Secret's value. The body travels as a file (--data @file), and the
  # PUT merges this one field into the client representation — no redirect URI,
  # role or mapper is touched.
  python3 - "$secret_file" > "$tmp/$client.write.json" <<'PY'
import json, sys
sys.stdout.write(json.dumps({"secret": open(sys.argv[1]).read().rstrip("\n")}))
PY
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT --data @"$tmp/$client.write.json" "$API/clients/$uuid" >/dev/null \
    || fail "Keycloak refused the secret update for client $client — check 'kubectl -n $NAMESPACE logs deploy/keycloak'"

  # Read back: "updated" is only true when the realm now stores the Secret's value.
  read_realm_secret "$uuid" "$stored_file" \
    || fail "cannot read client $client's secret back from the admin API after the update"
  cmp -s "$stored_file" "$secret_file" \
    || fail "Keycloak accepted the update for client $client but reads back a different value — check 'kubectl -n $NAMESPACE logs deploy/keycloak'"

  # And prove it the way a browser will: a client-credentials token request.
  probe=0
  try_client_secret "$client" "$secret_file" || probe=$?
  case "$probe" in
    0) echo "› client $client: updated" ;;
    1) fail "client $client: the realm stores the Secret's value now, but the token endpoint still refuses the credentials
  (HTTP $PROBE_HTTP ${PROBE_ERROR:-error}: ${PROBE_DESCRIPTION:-no error_description}) — check 'kubectl -n $NAMESPACE logs deploy/keycloak'" ;;
    *) fail "client $client: cannot confirm the update — the token endpoint answered HTTP $PROBE_HTTP ${PROBE_ERROR:+($PROBE_ERROR) }${PROBE_DESCRIPTION:-without an error body}" ;;
  esac
  updated=$((updated + 1))
done

# 6. Client trino: delegate, do not duplicate. Its script re-applies the secret
#    together with the redirect URIs, PKCE setting, mappers and lifespan that
#    Trino's OAuth2 flow needs — so it only runs when the probe shows the
#    Secret's value is not accepted (or cannot be confirmed). When the secret
#    already works, this script writes nothing here either.
if [ "$SYNC_TRINO" != 0 ]; then
  if [ -n "$(kubectl -n "$NAMESPACE" get secret "$CLIENTS_SECRET" -o jsonpath='{.data.trino}' 2>/dev/null || true)" ]; then
    trino_uuid="$(client_uuid trino)" \
      || fail "client 'trino' does not exist in realm $REALM — keycloak-sync-trino-client.sh cannot re-apply its secret onto a missing client"
    checked=$((checked + 1))
    trino_secret="$tmp/trino.secret"
    kubectl -n "$NAMESPACE" get secret "$CLIENTS_SECRET" -o jsonpath='{.data.trino}' | base64 -d > "$trino_secret"
    probe=0
    try_client_secret trino "$trino_secret" || probe=$?
    if [ "$probe" = 0 ]; then
      echo "› client trino: matches"
    else
      trino_url="$TRINO_PUBLIC_URL"
      if [ -z "$trino_url" ]; then
        trino_url="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$trino_uuid" \
          | python3 -c 'import sys,json
uris = json.load(sys.stdin).get("redirectUris") or []
suffix = "/oauth2/callback"
hit = next((u for u in uris if u.endswith(suffix) and not u.startswith("https://localhost")), None)
if hit is None: sys.exit(1)
print(hit[:-len(suffix)])')" \
          || fail "client trino has no /oauth2/callback redirect URI to derive TRINO_PUBLIC_URL from — set TRINO_PUBLIC_URL"
        echo "› client trino: TRINO_PUBLIC_URL unset — reusing the live redirect URI ($trino_url)"
      fi
      echo "› client trino: delegating to scripts/keycloak-sync-trino-client.sh"
      NAMESPACE="$NAMESPACE" TRINO_PUBLIC_URL="$trino_url" bash scripts/keycloak-sync-trino-client.sh
      updated=$((updated + 1))
    fi
  else
    echo "› client trino: Secret $CLIENTS_SECRET has no 'trino' key — nothing to sync"
  fi
fi

echo ""
if [ "$updated" = 0 ]; then
  echo "sync-oidc-clients: OK — $checked client(s) checked in realm $REALM, nothing changed"
else
  echo "sync-oidc-clients: OK — $checked client(s) checked in realm $REALM, $updated updated"
fi
echo "Run 'make verify-oidc-clients' to prove every client secret at the token endpoint."
