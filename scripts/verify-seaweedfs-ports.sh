#!/usr/bin/env bash
# The object store's internal ports are for SeaweedFS's own pods (platform#1100).
#
#   NS=stardelt bash scripts/verify-seaweedfs-ports.sh
#
# Creates three one-shot busybox probes and deletes them again: a plain pod (must
# reach only the S3 gateway), a pod labelled as SeaweedFS (must reach the filer)
# and a pod carrying the chart's bucket hook identity (platform#1244; must reach
# the master and the filer). Needs a CNI that enforces NetworkPolicy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS="${NS:-${NAMESPACE:-stardelt}}"
IMAGE="busybox:1.36"
plain=seaweedfs-port-probe
peer=seaweedfs-port-probe-peer
hook=seaweedfs-port-probe-hook
problems=0
command -v kubectl >/dev/null 2>&1 || { echo "UNVERIFIED (kubectl not found)"; exit 3; }
kubectl get networkpolicy seaweedfs-internal -n "$NS" >/dev/null 2>&1 || {
  echo "UNVERIFIED (NetworkPolicy seaweedfs-internal is not installed — run make step-storage)"; exit 3; }
cleanup() { kubectl -n "$NS" delete pod "$plain" "$peer" "$hook" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
kubectl -n "$NS" run "$plain" --image="$IMAGE" --restart=Never --labels='app.kubernetes.io/part-of=stardelt' --command -- sleep 300 >/dev/null
kubectl -n "$NS" run "$peer" --image="$IMAGE" --restart=Never --labels='app.kubernetes.io/part-of=stardelt,app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=filer' --command -- sleep 300 >/dev/null
kubectl -n "$NS" run "$hook" --image="$IMAGE" --restart=Never --labels='app.kubernetes.io/part-of=stardelt,job-name=seaweedfs-bucket-hook' --command -- sleep 300 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/"$plain" pod/"$peer" pod/"$hook" --timeout=120s >/dev/null

must_fail() {  # pod, host, port, label
  if kubectl -n "$NS" exec "$1" -- timeout 3 nc -z -w 2 "$2" "$3" >/dev/null 2>&1; then
    echo "✗ $4: $2:$3 answered from a pod that is not SeaweedFS"; problems=$((problems + 1))
  else
    echo "✓ $4: $2:$3 is closed"
  fi
}
must_pass() {  # pod, host, port, label
  if kubectl -n "$NS" exec "$1" -- timeout 3 nc -z -w 2 "$2" "$3" >/dev/null 2>&1; then
    echo "✓ $4: $2:$3 answers"
  else
    echo "✗ $4: $2:$3 does not answer — a legitimate client was cut off"; problems=$((problems + 1))
  fi
}

must_fail "$plain" seaweedfs-filer 8888 "filer"
must_fail "$plain" seaweedfs-master 9333 "master"
must_fail "$plain" seaweedfs-volume 8080 "volume"
must_pass "$plain" seaweedfs-s3 8333 "S3 gateway (control)"
must_pass "$peer" seaweedfs-filer 8888 "SeaweedFS pod -> filer"
must_pass "$hook" seaweedfs-master 9333 "the chart's bucket hook -> master"
must_pass "$hook" seaweedfs-filer 8888 "the chart's bucket hook -> filer"
# The FAIL branch exits first on purpose: a trailing unconditional `exit` makes
# ShellCheck (0.9 SC2317, 0.11 SC2329) call the trap-only `cleanup` unreachable.
[ "$problems" -eq 0 ] || { echo "FAIL ($problems problem(s))"; exit 1; }
echo "PASS (7 of 7)"
