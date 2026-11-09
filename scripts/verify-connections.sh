#!/usr/bin/env bash
# Prove the connection path is wired in the live platform: the Pipeline CRD carries
# `spec.tasks[].connection`, the Airflow pipeline reader may read Connections, and the DAG
# processor's loader image resolves a connection into `CONN_` variables.
#
# Why: the path is three repositories (operator CRD, platform Role, demos loader image). On
# 2026-11-09 two of the three were behind their pins while every repository's CI was green
# (stardelt-platform#720). The schema half is `verify-crds`' job; this script checks the two
# cross-repository links it cannot see.
#
#   scripts/verify-connections.sh
#
# Exit codes: 0 everything is wired, 1 one link is missing, 3 nothing could be proved.
# Needs: kubectl, python3.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NAMESPACE="${NAMESPACE:-stardelt}"
DAG_PROCESSOR="${DAG_PROCESSOR:-airflow-dag-processor}"
READER="${READER:-airflow-pipeline-reader}"

command -v kubectl >/dev/null || { echo "verify-connections: UNVERIFIED (kubectl not found)" >&2; exit 3; }
command -v python3 >/dev/null || { echo "verify-connections: UNVERIFIED (python3 not found)" >&2; exit 3; }

status=0
ok() { printf '✓ %-8s %s\n' "$1" "$2"; }
bad() { printf '✗ %-8s %s\n' "$1" "$2" >&2; status=1; }
unknown() { printf '? %-8s %s\n' "$1" "$2" >&2; status=3; }

crd="$(kubectl get crd pipelines.stardelt.io -o json 2>/dev/null || true)"
if [ -z "$crd" ]; then
  unknown crd "pipelines.stardelt.io is not readable"
else
  type="$(printf '%s' "$crd" | python3 -c '
import json, sys
spec = json.load(sys.stdin)["spec"]["versions"][0]["schema"]["openAPIV3Schema"]
print(spec["properties"]["spec"]["properties"]["tasks"]["items"]["properties"]
      .get("connection", {}).get("type", ""))
' 2>/dev/null || true)"
  if [ "$type" = "string" ]; then
    ok crd "spec.tasks[].connection exists (string)"
  else
    bad crd "the Pipeline CRD has no spec.tasks[].connection (operator#408; run ./scripts/pin-image.sh stardelt-operator)"
  fi
fi

role="$(kubectl -n "$NAMESPACE" get role "$READER" -o json 2>/dev/null || true)"
if [ -z "$role" ]; then
  unknown role "Role $READER is not readable"
elif printf '%s' "$role" | python3 -c '
import json, sys
rules = json.load(sys.stdin).get("rules") or []
resources = {r for rule in rules for r in (rule.get("resources") or [])}
sys.exit(0 if "connections" in resources else 1)
'; then
  ok role "$READER may read connections"
else
  bad role "$READER cannot read connections (run make step-airflow)"
fi

count="$(kubectl -n "$NAMESPACE" exec "deploy/$DAG_PROCESSOR" -c dag-processor -- \
  grep -c 'CONN_' /opt/airflow/dags/stardelt_pipelines/notebook.py 2>/dev/null || true)"
if [ -z "$count" ]; then
  unknown loader "the loader inside deploy/$DAG_PROCESSOR could not be read"
elif [ "$count" -gt 0 ]; then
  ok loader "the DAG processor image resolves CONN_ variables ($count references)"
else
  bad loader "the DAG processor image predates demos#63 (no CONN_ reference; run make step-airflow)"
fi

case "$status" in
  0) echo "verify-connections: PASS (the CRD, the reader Role and the loader image carry the connection path)" ;;
  1) echo "verify-connections: FAIL (a link of the connection path is missing)" >&2 ;;
  *) echo "verify-connections: UNVERIFIED (a link could not be read)" >&2 ;;
esac
exit "$status"
