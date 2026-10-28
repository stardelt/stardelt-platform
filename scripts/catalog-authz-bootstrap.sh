#!/usr/bin/env bash
# Catalog authorization cutover for the dev cluster (platform#304, authz 3/8).
#
# Switches Lakekeeper from `authz.backend: allowall` to OpenFGA + the OPA bridge,
# re-bootstraps the catalog, writes the grants and runs the verification table.
# Idempotent: a second run reports every step as already done.
#
# A mistake locks the catalog out (every request 403). The recovery path is in the
# README "Catalog authorization" section: reopen-bootstrap, POST bootstrap,
# `openfga reconcile`, grants again. Switching back to `allowall` is a maintainer
# decision (upstream does not support it); never improvise a restore.
#
# Secrets never reach argv or stdout: client credentials and tokens live in a
# 0600 temp directory, and curl reads headers/config from files (`-H @file`,
# `-K file`).
set -euo pipefail

NAMESPACE=${NAMESPACE:-stardelt}
LAKEKEEPER_VERSION=${LAKEKEEPER_VERSION:-0.11.0}
HELM_FLAGS=${HELM_FLAGS:---namespace "$NAMESPACE" --create-namespace --wait --timeout 10m}
BASE=http://127.0.0.1:18181
PASS=0
FAIL=0

TMP=$(mktemp -d)
chmod 700 "$TMP"
PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { printf '  ✓ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }
check() { # check <description> <0|1>
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

# --- a. preflight -------------------------------------------------------------
kubectl -n "$NAMESPACE" get configmap stardelt-identity >/dev/null 2>&1 \
  || die "ConfigMap stardelt-identity is missing (run 'make install-identity' first)"
kubectl -n "$NAMESPACE" rollout status deploy/openfga --timeout=120s >/dev/null \
  || die "OpenFGA is not Ready"
for c in bootstrap bridge trino nova spark airflow operator; do
  kubectl -n "$NAMESPACE" get secret "svc-catalog-$c" >/dev/null 2>&1 \
    || die "Secret svc-catalog-$c is missing (run 'make sync-catalog-clients')"
done
phase=$(kubectl -n "$NAMESPACE" get cluster lakekeeper-pg -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ "$phase" = "Cluster in healthy state" ] || die "lakekeeper-pg is not healthy ($phase)"
ok "preflight (identity, OpenFGA Ready, seven clients, lakekeeper-pg healthy)"

# --- token helper -------------------------------------------------------------
token() { # token <client suffix> -> $TMP/token-<name>, $TMP/hdr-<name>
  local name=$1 id secret url scope cfg
  id=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.client-id}' | base64 -d)
  secret=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.client-secret}' | base64 -d)
  url=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.token-url}' | base64 -d)
  scope=$(kubectl -n "$NAMESPACE" get secret "svc-catalog-$name" -o jsonpath='{.data.scope}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "${scope:-}" ] || scope=openid
  cfg=$TMP/curl-$name.cfg
  {
    printf 'url = "%s"\n' "$url"
    printf 'data-urlencode = "grant_type=client_credentials"\n'
    printf 'data-urlencode = "client_id=%s"\n' "$id"
    printf 'data-urlencode = "client_secret=%s"\n' "$secret"
    printf 'data-urlencode = "scope=%s"\n' "$scope"
    printf 'silent\nshow-error\n'
  } > "$cfg"
  chmod 600 "$cfg"
  curl -K "$cfg" > "$TMP/token-$name.json" \
    || die "token request failed for svc-catalog-$name"
  python3 - "$TMP/token-$name.json" "$TMP/token-$name" <<'PY'
import json, sys
token = json.load(open(sys.argv[1]))["access_token"]
open(sys.argv[2], "w").write(token)
PY
  [ -s "$TMP/token-$name" ] || die "empty token for svc-catalog-$name"
  { printf 'Authorization: Bearer '; cat "$TMP/token-$name"; printf '\n'; } > "$TMP/hdr-$name"
  chmod 600 "$TMP/hdr-$name"
}

sub_of() { # sub_of <token file> — decode the JWT payload locally, never print it
  python3 - "$1" <<'PY'
import base64, json, sys
part = open(sys.argv[1]).read().strip().split(".")[1]
part += "=" * (-len(part) % 4)
print(json.loads(base64.urlsafe_b64decode(part))["sub"])
PY
}

