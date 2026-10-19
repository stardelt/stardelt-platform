#!/usr/bin/env bash
# Fail when the Airflow image digest the Deployments run (images.airflow.digest) differs from the
# digest the KubernetesExecutor task pods are told to run (the WORKER_CONTAINER_TAG variable), both
# in helm-values/airflow.yaml. Task pods built from a bare tag ran a stale cached image (platform#203).
#
#   bash scripts/check-airflow-pin.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

file=helm-values/airflow.yaml
deployments="$(sed -n 's/^    digest: \(sha256:[0-9a-f]\{64\}\)$/\1/p' "$file")"
tasks="$(grep -A1 'AIRFLOW__KUBERNETES_EXECUTOR__WORKER_CONTAINER_TAG' "$file" \
  | sed -n 's/^ *value: "[a-z0-9.-]*@\(sha256:[0-9a-f]\{64\}\)"$/\1/p')"

if [ -z "$deployments" ] || [ -z "$tasks" ]; then
  echo "check-airflow-pin: could not read both digests from $file (deployments='$deployments' tasks='$tasks')" >&2
  exit 1
fi
if [ "$deployments" != "$tasks" ]; then
  echo "check-airflow-pin: the Deployments run $deployments but task pods are pinned to $tasks" >&2
  echo "Edit both places in $file when the Airflow image changes." >&2
  exit 1
fi
echo "check-airflow-pin: OK ($deployments)"
