#!/usr/bin/env bash
# Fail when the Airflow image digest differs across the three places it is pinned:
#   - helm-values/airflow.yaml: images.airflow.digest (the Deployments)
#   - helm-values/airflow.yaml: AIRFLOW__KUBERNETES_EXECUTOR__WORKER_CONTAINER_TAG (task pods; platform#203)
#   - manifests/airflow-group-roles.yaml: the group-roles CronJob container image (platform#572)
# Moving the demo image by hand means editing all three.
#
#   bash scripts/check-airflow-pin.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

file=helm-values/airflow.yaml
deployments="$(sed -n 's/^    digest: \(sha256:[0-9a-f]\{64\}\)$/\1/p' "$file")"
tasks="$(grep -A1 'AIRFLOW__KUBERNETES_EXECUTOR__WORKER_CONTAINER_TAG' "$file" \
  | sed -n 's/^ *value: "[a-z0-9.-]*@\(sha256:[0-9a-f]\{64\}\)"$/\1/p')"
manifest="$(sed -n 's/^ *ghcr\.io\/stardelt\/airflow:[a-z0-9.-]*@\(sha256:[0-9a-f]\{64\}\)$/\1/p' \
  manifests/airflow-group-roles.yaml)"

if [ -z "$deployments" ] || [ -z "$tasks" ] || [ -z "$manifest" ]; then
  echo "check-airflow-pin: could not read all three digests (deployments='$deployments' tasks='$tasks' manifest='$manifest')" >&2
  exit 1
fi
if [ "$deployments" != "$tasks" ]; then
  echo "check-airflow-pin: the Deployments run $deployments but task pods are pinned to $tasks" >&2
  echo "Edit both places in $file when the Airflow image changes." >&2
  exit 1
fi
if [ "$manifest" != "$deployments" ]; then
  echo "check-airflow-pin: the group-roles CronJob runs $manifest but the Deployments run $deployments" >&2
  echo "Edit manifests/airflow-group-roles.yaml too when the Airflow image changes." >&2
  exit 1
fi
echo "check-airflow-pin: OK ($deployments, three places)"