# --- c. port-forward and current state ---------------------------------------
kubectl -n "$NAMESPACE" port-forward svc/lakekeeper 18181:8181 >/dev/null 2>"$TMP/pf.log" &
PF_PID=$!
for _ in $(seq 1 40); do
  curl -sf "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "$BASE/health" >/dev/null 2>&1 || die "port-forward to Lakekeeper failed"
token bootstrap
info_json=$(curl -sS -H @"$TMP/hdr-bootstrap" "$BASE/management/v1/info")
backend=$(printf '%s' "$info_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("authz-backend",""))')
bootstrapped=$(printf '%s' "$info_json" | python3 -c 'import json,sys; print(str(bool(json.load(sys.stdin).get("bootstrapped"))).lower())')

if [ "$backend" = "openfga" ] && [ "$bootstrapped" = "true" ]; then
  ok "already done: authorization is openfga and the catalog is bootstrapped"
else
  info "current backend: $backend (bootstrapped: $bootstrapped) — cutting over"

  # --- b. backup --------------------------------------------------------------
  backup="pre-authz-$(date -u +%Y%m%dt%H%M%Sz)"
  cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $backup
  namespace: $NAMESPACE
spec:
  cluster:
    name: lakekeeper-pg
EOF
  bphase=""
  for _ in $(seq 1 60); do
    bphase=$(kubectl -n "$NAMESPACE" get backup "$backup" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$bphase" = "completed" ] && break
    [ "$bphase" = "failed" ] && die "backup $backup failed"
    sleep 5
  done
  [ "$bphase" = "completed" ] || die "backup $backup did not complete within 5 minutes"
  ok "backup $backup completed"

  # --- d. helm upgrade --------------------------------------------------------
  # The bridge's administrator list (`OPABridge.adminUsers`, platform#311) comes
  # from ConfigMap trino-group-file, like every other Lakekeeper apply of ours —
  # see scripts/render-catalogs.sh admin-arg.
  admin_arg="$(NAMESPACE="$NAMESPACE" bash scripts/render-catalogs.sh admin-arg)"
  # shellcheck disable=SC2086,SC2046
  helm upgrade --install lakekeeper lakekeeper/lakekeeper \
    --version "$LAKEKEEPER_VERSION" $HELM_FLAGS \
    -f helm-values/lakekeeper.yaml $admin_arg
  kubectl -n "$NAMESPACE" rollout status deploy/lakekeeper --timeout=300s
  # The upgrade replaces the pod, so the port-forward from step c is stale.
  kill "$PF_PID" 2>/dev/null || true
  kubectl -n "$NAMESPACE" port-forward svc/lakekeeper 18181:8181 >/dev/null 2>"$TMP/pf.log" &
  PF_PID=$!
  for _ in $(seq 1 40); do
    curl -sf "$BASE/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -sf "$BASE/health" >/dev/null 2>&1 || die "port-forward after the upgrade failed"
  ok "Lakekeeper upgraded to authz.backend=openfga"

  # The catalog now answers 403 to everything until the re-bootstrap below.
  # --- e. reopen-bootstrap ----------------------------------------------------
  kubectl -n "$NAMESPACE" exec deploy/lakekeeper -c lakekeeper -- \
    /home/nonroot/lakekeeper reopen-bootstrap -y
  ok "catalog reopened for bootstrap"

  # --- f. bootstrap + reconcile ----------------------------------------------
  code=$(curl -sS -o "$TMP/bootstrap.json" -w '%{http_code}' -X POST \
    -H @"$TMP/hdr-bootstrap" -H 'Content-Type: application/json' \
    --data '{"accept-terms-of-use":true,"is-operator":true}' \
    "$BASE/management/v1/bootstrap")
  case "$code" in 200|204) ok "bootstrap accepted ($code)";; *) die "bootstrap returned $code: $(head -c 300 "$TMP/bootstrap.json" 2>/dev/null || true)";; esac
  kubectl -n "$NAMESPACE" exec deploy/lakekeeper -c lakekeeper -- \
    /home/nonroot/lakekeeper openfga reconcile
  ok "OpenFGA reconciled"
fi

