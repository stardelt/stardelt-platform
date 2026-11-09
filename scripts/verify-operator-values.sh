#!/usr/bin/env bash
# Prove the RUNNING operator carries the golden values that were merged, not only that its image
# tag is current. values/*.yaml is compiled into the binary: an image built before a values merge
# prints the old values. Unlike scripts/check-operator-pins.sh (two checkouts) and verify-pins.sh
# (image digests), this asks the Deployment. A second loop passes `--identity`: that proves the
# identity overlays (values/<component>-identity.yaml) are compiled in too, which the plain output
# cannot show because it never contains them.
#
# Exit codes: 0 every probe passes, 1 a value differs or the binary cannot answer, 3 the check
# proved nothing (no kubectl, no Deployment). Needs: kubectl, grep.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS="${NAMESPACE:-stardelt}"
SEAWEEDFS_VOLUME_SIZE="${SEAWEEDFS_VOLUME_SIZE:-20Gi}"
JUPYTERHUB_HOME_SIZE="${JUPYTERHUB_HOME_SIZE:-2Gi}"
# The identity overlays substitute this placeholder host; the check only proves the overlay is
# compiled into the binary, so any reserved domain works (RFC 2606).
BASE_DOMAIN="${BASE_DOMAIN:-example.test}"

command -v kubectl >/dev/null || { echo "verify-operator-values: UNVERIFIED (kubectl not found)" >&2; exit 3; }
kubectl -n "$NS" get deploy stardelt-operator >/dev/null 2>&1 \
  || { echo "verify-operator-values: UNVERIFIED (no Deployment stardelt-operator in $NS)" >&2; exit 3; }

digest_of() { grep -m1 -oE 'sha256:[0-9a-f]{64}' "$1"; }
LOADER="$(digest_of helm-values/airflow.yaml)"
NOTEBOOK="$(digest_of helm-values/jupyterhub.yaml)"
SUPERSET="$(digest_of helm-values/superset.yaml)"

# A probe records its lines instead of printing them: a short `kubectl exec` stream can cut the
# document's tail, and a probe that misses must be re-read once before it is reported.
PASS_LINES=()
FAIL_LINES=()
pass=0
fail=0
total_pass=0
total_fail=0

check_contains() { # label, haystack, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    PASS_LINES+=("✓ $1")
    pass=$((pass + 1))
  else
    FAIL_LINES+=("✗ $1: \`$3\` is not in the running operator")
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

attempt() { # component [extra args...] -> one read; 0 when every probe of it passed
  local component="$1"
  shift
  PASS_LINES=()
  FAIL_LINES=()
  pass=0
  fail=0
  local out
  local identity=0
  if [ "${1-}" = "--identity" ]; then
    identity=1
  fi
  if ! out="$(kubectl -n "$NS" exec deploy/stardelt-operator -- \
      stardelt-operator values "$component" full "$@" 2>&1)"; then
    FAIL_LINES+=("✗ $component: \`values $component full\` failed: $out")
    fail=$((fail + 1))
    return 1
  fi
  if [ "$identity" -eq 1 ]; then
    case "$component" in
      trino)
        check_contains "trino identity: TLS listener" "$out" "port: 8443"
        check_contains "trino identity: PASSWORD,OAUTH2" "$out" "authenticationType: PASSWORD,OAUTH2"
        check_contains "trino identity: password file" "$out" "passwordAuthSecret: trino-password-db"
        check_contains "trino identity: impersonation rule" "$out" '"original_user": "superset"'
        ;;
      superset)
        check_contains "superset identity: impersonated Trino host" "$out" "trino.$BASE_DOMAIN:443"
        ;;
      jupyterhub)
        check_contains "jupyterhub identity: OIDC client Secret" "$out" "stardelt-oidc-clients"
        ;;
      airflow)
        check_contains "airflow identity: OIDC client Secret" "$out" "stardelt-oidc-clients"
        ;;
    esac
  else
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
        local volume
        volume="$(printf '%s\n' "$out" | section_of volume)"
        check_contains "seaweedfs: volume sizing block" "$volume" "name: data"
        check_contains "seaweedfs: volume size" "$volume" "size: $SEAWEEDFS_VOLUME_SIZE"
        ;;
    esac
  fi
  [ "${#FAIL_LINES[@]}" -eq 0 ]
}

print_attempt() { # the lines of the attempt that is reported
  if [ "${#PASS_LINES[@]}" -gt 0 ]; then
    printf '%s\n' "${PASS_LINES[@]}"
  fi
  if [ "${#FAIL_LINES[@]}" -gt 0 ]; then
    printf '%s\n' "${FAIL_LINES[@]}" >&2
  fi
}

probe() { # component [extra args...] -> one read, and a second when the first missed
  local component="$1"
  if ! attempt "$@"; then
    printf '… %s: re-reading values once\n' "$component" >&2
    attempt "$@" || true
  fi
  print_attempt
  total_pass=$((total_pass + pass))
  total_fail=$((total_fail + fail))
  return 0
}

for component in airflow jupyterhub superset seaweedfs; do
  probe "$component"
done

for component in trino superset jupyterhub airflow; do
  probe "$component" --identity "$BASE_DOMAIN"
done

if [ "$total_fail" -ne 0 ]; then
  printf 'verify-operator-values: FAIL (%d of %d probes)\n' "$total_fail" "$((total_pass + total_fail))"
  exit 1
fi
printf 'verify-operator-values: PASS (%d probes)\n' "$total_pass"
