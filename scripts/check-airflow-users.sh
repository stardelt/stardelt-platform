#!/usr/bin/env bash
# Fail when the Airflow create-user Job in helm-values/airflow.yaml would not create the `nova-api`
# service user: read-only (Viewer), with the username and password of the airflow-nova-api Secret,
# and with its password reset to the Secret's value when the user already exists (platform#476).
# A clean install without this user leaves Nova's Pipelines page with HTTP 401 from Airflow.
# It also checks that people who sign in are `stardelt-member`, not `Viewer`: the global read on
# DAGs and DAG Runs of a plain Viewer shows every group's DAGs, runs, logs and code (platform#477).
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
[ "$(grep -cF -e 'AUTH_USER_REGISTRATION_ROLE = "stardelt-member"' "$file")" -eq 1 ] \
  || fail "the registration role must be stardelt-member: a plain Viewer sees every group's DAGs"
[ "$(printf '%s\n' "$block" | grep -cF -e 'sm.add_role("stardelt-member")')" -eq 1 ] \
  || fail "createUserJob must create the role stardelt-member"
[ "$(printf '%s\n' "$block" | grep -cF -e 'sm.find_role("Viewer").permissions')" -eq 1 ] \
  || fail "stardelt-member must be built from the permissions of Viewer"
[ "$(printf '%s\n' "$block" | grep -cF -e 'GLOBAL = {("can_read", "DAGs"), ("can_read", "DAG Runs")}')" -eq 1 ] \
  || fail "stardelt-member must not hold the global read on DAGs and DAG Runs"
echo "check-airflow-users: OK"
