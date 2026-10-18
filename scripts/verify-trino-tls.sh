#!/usr/bin/env bash
# Prove the in-cluster Trino path is authenticated and TLS-only (platform#80).
#
#   NAMESPACE=stardelt TRINO_VERIFY_USER=analyst TRINO_VERIFY_USER_PASSWORD=… \
#     bash scripts/verify-trino-tls.sh
#
# What it checks, in the order the acceptance criteria list them. "In-cluster"
# is the property under test, so every request runs in a short-lived pod
# (curlimages/curl) next to the coordinator, not through the ingress:
#
#   1. anonymous POST over plain HTTP to trino:8080 → refused, no query id
#      (before platform#80 this answered 200 as whatever X-Trino-User said);
#   2. anonymous POST over the in-cluster HTTPS endpoint :8443 → 401, no query id;
#   3. that endpoint's chain validates against the internal CA (Secret trino-ca,
#      key tls.crt) with no `-k`: issuer, SANs, "SSL certificate verify ok";
#   4. a real Keycloak access token for TRINO_VERIFY_USER, minted with the same
#      device grant as scripts/verify-trino-auth.sh, sent from inside the cluster
#      over HTTPS → query id and `select current_user` = that user. The token
#      travels in a temporary Secret mounted into the pod, never on a command
#      line and never printed.
#
# Check 4 is skipped (and said so) when TRINO_VERIFY_USER_PASSWORD is unset, so
# the anonymous and certificate checks still run without a credential.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
TRINO_VERIFY_USER="${TRINO_VERIFY_USER:-analyst}"
USER_PASSWORD="${TRINO_VERIFY_USER_PASSWORD:-}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.10.1}"

TOKEN_SECRET=trino-tls-verify-token
HTTP_URL="http://trino.${NAMESPACE}.svc.cluster.local:8080"
HTTPS_URL="https://trino.${NAMESPACE}.svc.cluster.local:8443"

for tool in kubectl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "verify-trino-tls: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
cleanup() {
  kubectl -n "$NAMESPACE" delete secret "$TOKEN_SECRET" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "verify-trino-tls: $*" >&2; exit 1; }
indent() { local line; while IFS= read -r line; do printf '  %s\n' "$line"; done <<< "$1"; }
query_id() { python3 -c 'import sys,json;print(json.load(sys.stdin).get("id") or "")' 2>/dev/null || true; }
rows() { python3 -c 'import sys,json;print(json.load(sys.stdin).get("data") or [])' 2>/dev/null || true; }

kubectl -n "$NAMESPACE" get secret trino-ca >/dev/null 2>&1 \
  || fail "Secret trino-ca not found — run 'make trino' (manifests/trino-tls.yaml)"

# run_probe NAME SCRIPT EXTRA_VOLUMES EXTRA_MOUNTS
# The pod's shell prints the check's variables; the caller parses them. A failing
# curl must still leave the pod's output readable, so the script never sets -e.
run_probe() {
  local name="$1" script="$2" volumes="$3" mounts="$4" overrides
  overrides="$(PROBE="$name" IMAGE="$PROBE_IMAGE" SCRIPT="$script" VOLUMES="$volumes" MOUNTS="$mounts" \
    python3 - <<'PY'
import json, os
mounts = json.loads(os.environ["MOUNTS"] or "[]")
volumes = json.loads(os.environ["VOLUMES"] or "[]")
print(json.dumps({
    "apiVersion": "v1",
    "spec": {
        "volumes": volumes,
        "containers": [{
            "name": os.environ["PROBE"],
            "image": os.environ["IMAGE"],
            "command": ["sh", "-c", os.environ["SCRIPT"]],
            "volumeMounts": mounts,
        }],
    },
}))
PY
)"
  kubectl -n "$NAMESPACE" run "$name" --restart=Never --image="$PROBE_IMAGE" --overrides="$overrides" >/dev/null
  kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=180s >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" logs "$name" 2>/dev/null || true
  kubectl -n "$NAMESPACE" delete pod "$name" --wait=false >/dev/null 2>&1 || true
}

CA_VOLUME='[{"name":"ca","secret":{"secretName":"trino-ca","items":[{"key":"tls.crt","path":"ca.crt"}]}}]'
CA_MOUNT='[{"name":"ca","mountPath":"/tls","readOnly":true}]'

echo "› 1/4 anonymous POST $HTTP_URL/v1/statement (plain HTTP, expect a refusal with no query id)"
out="$(run_probe trino-tls-http "
code=\$(curl -sS -o /tmp/b -w '%{http_code}' -X POST $HTTP_URL/v1/statement -H 'X-Trino-User: verify-anonymous' -d 'select 1' 2>/tmp/e) || code=\${code:-000}
echo \"http_code=\$code\"
echo \"has_id=\$(grep -c '\"id\"' /tmp/b)\"
echo \"body=\$(head -c 200 /tmp/b | tr '\n' ' ')\"
" '' '')"
indent "$out"
http_code="$(printf '%s' "$out" | sed -n 's/^http_code=//p')"
[ "$http_code" != "200" ] || fail "plain HTTP answered 200 — the coordinator still trusts X-Trino-User in-cluster"
printf '%s' "$out" | grep -q '^has_id=0$' || fail "the refusal still returned a query id"
echo "  refused: HTTP $http_code, no query id"

