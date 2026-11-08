#!/usr/bin/env bash
# Prove that the live Deployments run the digests this repository pins.
#
# Why: the recurring failure is a correct pin plus a Deployment that was never rolled to it
# (stardelt-platform#697, #704, #503, #501, #509, #510). verify-images proves a pin is readable,
# check-pins proves the registry tag has not moved; neither asks the cluster what it runs.
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

# app | Deployment | pin file | how to read the pin
rows=(
  "nova|nova|manifests/nova-deployment.yaml|image"
  "stardelt-operator|stardelt-operator|helm-values/operator.yaml|tag"
  "spark|spark-connect|manifests/spark.yaml|image"
  "superset|superset|helm-values/superset.yaml|tag"
  "airflow|airflow-api-server|helm-values/airflow.yaml|value"
)

pins="$(python3 - "${rows[@]}" <<'PY'
import re, sys

for row in sys.argv[1:]:
    app, deploy, path, kind = row.split("|")
    text = open(path, encoding="utf-8").read()
    if kind in ("tag", "value"):
        m = re.search(r"^\s*(?:tag|value):\s*[\"']?\S+@(sha256:[0-9a-f]{64})", text, re.M)
    else:
        m = re.search(r"^\s*image:\s*(ghcr\.io/stardelt/[^\s\"']+@sha256:[0-9a-f]{64})", text, re.M)
    if not m:
        print(f"{app}\t{deploy}\t{path}\tERROR: no digest pin")
        continue
    digest = m.group(1) if kind in ("tag", "value") else m.group(1).rsplit("@", 1)[1]
    print(f"{app}\t{deploy}\t{path}\t{digest}")
PY
)"

status=0
while IFS=$'\t' read -r app deploy path digest; do
  if [[ "$digest" == ERROR:* ]]; then
    echo "? $app $digest"; status=3; continue
  fi
  live="$(kubectl -n "$NAMESPACE" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ -z "$live" ]]; then
    echo "? $app no Deployment $deploy in namespace $NAMESPACE"; status=3; continue
  fi
  if [[ "$live" == *"@$digest" ]]; then
    printf '✓ %-18s %s\n' "$app" "${digest:0:19}… matches $path"
  else
    live_digest="${live##*@}"
    printf '✗ %-18s live %s… != pin %s… (%s) — run ./scripts/pin-image.sh %s\n' \
      "$app" "${live_digest:0:19}" "${digest:0:19}" "$path" "$app"
    status=1
  fi
done <<< "$pins"

case "$status" in
  0) echo "verify-pins: PASS (live Deployments carry the checked-in pins)" ;;
  1) echo "verify-pins: FAIL (a Deployment does not run its pin)" >&2 ;;
  *) echo "verify-pins: UNVERIFIED (a pin or Deployment could not be read)" >&2 ;;
esac
exit "$status"
