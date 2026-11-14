#!/usr/bin/env bash
# The three Spark drivers — Connect, StreamApp and batch — may create executor pods and
# their own spark-*-conf-map ConfigMaps only (platform#1096, #1302, #1307, #1308).
#
#   NS=stardelt bash scripts/verify-spark-pod-guard.sh
#
# Read-only against the cluster: every pod and ConfigMap is created/deleted with
# --dry-run=server as one of spark-connect, spark-stream-driver or spark-batch-driver,
# so the admission policies decide and nothing is persisted.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS="${NS:-${NAMESPACE:-stardelt}}"
SA="system:serviceaccount:${NS}:spark-connect"
SA_STREAM="system:serviceaccount:${NS}:spark-stream-driver"
SA_BATCH="system:serviceaccount:${NS}:spark-batch-driver"
IMAGE="ghcr.io/stardelt/spark:dev@sha256:1acae61431891d5354fc959374adf3d5c1fbfc5cf7a7a39b099ef7c6eba89709"
problems=0
command -v kubectl >/dev/null 2>&1 || { echo "UNVERIFIED (kubectl not found)"; exit 3; }

POLICIES="spark-connect-executor-pods spark-connect-configmaps \
          spark-stream-executor-pods spark-stream-configmaps \
          spark-batch-executor-pods spark-batch-configmaps"
for policy in $POLICIES; do
  kubectl get validatingadmissionpolicy "$policy" >/dev/null 2>&1 || {
    echo "UNVERIFIED (ValidatingAdmissionPolicy $policy is not installed — kubectl < 1.30, or make install-spark / step-airflow has not run)"; exit 3; }
done

deny() {  # <sa> <policy> <label>; the YAML to apply is on stdin
  local sa="$1" policy="$2" label="$3" out
  out="$(mktemp)"; trap 'rm -f "$out"' RETURN
  if kubectl -n "$NS" apply --dry-run=server --as="$sa" -f - >"$out" 2>&1; then
    echo "✗ ${label} was admitted; the policy should deny it"; problems=$((problems + 1))
  elif grep -q "$policy" "$out"; then
    echo "✓ ${label} denied by the policy"
  else
    echo "✗ ${label} was refused, but not by $policy: $(tail -1 "$out")"; problems=$((problems + 1))
  fi
}

deny_configmap() {  # <sa> <policy> <label>: a ConfigMap that is not Spark's may not be created
  local sa="$1" policy="$2" label="$3" out
  out="$(mktemp)"; trap 'rm -f "$out"' RETURN
  if kubectl -n "$NS" apply --dry-run=server --as="$sa" -f - >"$out" 2>&1 <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-realm-probe
  namespace: ${NS}
data: { probe: "1" }
EOF
  then
    echo "✗ ${label}: a foreign ConfigMap was admitted; the policy should deny it"; problems=$((problems + 1))
  elif grep -q "$policy" "$out"; then
    echo "✓ ${label} denied by the policy"
  else
    echo "✗ ${label}: a foreign ConfigMap was refused, but not by $policy: $(tail -1 "$out")"; problems=$((problems + 1))
  fi
}

deny_configmap_delete() {  # <sa> <policy> <label>: and a foreign ConfigMap may not be deleted either
  local sa="$1" policy="$2" label="$3" out
  out="$(mktemp)"; trap 'rm -f "$out"' RETURN
  # `kube-root-ca.crt` exists in every namespace and is not ours to remove.
  if kubectl -n "$NS" delete configmap kube-root-ca.crt --dry-run=server --as="$sa" >"$out" 2>&1; then
    echo "✗ ${label}: the driver can delete ConfigMap kube-root-ca.crt; the policy should deny it"; problems=$((problems + 1))
  elif grep -q "$policy" "$out"; then
    echo "✓ ${label} denied by the policy"
  else
    echo "✗ ${label}: deleting a foreign ConfigMap was refused, but not by $policy: $(tail -1 "$out")"; problems=$((problems + 1))
  fi
}

admit_configmap() {  # <sa> <label>: the ConfigMap a session writes is admitted
  local sa="$1" label="$2"
  if kubectl -n "$NS" apply --dry-run=server --as="$sa" -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spark-exec-0123456789abcdef-conf-map
  namespace: ${NS}
data: { probe: "1" }
EOF
  then
    echo "✓ ${label} admitted"
  else
    echo "✗ ${label}: Spark's own ConfigMap was denied — a real query can no longer start"; problems=$((problems + 1))
  fi
}

