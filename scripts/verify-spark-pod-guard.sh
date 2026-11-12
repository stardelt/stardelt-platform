#!/usr/bin/env bash
# The Spark Connect driver may create executor pods only (platform#1096).
#
#   NS=stardelt bash scripts/verify-spark-pod-guard.sh
#
# Read-only against the cluster: every pod is created with --dry-run=server as
# ServiceAccount spark-connect, so the admission policy decides and nothing is persisted.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS="${NS:-${NAMESPACE:-stardelt}}"
SA="system:serviceaccount:${NS}:spark-connect"
IMAGE="ghcr.io/stardelt/spark:dev@sha256:1acae61431891d5354fc959374adf3d5c1fbfc5cf7a7a39b099ef7c6eba89709"
problems=0
command -v kubectl >/dev/null 2>&1 || { echo "UNVERIFIED (kubectl not found)"; exit 3; }
kubectl get validatingadmissionpolicy spark-connect-executor-pods >/dev/null 2>&1 || {
  echo "UNVERIFIED (ValidatingAdmissionPolicy spark-connect-executor-pods is not installed — kubectl < 1.30 or make install-spark not run)"; exit 3; }

deny() {  # name, yaml-file-or-stdin description
  local out
  out="$(mktemp)"; trap 'rm -f "$out"' RETURN
  if kubectl -n "$NS" apply --dry-run=server --as="$SA" -f - >"$out" 2>&1; then
    echo "✗ $(basename "$1") was admitted; the policy should deny it"; problems=$((problems + 1))
  elif grep -q 'spark-connect-executor-pods' "$out"; then
    echo "✓ $(basename "$1") denied by the policy"
  else
    echo "✗ $(basename "$1") was refused, but not by the policy: $(tail -1 "$out")"; problems=$((problems + 1))
  fi
}

# 1. Another ServiceAccount: every Secret in the namespace would be reachable.
deny deny-default-sa.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spark-guard-probe-default-sa
  namespace: ${NS}
spec:
  serviceAccountName: default
  restartPolicy: Never
  containers:
    - name: probe
      image: ${IMAGE}
EOF

# 2. A Secret volume: the pod would read a Secret the executors never need.
deny deny-secret-volume.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spark-guard-probe-secret
  namespace: ${NS}
spec:
  serviceAccountName: spark-executor
  automountServiceAccountToken: true
  restartPolicy: Never
  volumes:
    - name: probe-secret
      secret:
        secretName: keycloak-admin
  containers:
    - name: probe
      image: ${IMAGE}
      volumeMounts:
        - name: probe-secret
          mountPath: /probe
EOF

# 3. Host access: the pod would see the node's network.
deny deny-host-network.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spark-guard-probe-host-network
  namespace: ${NS}
spec:
  serviceAccountName: spark-executor
  hostNetwork: true
  restartPolicy: Never
  volumes:
    - name: spark-local-dir-1
      emptyDir: {}
  containers:
    - name: probe
      image: ${IMAGE}
      volumeMounts:
        - name: spark-local-dir-1
          mountPath: /tmp
EOF

if kubectl -n "$NS" apply --dry-run=server --as="$SA" -f scripts/fixtures/spark-executor-pod.yaml >/dev/null 2>&1; then
  echo "✓ the measured executor shape is admitted"
else
  echo "✗ the measured executor shape was denied — a real Spark query can no longer start executors"; problems=$((problems + 1))
fi
[ "$problems" -eq 0 ] && { echo "PASS (4 cases: 3 denied, 1 admitted)"; exit 0; }
echo "FAIL ($problems problem(s))"; exit 1