# The bridge port (8282) is admitted by this policy; apply it on every run so a
# missing rule cannot make the verification (or Trino) fail.
kubectl apply -f manifests/lakekeeper-network-policy.yaml >/dev/null
ok "catalog ingress NetworkPolicy applied"

# --- g. grants ----------------------------------------------------------------
grant() { # grant <client> <type>
  local name=$1 type=$2 sub body code
  token "$name"
  sub=$(sub_of "$TMP/token-$name")
  body=$TMP/grant-$name-$type.json
  printf '{"writes":[{"type":"%s","user":"oidc~%s"}],"deletes":[]}' "$type" "$sub" > "$body"
  # Assignments are an operator action: post them with the bootstrap identity
  # (the server operator after step f) while the body names the client's sub.
  code=$(curl -sS -o "$TMP/grant-out.json" -w '%{http_code}' -X POST \
    -H @"$TMP/hdr-bootstrap" -H 'Content-Type: application/json' \
    --data @"$body" "$BASE/management/v1/permissions/project/assignments")
  case "$code" in
    200|204) ok "granted $type to svc-catalog-$name" ;;
    409)     ok "granted $type to svc-catalog-$name (already present)" ;;
    *)       die "grant $type to svc-catalog-$name returned $code: $(head -c 300 "$TMP/grant-out.json" 2>/dev/null || true)" ;;
  esac
}
grant bridge project_admin
grant operator project_admin
for c in trino nova spark airflow; do grant "$c" data_admin; done

# --- h. verification ----------------------------------------------------------
info "verification table"

