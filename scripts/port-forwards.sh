#!/usr/bin/env bash
# Open port-forwards to the in-cluster services. Backgrounded.
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"

pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

forward() {
  local svc="$1" local_port="$2" remote_port="$3"
  if kubectl -n "$NAMESPACE" get svc "$svc" >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" port-forward "svc/$svc" "$local_port:$remote_port" >/dev/null &
    pids+=("$!")
    echo "  $svc → http://localhost:$local_port"
  else
    echo "  $svc → (not installed yet)"
  fi
}

echo "Port-forwards (Ctrl-C to stop):"
forward nova       8080 8080
forward trino      8081 8080
forward lakekeeper 8181 8181
forward superset   8089 8088

wait
