#!/usr/bin/env bash
# Make the live Keycloak realm match what Trino needs, without re-importing the
# realm (the import only runs on a fresh realm).
#
#   NAMESPACE=stardelt TRINO_PUBLIC_URL=https://trino.alpha.dev.stardelt.io \
#     bash scripts/keycloak-sync-trino-client.sh
#
# Why a separate script: the realm JSON is the source of truth for a fresh
# install, but `--import-realm` skips an existing realm, so the changes that turn
# client `trino` from a public client into Trino 480's confidential OAuth2 client
# have to be applied through the admin API on a running cluster. It is idempotent
# and touches exactly two objects: client `trino` and client `nova`'s audience
# mapper.
#
# What it does:
#   1. port-forwards svc/keycloak — the admin API is deliberately not published
#      through the ingress (stardelt-platform#53) — and signs in with the
#      keycloak-admin Secret;
#   2. client `trino`: publicClient=false, client secret from
#      stardelt-oidc-clients/trino, no PKCE (Trino 480 never sends a
#      code_challenge; with PKCE required, login fails with
#      "Missing parameter: code_challenge_method"), redirect URIs
#      <TRINO_PUBLIC_URL>/oauth2/callback + /ui/login.html, post-logout
#      <TRINO_PUBLIC_URL>/ui/logout/logout.html;
#   3. client `nova`: adds the aud-trino mapper when missing. That mapper is the
#      moat: it is what makes the token Nova forwards — the user's own — carry a
#      valid audience at Trino;
#   4. proves the client secret works: Keycloak answers invalid_grant for the
#      right secret and unauthorized_client for a wrong one (bogus auth code,
#      so the check needs no user).
#
# Secrets are read into files under a mode-0700 temp dir, passed to curl through
# `-K`/`@file`, and never printed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
TRINO_PUBLIC_URL="${TRINO_PUBLIC_URL:?set TRINO_PUBLIC_URL, e.g. https://trino.alpha.dev.stardelt.io}"
CURL=(curl --fail-with-body --silent --show-error --max-time 30)
# Same, but a 4xx body is data rather than an error (the client-credential check
# below answers 400 invalid_grant when the secret is right).
CURL_SOFT=(curl --silent --show-error --max-time 30)

command -v kubectl >/dev/null 2>&1 || { echo "keycloak-sync-trino-client: kubectl not found" >&2; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "keycloak-sync-trino-client: curl not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "keycloak-sync-trino-client: python3 not found" >&2; exit 1; }

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Public host of Keycloak, from the ConfigMap the deployment itself reads.
strip_scheme() { printf '%s' "$1" | sed -E 's|https?://||; s|/.*||'; }
KC_HOST="$(strip_scheme "$(kubectl -n "$NAMESPACE" get configmap keycloak-env -o jsonpath='{.data.KC_HOSTNAME}' 2>/dev/null || true)")"
KC_HOST="${KC_HOST:-id.$(strip_scheme "$TRINO_PUBLIC_URL" | sed -E 's|^trino\.||')}"

# 1. Reach the admin API on loopback.
local_port=18090
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
[ -n "$ready" ] || { echo "keycloak-sync-trino-client: port-forward to svc/keycloak never came up" >&2; exit 1; }
KC="http://127.0.0.1:$local_port"
HEAD=(-H "X-Forwarded-Host: $KC_HOST" -H 'X-Forwarded-Proto: https')

kubectl -n "$NAMESPACE" get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d > "$tmp/admin-pw"
kubectl -n "$NAMESPACE" get secret stardelt-oidc-clients -o jsonpath='{.data.trino}' | base64 -d > "$tmp/trino-secret"
[ -s "$tmp/trino-secret" ] || {
  echo "keycloak-sync-trino-client: stardelt-oidc-clients has no 'trino' key — run scripts/identity-bootstrap.sh" >&2
  exit 1
}

admin_token="$("${CURL[@]}" "${HEAD[@]}" -X POST "$KC/realms/master/protocol/openid-connect/token" \
  --data-urlencode "username=admin" --data-urlencode "password@$tmp/admin-pw" \
  --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"
AUTH=(-H "Authorization: Bearer $admin_token")
API="$KC/admin/realms/stardelt"

# 2. Client `trino`.
client_json="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=trino")"
client_id="$(printf '%s' "$client_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"

# PKCE has to go in its own request: Keycloak merges attribute maps on update, so
# omitting the key (or sending the full representation without it) leaves it in
# place — an empty value removes it.
if printf '%s' "$client_json" | python3 -c 'import sys,json;sys.exit(0 if "pkce.code.challenge.method" in json.load(sys.stdin)[0].get("attributes",{}) else 1)'; then
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT --data '{"attributes":{"pkce.code.challenge.method":""}}' "$API/clients/$client_id" >/dev/null
  echo "› client trino: PKCE requirement removed"
fi

python3 - "$TRINO_PUBLIC_URL" > "$tmp/trino-client.json" <<'PY'
import json, sys
url = sys.argv[1].rstrip("/")
print(json.dumps({
    "publicClient": False,
    "clientAuthenticatorType": "client-secret",
    "standardFlowEnabled": True,
    "directAccessGrantsEnabled": False,
    "redirectUris": [f"{url}/oauth2/callback", f"{url}/ui/login.html"],
    "webOrigins": [url],
    "attributes": {"post.logout.redirect.uris": f"{url}/ui/logout/logout.html"},
}))
PY
python3 - "$tmp/trino-secret" > "$tmp/trino-secret.json" <<'PY'
import json, sys
print(json.dumps({"secret": open(sys.argv[1]).read().strip()}))
PY
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -X PUT --data @"$tmp/trino-client.json" "$API/clients/$client_id" >/dev/null
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -X PUT --data @"$tmp/trino-secret.json" "$API/clients/$client_id" >/dev/null
echo "› client trino: confidential, secret synced from stardelt-oidc-clients/trino"

# 3. The aud-trino mapper on client nova — without it a Nova-forwarded token is
#    rejected by Trino with 401 even though Keycloak signed it.
nova_id="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients?clientId=nova" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
existing="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/clients/$nova_id/protocol-mappers/models")"
if printf '%s' "$existing" | python3 -c 'import sys,json;sys.exit(0 if any(m["name"]=="aud-trino" for m in json.load(sys.stdin)) else 1)'; then
  echo "› client nova: aud-trino mapper present"
else
  "${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' -X POST \
    --data @- "$API/clients/$nova_id/protocol-mappers/models" >/dev/null <<'JSON'
{"name":"aud-trino","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","consentRequired":false,
 "config":{"included.client.audience":"trino","id.token.claim":"false","access.token.claim":"true","introspection.token.claim":"true"}}
JSON
  echo "› client nova: aud-trino mapper added"
fi

# 4. Prove the secret: wrong secret → unauthorized_client, right secret → invalid_grant.
printf 'user = "trino:%s"\n' "$(cat "$tmp/trino-secret")" > "$tmp/trino.curlrc"
verify="$("${CURL_SOFT[@]}" -K "$tmp/trino.curlrc" "${HEAD[@]}" -X POST "$KC/realms/stardelt/protocol/openid-connect/token" \
  --data-urlencode "grant_type=authorization_code" --data-urlencode "code=verify-only" \
  --data-urlencode "redirect_uri=$TRINO_PUBLIC_URL/oauth2/callback" || true)"
case "$verify" in
  *invalid_grant*) echo "› client trino: secret verified against the live realm" ;;
  *) echo "keycloak-sync-trino-client: client secret check failed: $verify" >&2; exit 1 ;;
esac
