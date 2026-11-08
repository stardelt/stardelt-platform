#!/usr/bin/env bash
# Prove Nova's Airflow service user can run the pipeline actions a person sees in the
# UI: sign in, read a DAG, and pause/resume it (platform#684).
#
# The 403 that started this was invisible until someone clicked Pause: Nova's Airflow
# user was a plain Viewer, so `/pause` was refused and Nova answered 502 (platform#680,
# fixed by giving `nova-api` the `stardelt-nova-operator` role; platform#681). Every
# manifest still looks correct while that role is missing or empty, so the check has to
# sign in as the service user and exercise the same endpoints Nova does.
#
#   NS=stardelt bash scripts/verify-airflow-actions.sh
#
# Environment:
#   NS      namespace, default stardelt
#   DAG     DAG to exercise, default pegelonline_hourly
#   PORT    local port for the port-forward, default 18080
#   SECRET  Secret holding the service user's password, default airflow-nova-api
#
# The run pauses the DAG once and restores the state it found, so it needs write access
# to the one DAG it names. Read-only otherwise: no other object is changed.
#
# Exit 0 = PASS, 1 = FAIL, 3 = UNVERIFIED (could not see the subject).
set -euo pipefail

NS="${NS:-stardelt}"
DAG="${DAG:-pegelonline_hourly}"
PORT="${PORT:-18080}"
SECRET="${SECRET:-airflow-nova-api}"

unverified() { echo "UNVERIFIED ($*)"; exit 3; }
fail() { echo "FAIL ($*)"; exit 1; }

for cmd in kubectl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || unverified "$cmd not found"
done

# ---------------------------------------------------------------------------
# 1. The service user's credential. A missing Secret is not a failure of the
#    platform: an install without Pipelines has no service user to check.
#    The values are used and never printed.
# ---------------------------------------------------------------------------
if ! secret="$(kubectl -n "$NS" get secret "$SECRET" -o json 2>&1)"; then
  case "$secret" in
    *NotFound*) unverified "no Secret $SECRET" ;;
    *) unverified "cannot read Secret $SECRET: $secret" ;;
  esac
fi
username="$(printf '%s' "$secret" | python3 -c 'import base64,json,sys; print(base64.b64decode(json.load(sys.stdin)["data"]["username"]).decode())')" \
  || unverified "Secret $SECRET has no username"
password="$(printf '%s' "$secret" | python3 -c 'import base64,json,sys; print(base64.b64decode(json.load(sys.stdin)["data"]["password"]).decode())')" \
  || unverified "Secret $SECRET has no password"
unset secret

# ---------------------------------------------------------------------------
# 2. Port-forward the API server. The API is only reachable in-cluster; the
#    forward is killed on every exit path.
# ---------------------------------------------------------------------------
kubectl -n "$NS" port-forward svc/airflow-api-server "$PORT":8080 >/dev/null 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

base="http://127.0.0.1:$PORT"
up=0
for _ in $(seq 1 20); do
  if curl -s -o /dev/null "$base/health"; then up=1; break; fi
  sleep 0.5
done
[ "$up" -eq 1 ] || unverified "port-forward did not come up"

# ---------------------------------------------------------------------------
# 3. Sign in as the service user. 401/403 is the #476/#680 shape: the user does
#    not exist or the Secret's password is not its password.
# ---------------------------------------------------------------------------
token_body="$(AIRFLOW_USER="$username" AIRFLOW_PASS="$password" python3 -c \
  'import json,os; print(json.dumps({"username": os.environ["AIRFLOW_USER"], "password": os.environ["AIRFLOW_PASS"]}))')"
unset username password

token_raw="$(printf '%s' "$token_body" | curl -s -H 'Content-Type: application/json' \
  --data-binary @- -w '\n%{http_code}' "$base/auth/token")" || fail "cannot reach $base/auth/token"
unset token_body
token_code="${token_raw##*$'\n'}"
token_payload="${token_raw%$'\n'*}"

case "$token_code" in
  201) ;;
  401|403) fail "nova-api cannot sign in to Airflow — check Secret $SECRET" ;;
  *) fail "sign-in returned HTTP $token_code, expected 201" ;;
esac

token="$(printf '%s' "$token_payload" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["access_token"])')" \
  || fail "sign-in answered $token_code without an access_token"
[ -n "$token" ] || fail "sign-in answered 201 with an empty access_token"
unset token_raw token_payload

# ---------------------------------------------------------------------------
# 4. Read the DAG. 404 means the platform no longer installs it; 403 means
#    `nova-api` lost its role (or the role is empty).
#
#    The bearer token travels in a curl config on a pipe, never on the command
#    line, so it does not show up in the process list.
# ---------------------------------------------------------------------------
api_curl() {
  curl -s -K <(printf 'header = "Authorization: Bearer %s"\n' "$token") "$@"
}

dag_raw="$(api_curl -w '\n%{http_code}' "$base/api/v2/dags/$DAG")" \
  || fail "cannot reach $base/api/v2/dags/$DAG"
dag_code="${dag_raw##*$'\n'}"
dag_payload="${dag_raw%$'\n'*}"

case "$dag_code" in
  200) ;;
  404) fail "Airflow has no DAG $DAG" ;;
  403) fail "nova-api cannot read DAG $DAG — role stardelt-nova-operator is missing or empty" ;;
  *) fail "reading DAG $DAG returned HTTP $dag_code, expected 200" ;;
esac

original="$(printf '%s' "$dag_payload" | python3 -c \
  'import json,sys; print("true" if json.load(sys.stdin)["is_paused"] else "false")')" \
  || fail "DAG $DAG answered 200 without is_paused"
unset dag_raw dag_payload

# ---------------------------------------------------------------------------
# 5. Pause and restore. These are the writes Nova's Pause/Resume buttons make;
#    403 here is exactly the permission the platform#680 fix granted.
# ---------------------------------------------------------------------------
patch_state() {
  local value="$1"
  printf '{"is_paused":%s}' "$value" | api_curl -o /dev/null -w '%{http_code}' \
    -X PATCH -H 'Content-Type: application/json' \
    --data-binary @- "$base/api/v2/dags/$DAG"
}

patch_code="$(patch_state true)" || fail "cannot reach $base/api/v2/dags/$DAG"
case "$patch_code" in
  200) ;;
  403) fail "nova-api cannot pause DAG $DAG — role stardelt-nova-operator lacks can_edit DAGs" ;;
  *) fail "pausing DAG $DAG returned HTTP $patch_code, expected 200" ;;
esac

restore_code="$(patch_state "$original")" || restore_code="(no answer)"
case "$restore_code" in
  200) ;;
  *) fail "DAG $DAG could not be restored (HTTP $restore_code): it is left is_paused=true, resume it by hand" ;;
esac

echo "✓ nova-api   signs in, reads and pauses/resumes $DAG (is_paused restored to $original)"
echo "PASS (nova-api signs in, reads and pauses/resumes DAG $DAG; role stardelt-nova-operator)"