echo "› 2/4 anonymous POST $HTTPS_URL/v1/statement (in-cluster TLS, expect 401 and no query id)"
out="$(run_probe trino-tls-https "
code=\$(curl -sS --cacert /tls/ca.crt -o /tmp/b -w '%{http_code}' -X POST $HTTPS_URL/v1/statement -H 'X-Trino-User: verify-anonymous' -d 'select 1' 2>/tmp/e) || code=\${code:-000}
echo \"https_code=\$code\"
echo \"has_id=\$(grep -c '\"id\"' /tmp/b)\"
echo \"body=\$(head -c 200 /tmp/b | tr '\n' ' ')\"
" "$CA_VOLUME" "$CA_MOUNT")"
indent "$out"
https_code="$(printf '%s' "$out" | sed -n 's/^https_code=//p')"
[ "$https_code" = "401" ] || fail "anonymous over in-cluster TLS answered $https_code, expected 401"
printf '%s' "$out" | grep -q '^has_id=0$' || fail "the refusal still returned a query id"
echo "  refused: HTTP $https_code, no query id"

echo "› 3/4 certificate chain of $HTTPS_URL against Secret trino-ca (no -k)"
out="$(run_probe trino-tls-chain "
curl -sv --cacert /tls/ca.crt -o /dev/null $HTTPS_URL/v1/info 2>&1 | sed -n '/Server certificate/,/SSL certificate verify/p'
" "$CA_VOLUME" "$CA_MOUNT")"
indent "$out"
printf '%s' "$out" | grep -q 'SSL certificate verify ok' \
  || fail "the in-cluster certificate did not verify against the CA in Secret trino-ca"
echo "  chain verified with the CA alone (no -k)"

echo "› 4/4 a real Keycloak token for '$TRINO_VERIFY_USER' over the in-cluster TLS endpoint"
if [ -z "$USER_PASSWORD" ]; then
  echo "  TRINO_VERIFY_USER_PASSWORD not set — skipping the user check"
  echo "verify-trino-tls: 3/4 checks passed"
  exit 0
fi
kubectl -n "$NAMESPACE" get secret stardelt-oidc-clients -o jsonpath='{.data.trino}' | base64 -d > "$tmp/trino-secret"
[ -s "$tmp/trino-secret" ] || fail "stardelt-oidc-clients has no 'trino' key — run scripts/identity-bootstrap.sh"
ISSUER="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath='{.data.issuerUrl}')"
[ -n "$ISSUER" ] || fail "ConfigMap stardelt-identity has no issuerUrl — run 'make install-identity'"
ISSUER="$ISSUER" MINT_ONLY=1 TOKEN_FILE="$tmp/token" USER="$TRINO_VERIFY_USER" PASSWORD="$USER_PASSWORD" \
  CLIENT_SECRET_FILE="$tmp/trino-secret" python3 scripts/verify-trino-auth.py
[ -s "$tmp/token" ] || fail "the device grant did not produce a token"

kubectl -n "$NAMESPACE" delete secret "$TOKEN_SECRET" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" create secret generic "$TOKEN_SECRET" --from-file=token="$tmp/token" >/dev/null
TOKEN_VOLUME='[{"name":"ca","secret":{"secretName":"trino-ca","items":[{"key":"tls.crt","path":"ca.crt"}]}},{"name":"token","secret":{"secretName":"trino-tls-verify-token","items":[{"key":"token","path":"token"}]}}]'
TOKEN_MOUNT='[{"name":"ca","mountPath":"/tls","readOnly":true},{"name":"token","mountPath":"/token","readOnly":true}]'

result="$(run_probe trino-tls-user "
body=\$(curl -sS --cacert /tls/ca.crt -X POST $HTTPS_URL/v1/statement \
  -H 'X-Trino-User: $TRINO_VERIFY_USER' \
  -H \"Authorization: Bearer \$(cat /token/token)\" \
  -d 'select current_user as who')
# One line per statement page: the rows of a query can be delivered on a page
# that is not the last one (the final page may carry only the stats), so the
# caller needs all of them, not just the body the loop ended on.
printf '%s\n' \"\$body\"
for _ in \$(seq 1 60); do
  next=\$(printf '%s' \"\$body\" | sed -n 's/.*\"nextUri\":\"\\([^\"]*\\)\".*/\\1/p')
  [ -n \"\$next\" ] || break
  body=\$(curl -sS --cacert /tls/ca.crt \"\$next\")
  printf '%s\n' \"\$body\"
done
" "$TOKEN_VOLUME" "$TOKEN_MOUNT" | python3 -c '
import json, sys

# Pages arrive one JSON object per line; collect ids, rows and the first error
# from whichever page carried them.
ids, rows, errors = [], [], []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        body = json.loads(line)
    except ValueError:
        continue
    if body.get("id") and not ids:
        ids.append(body["id"])
    rows.extend(body.get("data") or [])
    if body.get("error"):
        errors.append(body["error"].get("message") or json.dumps(body["error"])[:200])
print(json.dumps({"id": ids[0] if ids else "", "rows": rows, "error": errors[0] if errors else ""}))
')"
[ -n "$result" ] || fail "no response from the in-cluster TLS endpoint for the user token"
query_id="$(printf '%s' "$result" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
rows="$(printf '%s' "$result" | python3 -c 'import sys,json;print(json.load(sys.stdin)["rows"])')"
error="$(printf '%s' "$result" | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
[ -n "$query_id" ] || fail "the token was refused: ${error:-no query id and no error}"
echo "  query id: $query_id"
echo "  rows: $rows"
[ -z "$error" ] || fail "the query failed: $error"
printf '%s' "$rows" | grep -q "$TRINO_VERIFY_USER" \
  || fail "Trino did not authenticate the token as $TRINO_VERIFY_USER"

echo "verify-trino-tls: 4/4 checks passed"
