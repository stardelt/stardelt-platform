#!/usr/bin/env bash
# Prove the RUNNING operator carries the golden values that were merged, not only that its image
# tag is current. values/*.yaml is compiled into the binary: an image built before a values merge
# prints the old values. Unlike scripts/check-operator-pins.sh (two checkouts) and verify-pins.sh
# (image digests), this asks the Deployment.
#
# Exit codes: 0 every probe passes, 1 a value differs or the binary cannot answer, 3 the check
# proved nothing (no kubectl, no Deployment). Needs: kubectl, grep.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS="${NAMESPACE:-stardelt}"
SEAWEEDFS_VOLUME_SIZE="${SEAWEEDFS_VOLUME_SIZE:-20Gi}"
JUPYTERHUB_HOME_SIZE="${JUPYTERHUB_HOME_SIZE:-2Gi}"

command -v kubectl >/dev/null || { echo "verify-operator-values: UNVERIFIED (kubectl not found)" >&2; exit 3; }
kubectl -n "$NS" get deploy stardelt-operator >/dev/null 2>&1 \
  || { echo "verify-operator-values: UNVERIFIED (no Deployment stardelt-operator in $NS)" >&2; exit 3; }

digest_of() { grep -m1 -oE 'sha256:[0-9a-f]{64}' "$1"; }
LOADER="$(digest_of helm-values/airflow.yaml)"
NOTEBOOK="$(digest_of helm-values/jupyterhub.yaml)"
SUPERSET="$(digest_of helm-values/superset.yaml)"

pass=0
fail=0

check_contains() { # label, haystack, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    printf '✓ %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '✗ %s: %s is not in the running operator\n' "$1" "\`$3\`" >&2
    fail=$((fail + 1))
  fi
}

section_of() { # stdin -> one top-level mapping of a `values <component> full` document
  awk -v name="$1" '
    $0 == name ":" { inside = 1; print; next }
    inside && /^[^[:space:]#]/ { exit }
    inside { print }
  '
}

for component in airflow jupyterhub superset seaweedfs; do
  if ! out="$(kubectl -n "$NS" exec deploy/stardelt-operator -- \
      stardelt-operator values "$component" full 2>&1)"; then
    printf '✗ %s: %s failed: %s\n' "$component" "\`values $component full\`" "$out" >&2
    fail=$((fail + 1))
    continue
  fi
  case "$component" in
    airflow)
      check_contains "airflow: nova-api role" "$out" "stardelt-nova-operator"
      check_contains "airflow: loader image" "$out" "$LOADER"
      ;;
    jupyterhub)
      check_contains "jupyterhub: home size" "$out" "capacity: $JUPYTERHUB_HOME_SIZE"
      check_contains "jupyterhub: notebook image" "$out" "$NOTEBOOK"
      ;;
    superset)
      check_contains "superset: image" "$out" "$SUPERSET"
      ;;
    seaweedfs)
      volume="$(printf '%s\n' "$out" | section_of volume)"
      check_contains "seaweedfs: volume sizing block" "$volume" "name: data"
      check_contains "seaweedfs: volume size" "$volume" "size: $SEAWEEDFS_VOLUME_SIZE"
      ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  printf 'verify-operator-values: FAIL (%d of %d probes)\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'verify-operator-values: PASS (%d probes)\n' "$pass"
