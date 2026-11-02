#!/usr/bin/env bash
# Fail when the Airflow create-user Job in helm-values/airflow.yaml would not create the `nova-api`
# service user: read-only (Viewer), with the username and password of the airflow-nova-api Secret,
# and with its password reset to the Secret's value when the user already exists (platform#476).
# A clean install without this user leaves Nova's Pipelines page with HTTP 401 from Airflow.
#
#   bash scripts/check-airflow-users.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

file=helm-values/airflow.yaml
block="$(sed -n '/^createUserJob:/,$p' "$file")"

fail() {
  echo "check-airflow-users: $1" >&2
  exit 1
}

[ -n "$block" ] || fail "no createUserJob block in $file"
[ "$(printf '%s\n' "$block" | grep -c 'name: airflow-nova-api$')" -eq 2 ] \
  || fail "createUserJob.env must read username and password from the airflow-nova-api Secret"
[ "$(printf '%s\n' "$block" | grep -A1 -e '--role Viewer' | grep -c 'AIRFLOW_NOVA_API_USERNAME')" -eq 1 ] \
  || fail "the nova-api user must be created with --role Viewer"
[ "$(printf '%s\n' "$block" | grep -A1 -e 'users reset-password' | grep -c 'AIRFLOW_NOVA_API_USERNAME')" -eq 1 ] \
  || fail "the nova-api password must be reset to the Secret's value (airflow users reset-password)"
echo "check-airflow-users: OK"
