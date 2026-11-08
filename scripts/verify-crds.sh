#!/usr/bin/env bash
# Prove the live stardelt CRDs carry the schema of the operator checkout.
#
#   OPERATOR_DIR=../stardelt-operator bash scripts/verify-crds.sh
#
# Why: Helm applies chart/crds/ on `helm install` only, and the operator's image carries its
# API. A merge that adds a field moves the binary but not the cluster unless the CRDs are
# applied (stardelt-platform#539, and operator#386 again on 2026-11-08: the live
# platforminstances schema had no clusterOperation). `kubectl diff` compares the file with the
# live object through a server-side apply dry run; any output is drift.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OPERATOR_DIR="${OPERATOR_DIR:-../stardelt-operator}"
crds="$OPERATOR_DIR/chart/crds"
revision="working tree"
if git -C "$OPERATOR_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  for ref in origin/main origin/master; do
    if git -C "$OPERATOR_DIR" rev-parse --verify "$ref" >/dev/null 2>&1; then
      CRDS_TMP="$(mktemp -d)"
      trap 'rm -rf "$CRDS_TMP"' EXIT
      git -C "$OPERATOR_DIR" archive "$ref" chart/crds | tar -x -C "$CRDS_TMP"
      crds="$CRDS_TMP/chart/crds"
      revision="$ref ($(git -C "$OPERATOR_DIR" rev-parse --short "$ref"))"
      break
    fi
  done
fi

command -v kubectl >/dev/null || { echo "verify-crds: kubectl not found" >&2; exit 1; }
[ -d "$crds" ] || { echo "verify-crds: no operator CRDs at $crds (set OPERATOR_DIR)" >&2; exit 1; }

out="$(kubectl diff -f "$crds" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "verify-crds: PASS (live CRDs match $revision:chart/crds)"
  exit 0
fi
if [ "$rc" -eq 1 ]; then
  printf '%s\n' "$out" | head -60
  echo "verify-crds: FAIL (the live CRD schema differs from $revision:chart/crds — run 'kubectl apply --server-side --force-conflicts -f $crds/' or 'make install-operator')" >&2
  exit 1
fi
printf '%s\n' "$out" | head -20
echo "verify-crds: ERROR (kubectl diff exited $rc)" >&2
exit 1
