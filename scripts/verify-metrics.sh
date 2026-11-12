#!/usr/bin/env bash
# Every metrics endpoint a scraper may read answers Prometheus text (#607).
#
#   NS=stardelt bash scripts/verify-metrics.sh
#
# Creates one pod labelled as the scraper and deletes it again. Components that are not
# installed are skipped; at least five installed targets must pass. Needs a CNI that
# enforces NetworkPolicy (the lab has one) and kubectl access to the namespace.
#
# Two groups are gated by NetworkPolicy and only answer a pod that carries the scraper
# label: the object store (seaweedfs-*-metrics) and the catalog stack (lakekeeper,
# openfga). Plain `app.kubernetes.io/part-of=stardelt` pods are refused, which is why the
# probe carries `app.kubernetes.io/name=prometheus` (the label monitoring.coreos.com's own
# pods carry, operator#607).
#
# `nova:8081/metrics` is deliberately not listed: the nova image running on the lab
# predates nova#903's endpoint. It joins this list after the pin.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS="${NS:-${NAMESPACE:-stardelt}}"
IMAGE="curlimages/curl:8.11.1"
POD=metrics-scrape-probe
problems=0
checks=0
command -v kubectl >/dev/null 2>&1 || { echo "UNVERIFIED (kubectl not found)"; exit 3; }
# --grace-period=1 and a synchronous delete: the default 30 s keeps the pod Terminating long
# after the run returns — "no pod left behind" then reads 1, and an immediate second run fails
# with "object is being deleted" (seen 2026-11-12).
cleanup() { kubectl -n "$NS" delete pod "$POD" --ignore-not-found --grace-period=1 >/dev/null 2>&1 || true; }
trap cleanup EXIT
# The label the NetworkPolicies admit: monitoring.coreos.com's own pod label (operator#607).
kubectl -n "$NS" run "$POD" --image="$IMAGE" --restart=Never \
  --labels='app.kubernetes.io/name=prometheus' --command -- sleep 600 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/"$POD" --timeout=120s >/dev/null

targets=(
  seaweedfs-master:9327
  seaweedfs-filer:9327
  seaweedfs-volume:9327
  seaweedfs-s3:9327
  keycloak:9000
  lakekeeper:9000
  openfga:2112
  reloader-reloader:9090
  spark-operator-metrics:8080
  stardelt-operator-metrics:8082
  airflow-statsd:9102
)

for target in "${targets[@]}"; do
  service="${target%%:*}"
  if ! kubectl -n "$NS" get service "$service" >/dev/null 2>&1; then
    echo "– $target: Service '$service' is not installed, skipped"; continue
  fi
  checks=$((checks + 1))
  # The body is written inside the probe pod and read by a second exec: a single exec with a
  # pipe would lose the line to SIGPIPE when grep exits early on a long body and mask a 200.
  # One retry: the first TCP connect from a freshly created probe pod is refused while the
  # CNI programs the policy's allow rule for its source IP (measured 6 of 6 times against
  # seaweedfs-master on 2026-11-12, always immediately after `condition=Ready`). A target
  # that is really broken fails both attempts.
  for attempt in 1 2; do
    code=$(kubectl -n "$NS" exec "$POD" -- curl -sS -o /tmp/metrics-body -w '%{http_code}' \
        --max-time 15 "http://$target/metrics" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    if [ "$attempt" = 1 ]; then sleep 1; fi
  done
  first=$(kubectl -n "$NS" exec "$POD" -- grep -m1 '^# TYPE' /tmp/metrics-body 2>/dev/null || true)
  if [ "$code" = "200" ] && [ -n "$first" ]; then
    echo "✓ $target/metrics 200 ${first#\# TYPE }"
  else
    echo "✗ $target/metrics answered ${code:-nothing} ${first:-(no Prometheus text)} — fix before going on"
    problems=$((problems + 1))
  fi
done
[ "$checks" -ge 5 ] || { echo "UNVERIFIED (only $checks target(s) installed — run make install-core first)"; exit 3; }
# The FAIL branch exits before the final PASS: an unconditional trailing `exit` makes
# ShellCheck (0.9 SC2317, 0.11 SC2329) call the trap-only `cleanup` unreachable.
[ "$problems" -eq 0 ] || { echo "FAIL ($problems problem(s))"; exit 1; }
echo "PASS ($checks of $checks)"
