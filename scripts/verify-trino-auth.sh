#!/usr/bin/env bash
# Prove that Trino enforces the platform identity, end to end.
#
#   NAMESPACE=stardelt TRINO_URL=https://trino.alpha.dev.stardelt.io \
#     TRINO_VERIFY_USER=analyst TRINO_VERIFY_USER_PASSWORD=... \
#     bash scripts/verify-trino-auth.sh
#
# Three checks, in the order the acceptance criteria list them:
#   1. anonymous          POST /v1/statement without credentials is refused (401, no query id);
#   2. service account    the password-authenticator user from Secret trino-password-db still
#                         gets queries back (`current_user` = superset) — Superset's path;
#   3. user identity      a real Keycloak access token for TRINO_VERIFY_USER (OAuth2 device
#                         grant on client `trino`, approval automated) authenticates, and
#                         `current_user` is that user — not a shared account.
#
# Check 3 runs the same validation as the browser flow and as Nova's forwarded
# token: Trino inspects the token's issuer and audience against the realm JWKS.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
TRINO_URL="${TRINO_URL:-https://trino.alpha.dev.stardelt.io}"
TRINO_VERIFY_USER="${TRINO_VERIFY_USER:-analyst}"
USER_PASSWORD="${TRINO_VERIFY_USER_PASSWORD:-}"

for tool in kubectl curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify-trino-auth: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "verify-trino-auth: $*" >&2; exit 1; }
query_id() { python3 -c 'import sys,json;print(json.load(sys.stdin).get("id") or "")' 2>/dev/null || true; }
finish() {  # finish <initial response body> -> prints the aggregated rows
  python3 - "$1" <<'PY'
import json, sys, urllib.request
body = json.loads(sys.argv[1])
rows = list(body.get("data") or [])
while body.get("nextUri"):
    if body.get("error"):
        sys.exit("ERROR " + json.dumps(body["error"])[:200])
    with urllib.request.urlopen(urllib.request.Request(body["nextUri"])) as r:
        body = json.load(r)
    rows.extend(body.get("data") or [])
print(rows)
PY
}

echo "› 1/3 anonymous POST /v1/statement (expect 401 and no query id)"
anon="$(curl -sS -o "$tmp/anon.json" -w '%{http_code}' -X POST "$TRINO_URL/v1/statement" \
  -H 'X-Trino-User: verify-anonymous' -d 'select 1')"
[ "$anon" = "401" ] || fail "anonymous request answered $anon, expected 401 — Trino is not authenticating"
[ -z "$(query_id < "$tmp/anon.json")" ] || fail "anonymous request was refused but still returned a query id"
echo "  anonymous: HTTP $anon, no query id"

echo "› 2/3 service account 'superset' (password file from Secret trino-password-db)"
kubectl -n "$NAMESPACE" get secret trino-password-db -o jsonpath='{.data.superset-password}' | base64 -d > "$tmp/superset-pw"
[ -s "$tmp/superset-pw" ] || fail "Secret trino-password-db has no superset-password — run scripts/identity-bootstrap.sh"
printf 'user = "superset:%s"\n' "$(cat "$tmp/superset-pw")" > "$tmp/superset.curlrc"
sf="$(curl -sS -K "$tmp/superset.curlrc" -X POST "$TRINO_URL/v1/statement" -d 'select current_user as who')"
[ -n "$(printf '%s' "$sf" | query_id)" ] || fail "service-account statement was refused: $(printf '%s' "$sf" | head -c 200)"
sf_rows="$(finish "$sf")"
echo "  superset: query id $(printf '%s' "$sf" | query_id), rows $sf_rows"
printf '%s' "$sf_rows" | grep -q superset || fail "service account did not authenticate as 'superset'"

echo "› 3/3 user '$TRINO_VERIFY_USER' with a real Keycloak access token (device grant)"
if [ -z "$USER_PASSWORD" ]; then
  echo "  TRINO_VERIFY_USER_PASSWORD not set — skipping the user check"
  echo "verify-trino-auth: 2/3 checks passed"
  exit 0
fi
kubectl -n "$NAMESPACE" get secret stardelt-oidc-clients -o jsonpath='{.data.trino}' | base64 -d > "$tmp/trino-secret"
[ -s "$tmp/trino-secret" ] || fail "stardelt-oidc-clients has no 'trino' key — run scripts/identity-bootstrap.sh"
ISSUER="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath='{.data.issuerUrl}')"
[ -n "$ISSUER" ] || fail "ConfigMap stardelt-identity has no issuerUrl — run 'make install-identity'"
ISSUER="$ISSUER" TRINO_URL="$TRINO_URL" USER="$TRINO_VERIFY_USER" PASSWORD="$USER_PASSWORD" \
  CLIENT_SECRET_FILE="$tmp/trino-secret" python3 scripts/verify-trino-auth.py

echo "verify-trino-auth: 3/3 checks passed"
