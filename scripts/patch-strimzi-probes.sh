#!/usr/bin/env bash
# Give the Strimzi controller's probes a timeout that survives a busy node (stardelt-platform#665).
#
# The strimzi-kafka-operator chart templates only initialDelaySeconds and periodSeconds
# (templates/060-Deployment-strimzi-cluster-operator.yaml); the other fields are Kubernetes'
# defaults, so timeoutSeconds 1 and failureThreshold 3. A node stall of ~17 s then kills the
# controller that reconciles every KafkaTopic, although the broker and `get kafka` stay
# Ready=True. The chart exposes no value for these fields, so the Deployment is patched after
# the Helm release. A Helm upgrade rewrites the pod template and drops the patch, which is why
# `make install-kafka` runs this afterwards.
set -euo pipefail

NS="${NAMESPACE:-stardelt}"
DEPLOYMENT="strimzi-cluster-operator"

if ! kubectl -n "$NS" get deployment "$DEPLOYMENT" >/dev/null 2>&1; then
  echo "– patch-strimzi-probes: no deployment/$DEPLOYMENT in $NS (streaming not installed) — skipped"
  exit 0
fi

kubectl -n "$NS" patch deployment "$DEPLOYMENT" --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "strimzi-cluster-operator",
    "livenessProbe":  {"timeoutSeconds": 10, "failureThreshold": 10},
    "readinessProbe": {"timeoutSeconds": 10, "failureThreshold": 6}
  }]}}}
}' >/dev/null

kubectl -n "$NS" rollout status "deployment/$DEPLOYMENT" --timeout=3m

kubectl -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{range .spec.template.spec.containers[?(@.name=="strimzi-cluster-operator")]}{"liveness timeoutSeconds="}{.livenessProbe.timeoutSeconds}{" failureThreshold="}{.livenessProbe.failureThreshold}{" · readiness timeoutSeconds="}{.readinessProbe.timeoutSeconds}{" failureThreshold="}{.readinessProbe.failureThreshold}{"\n"}{end}'
