#!/usr/bin/env bash
# Fail when the notebook image the JupyterHub single-user pods run (singleuser.image.tag in
# helm-values/jupyterhub.yaml) differs from the image a notebook task pod is told to run
# (PIPELINE_NOTEBOOK_IMAGE in helm-values/airflow.yaml).
#
# A task pod on a stale digest is an image without papermill (platform#286) and without the run
# wrapper (platform#315): the notebook task starts and then fails inside the pod, which is
# exactly what platform#316 exists to prevent. `make pin-images` cannot cover this — spawned
# single-user pods and KubernetesPodOperator pods are not Deployments, so both pins are by hand.
#
#   bash scripts/check-notebook-image-pin.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Read the digest that follows the marker, not the first digest in the file: a comment above
# the pin names no digest today, but the marker keeps the two reads on the right lines.
digest_after() { # digest_after <file> <marker> <key>
  awk -v marker="$2" -v key="$3" '
    $0 ~ marker { found = 1; next }
    found && $0 ~ key {
      if (match($0, /sha256:[0-9a-f][0-9a-f]*/)) print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$1"
}

hub="$(digest_after helm-values/jupyterhub.yaml 'name: ghcr.io/stardelt/jupyter-singleuser$' '^[[:space:]]*tag:')"
task="$(digest_after helm-values/airflow.yaml 'name: PIPELINE_NOTEBOOK_IMAGE$' '^[[:space:]]*value:')"

# Both must be a full digest: a tag-only pin let a cached image serve stale code (platform#203).
for pin in "$hub" "$task"; do
  if [[ ! "$pin" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "check-notebook-image-pin: no full sha256 digest (jupyterhub='${hub}' airflow='${task}')" >&2
    exit 1
  fi
done

if [ "$hub" != "$task" ]; then
  echo "check-notebook-image-pin: the single-user pods run $hub" >&2
  echo "check-notebook-image-pin: but notebook task pods are pinned to $task" >&2
  echo "Set the same digest in helm-values/jupyterhub.yaml (singleuser.image.tag) and" >&2
  echo "helm-values/airflow.yaml (PIPELINE_NOTEBOOK_IMAGE) — bump both." >&2
  exit 1
fi

echo "check-notebook-image-pin: OK ($hub)"