# --- The Connect driver -----------------------------------------------------------

# 1. Another ServiceAccount: every Secret in the namespace would be reachable.
deny "$SA" spark-connect-executor-pods deny-default-sa.yaml <<EOF
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
deny "$SA" spark-connect-executor-pods deny-secret-volume.yaml <<EOF
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
deny "$SA" spark-connect-executor-pods deny-host-network.yaml <<EOF
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

# 4. A ConfigMap that is not Spark's: the driver may not create one.
if out="$(kubectl -n "$NS" apply --dry-run=server --as="$SA" -f - 2>&1 <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-realm-probe
  namespace: ${NS}
data: { probe: "1" }
EOF
)"; then
  echo "✗ a foreign ConfigMap was admitted; the policy should deny it"; problems=$((problems + 1))
elif grep -q 'spark-connect-configmaps' <<<"$out"; then
  echo "✓ creating a foreign ConfigMap is denied by the policy"
else
  echo "✗ a foreign ConfigMap was refused, but not by the policy: $(tail -1 <<<"$out")"; problems=$((problems + 1))
fi

# 5. A ConfigMap that is not Spark's: the driver may not delete one either.
#    `kube-root-ca.crt` exists in every namespace and is not ours to remove.
if out="$(kubectl -n "$NS" delete configmap kube-root-ca.crt --dry-run=server --as="$SA" 2>&1)"; then
  echo "✗ the driver can delete ConfigMap kube-root-ca.crt; the policy should deny it"; problems=$((problems + 1))
elif grep -q 'spark-connect-configmaps' <<<"$out"; then
  echo "✓ deleting a foreign ConfigMap is denied by the policy"
else
  echo "✗ deleting a foreign ConfigMap was refused, but not by the policy: $(tail -1 <<<"$out")"; problems=$((problems + 1))
fi

# 6. The ConfigMap a session writes is admitted (create; nothing is persisted).
if kubectl -n "$NS" apply --dry-run=server --as="$SA" -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spark-exec-0123456789abcdef-conf-map
  namespace: ${NS}
data: { probe: "1" }
EOF
then
  echo "✓ a Spark session ConfigMap is admitted"
else
  echo "✗ Spark's own ConfigMap was denied — a real query can no longer start"; problems=$((problems + 1))
fi

# 7. The measured executor shape a real query produces.
if kubectl -n "$NS" apply --dry-run=server --as="$SA" -f scripts/fixtures/spark-executor-pod.yaml >/dev/null 2>&1; then
  echo "✓ the measured executor shape is admitted"
else
  echo "✗ the measured executor shape was denied — a real Spark query can no longer start executors"; problems=$((problems + 1))
fi

# --- The StreamApp driver (platform#1307) -----------------------------------------

deny "$SA_STREAM" spark-stream-executor-pods "a default-ServiceAccount pod from the stream driver" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spark-guard-probe-stream-default-sa
  namespace: ${NS}
spec:
  serviceAccountName: default
  restartPolicy: Never
  containers:
    - name: probe
      image: ${IMAGE}
EOF

deny_configmap "$SA_STREAM" spark-stream-configmaps "a foreign ConfigMap created by the stream driver"
deny_configmap_delete "$SA_STREAM" spark-stream-configmaps "kube-root-ca.crt deletion by the stream driver"
admit_configmap "$SA_STREAM" "a Spark ConfigMap created by the stream driver"

# --- The batch driver (platform#1302) ---------------------------------------------

deny "$SA_BATCH" spark-batch-executor-pods "a default-ServiceAccount pod from the batch driver" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spark-guard-probe-batch-default-sa
  namespace: ${NS}
spec:
  serviceAccountName: default
  restartPolicy: Never
  containers:
    - name: probe
      image: ${IMAGE}
EOF

deny_configmap "$SA_BATCH" spark-batch-configmaps "a foreign ConfigMap created by the batch driver"
deny_configmap_delete "$SA_BATCH" spark-batch-configmaps "kube-root-ca.crt deletion by the batch driver"
admit_configmap "$SA_BATCH" "a Spark ConfigMap created by the batch driver"

[ "$problems" -eq 0 ] && { echo "PASS (15 cases: 11 denied, 4 admitted)"; exit 0; }
echo "FAIL ($problems problem(s))"; exit 1
