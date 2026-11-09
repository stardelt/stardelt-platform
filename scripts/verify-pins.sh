#!/usr/bin/env bash
# Prove that the live Deployments, the group-roles CronJob and the two spawned-notebook pins run
# the digests this repository pins.
#
# Why: the recurring failure is a correct pin plus a Deployment that was never rolled to it
# (stardelt-platform#697, #704, #503, #501, #509, #510). verify-images proves a pin is readable,
# check-pins proves the registry tag has not moved; neither asks the cluster what it runs.
# The group-roles CronJob is applied by make step-airflow, and the two notebook pins are not
# Deployments: the JupyterHub spawn image lives in Secret hub and the pipeline notebook image in
# Airflow's PIPELINE_NOTEBOOK_IMAGE, both pinned by hand.
#
#   scripts/verify-pins.sh
#
# Exit codes: 0 all match, 1 at least one differs, 3 the check proved nothing (no kubectl, no
# Deployment, a pin that cannot be parsed). Needs: kubectl, python3.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NAMESPACE="${NAMESPACE:-stardelt}"

command -v kubectl >/dev/null || { echo "verify-pins: UNVERIFIED (kubectl not found)" >&2; exit 3; }
command -v python3 >/dev/null || { echo "verify-pins: UNVERIFIED (python3 not found)" >&2; exit 3; }

# The rows read the pin files from this working tree. A checkout behind origin/main compares the
# cluster with old pins and prints a confident FAIL (2026-11-09: the main checkout was three days
# behind). Name the two revisions, like pin-image.sh does for the operator checkout; do not fail.
head_rev="$(git rev-parse HEAD 2>/dev/null || true)"
main_rev="$(git rev-parse --verify --quiet origin/main 2>/dev/null || true)"
if [ -n "$head_rev" ] && [ -n "$main_rev" ] && [ "$head_rev" != "$main_rev" ]; then
  printf '! verify-pins: this checkout is at %s, origin/main is %s — the pins below may be stale (git pull)\n' \
    "${head_rev:0:7}" "${main_rev:0:7}" >&2
fi

# app | Deployment | pin file | how to read the pin
rows=(
  "nova|nova|manifests/nova-deployment.yaml|image"
  "stardelt-operator|stardelt-operator|helm-values/operator.yaml|tag"
  "spark|spark-connect|manifests/spark.yaml|image"
  "superset|superset|helm-values/superset.yaml|tag"
  "airflow|airflow-api-server|helm-values/airflow.yaml|value"
  "notebook|hub|helm-values/jupyterhub.yaml|hub"
  "notebook-task|airflow-dag-processor|helm-values/airflow.yaml|env"
  "group-roles|airflow-group-roles|manifests/airflow-group-roles.yaml|cronjob"
)

pins="$(python3 - "${rows[@]}" <<'PY'
import re, sys

for row in sys.argv[1:]:
    app, deploy, path, kind = row.split("|")
    text = open(path, encoding="utf-8").read()
    if kind == "hub":
        m = re.search(r"^\s*tag:\s*[\"']?\S+@(sha256:[0-9a-f]{64})", text, re.M)
    elif kind == "env":
        m = re.search(r"name:\s*PIPELINE_NOTEBOOK_IMAGE\s*\n\s*value:\s*\S+@(sha256:[0-9a-f]{64})", text, re.M)
    elif kind == "cronjob":
        m = re.search(
            r"^\s*image:\s*>-\s*ghcr\.io/stardelt/[^\s\"']+@(sha256:[0-9a-f]{64})",
            text,
            re.M,
        )
    elif kind in ("tag", "value"):
        m = re.search(r"^\s*(?:tag|value):\s*[\"']?\S+@(sha256:[0-9a-f]{64})", text, re.M)
    else:
        m = re.search(r"^\s*image:\s*(ghcr\.io/stardelt/[^\s\"']+@sha256:[0-9a-f]{64})", text, re.M)
    if not m:
        print(f"{app}\t{deploy}\t{path}\tERROR: no digest pin")
        continue
    digest = m.group(1).rsplit("@", 1)[-1] if kind == "image" else m.group(1)
    print(f"{app}\t{deploy}\t{path}\t{digest}\t{kind}")
PY
)"

status=0
while IFS=$'\t' read -r app deploy path digest kind; do
  if [[ "$digest" == ERROR:* ]]; then
    echo "? $app $digest"; status=3; continue
  fi
  case "$kind" in
    hub) live="$(kubectl -n "$NAMESPACE" get secret hub \
             -o jsonpath='{.data.values\.yaml}' 2>/dev/null | base64 -d \
             | grep -m1 'tag: dev@sha256:' || true)" ;;
    env) live="$(kubectl -n "$NAMESPACE" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PIPELINE_NOTEBOOK_IMAGE")].value}' 2>/dev/null || true)" ;;
    cronjob) live="$(kubectl -n "$NAMESPACE" get cronjob "$deploy" \
             -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)" ;;
    *) live="$(kubectl -n "$NAMESPACE" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)" ;;
  esac
  if [[ -z "$live" ]]; then
    echo "? $app no pin in the live configuration"; status=3; continue
  fi
  if [[ "$live" == *"@$digest" ]]; then
    printf '✓ %-18s %s\n' "$app" "${digest:0:19}… matches $path"
  else
    case "$kind" in
      hub) hint="run make install-notebooks" ;;
      env) hint="run make step-airflow" ;;
      cronjob) hint="run make step-airflow" ;;
      *) hint="run ./scripts/pin-image.sh $app" ;;
    esac
    live_digest="${live##*@}"
    printf '✗ %-18s live %s… != pin %s… (%s) — %s\n' \
      "$app" "${live_digest:0:19}" "${digest:0:19}" "$path" "$hint"
    status=1
  fi
done <<< "$pins"

case "$status" in
  0) echo "verify-pins: PASS (live Deployments, the group-roles CronJob and spawned-notebook pins carry the checked-in pins)" ;;
  1) echo "verify-pins: FAIL (a pin does not match the live configuration)" >&2 ;;
  *) echo "verify-pins: UNVERIFIED (a pin or Deployment could not be read)" >&2 ;;
esac
exit "$status"