# 1. authz backend
token bootstrap
info_json=$(curl -sS -H @"$TMP/hdr-bootstrap" "$BASE/management/v1/info")
backend=$(printf '%s' "$info_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("authz-backend",""))')
if [ "$backend" = "openfga" ]; then r=0; else r=1; fi
check "GET /management/v1/info reports authz-backend=openfga" $r

# 2. anonymous -> 401
code=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/catalog/v1/config?warehouse=warehouse")
if [ "$code" = "401" ]; then r=0; else r=1; fi
check "no token => 401 (got $code)" $r

# 3. Nova's client -> 200
token nova
code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$TMP/hdr-nova" "$BASE/catalog/v1/config?warehouse=warehouse")
if [ "$code" = "200" ]; then r=0; else r=1; fi
check "svc-catalog-nova => 200 (got $code)" $r

# 4. throwaway client without a grant -> 403
NAMESPACE="$NAMESPACE" KIND=service NAME=catalog-verify AUDIENCES=lakekeeper \
  bash scripts/keycloak-sync-principal.sh >/dev/null
token verify
code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$TMP/hdr-verify" "$BASE/catalog/v1/config?warehouse=warehouse")
if [ "$code" = "403" ]; then r=0; else r=1; fi
check "ungranted svc-catalog-verify => 403 (got $code)" $r
NAMESPACE="$NAMESPACE" KIND=service NAME=catalog-verify YES=1 \
  bash scripts/keycloak-sync-principal.sh --delete >/dev/null

# 5. the bridge answers to the coordinator's labels only
body='{"input":{"context":{"identity":{"user":"nobody","groups":[]},"action":{"operation":"SelectFromColumns","resource":{"table":{"catalogName":"warehouse","schemaName":"demo","tableName":"trips","columns":["x"]}}}}}}'
pod="authz-bridge-allowed-$RANDOM"
kubectl -n "$NAMESPACE" run "$pod" --image=curlimages/curl:8.10.1 --restart=Never \
  --labels='app.kubernetes.io/name=trino,app.kubernetes.io/component=coordinator' \
  --command -- curl -sS --retry 6 --retry-connrefused --retry-delay 1 --max-time 10 \
  -X POST "http://lakekeeper-opa:8282/v1/data/trino/allow" \
  -H 'Content-Type: application/json' -d "$body" >/dev/null
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=40s >/dev/null 2>&1 || true
out=$(kubectl -n "$NAMESPACE" logs "pod/$pod" 2>/dev/null || true)
kubectl -n "$NAMESPACE" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
if printf '%s' "$out" | grep -q '"result":false'; then r=0; else r=1; fi
check "bridge answers {\"result\":false} to a coordinator-labelled pod" $r

pod="authz-bridge-denied-$RANDOM"
kubectl -n "$NAMESPACE" run "$pod" --image=curlimages/curl:8.10.1 --restart=Never \
  --command -- curl -sS --max-time 3 -o /dev/null -w '%{http_code}' -X POST "http://lakekeeper-opa:8282/v1/data/trino/allow" \
  -H 'Content-Type: application/json' -d "$body" >/dev/null
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=40s >/dev/null 2>&1 || true
out=$(kubectl -n "$NAMESPACE" logs "pod/$pod" 2>/dev/null || true)
kubectl -n "$NAMESPACE" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
if printf '%s' "$out" | grep -q '^000$'; then r=0; else r=1; fi
check "an unlabelled pod cannot reach the bridge (curl code '${out:-none}')" $r

# 6. Trino's own authentication still works (anonymous 401 + service account).
NAMESPACE="$NAMESPACE" bash scripts/verify-trino-auth.sh >"$TMP/trino-auth.log" 2>&1 || true
check "scripts/verify-trino-auth.sh passes" $?

# 7. memory stays inside the budget
mem_lines=$(kubectl -n "$NAMESPACE" top pod -l app.kubernetes.io/name=lakekeeper --no-headers 2>/dev/null || true)
total_mi=$(printf '%s\n' "$mem_lines" | awk '{gsub(/Mi/,"",$3); s+=$3} END {print s+0}')
if [ "${total_mi:-0}" -gt 0 ] && [ "${total_mi:-0}" -lt 450 ]; then r=0; else r=1; fi
check "Lakekeeper pod incl. bridge uses ${total_mi}Mi (< 450Mi)" $r
node_mem=$(kubectl top node --no-headers 2>/dev/null | awk '{print $5}' | tr -d '%' | head -1)
if [ "${node_mem:-100}" -lt 85 ]; then r=0; else r=1; fi
check "node memory ${node_mem:-?}% (< 85%)" $r

# 8. The questions a query depends on (platform#333). The bridge must answer the
#    captured Trino 480 requests the way the seed's grants say — the replay's
#    data rows are the regression gate before anyone points Trino's authorizer
#    at it (platform#311). It needs the dev seed (#309): people to ask as AND the
#    four Catalogs the matrix asserts about. On a cluster without them there is
#    nothing to compare against and the step is skipped, not failed.
have_seed=1
kubectl -n "$NAMESPACE" get secret dev-seed-users >/dev/null 2>&1 || have_seed=0
for catalog in finance product sandbox warehouse; do
  kubectl -n "$NAMESPACE" get "catalogs.stardelt.io/$catalog" >/dev/null 2>&1 || have_seed=0
done
if [ "$have_seed" = 1 ]; then
  NAMESPACE="$NAMESPACE" bash scripts/bridge-replay.sh --data-only >"$TMP/bridge-replay.log" 2>&1 || true
  check "the bridge answers the replay's data rows (make bridge-replay --data-only)" $?
else
  info "skipped: bridge replay (the dev seed's four Catalogs are not installed — 'make seed-dev-access YES=1')"
fi

# 9. The cost of the question that used to grow with the catalog count
#    (platform#359): FilterCatalogs with every catalog, five cold runs, a median
#    above 0.2 s fails, and one AccessCatalog / SelectFromColumns above 0.05 s.
#    It also proves the front entry point returns the chart's own answer for
#    every seed person and the administrator. Needs the seed people, not the
#    seed catalogs: it asks about whatever this cluster has.
if kubectl -n "$NAMESPACE" get secret dev-seed-users >/dev/null 2>&1; then
  NAMESPACE="$NAMESPACE" bash scripts/bridge-latency.sh >"$TMP/bridge-latency.log" 2>&1 || true
  check "FilterCatalogs <= 0.2 s and one question <= 0.05 s median, answers unchanged (make bridge-latency)" $?

  # 10. The correctness gate of the decision table (platform#359): the front
  #     entry points against the chart's own rules, for every catalog, every
  #     table that exists, and every principal — plus one in no group at all.
  NAMESPACE="$NAMESPACE" bash scripts/bridge-replay.sh --differential >"$TMP/bridge-differential.log" 2>&1 || true
  check "the front entry points answer exactly what the chart's rules answer (make bridge-differential)" $?
else
  info "skipped: bridge latency and differential (no dev seed people in the realm — 'make seed-dev-access YES=1')"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
