#!/usr/bin/env bash
# Fail when the Airflow create-user Job in helm-values/airflow.yaml would not create the `nova-api`
# service user: Viewer's read permissions plus the `nova-service` role that lets Nova trigger and
# pause DAGs (platform#496), with the username and password of the airflow-nova-api Secret, and
# with its password reset to the Secret's value when the user already exists (platform#476).
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
grep -qF -e 'sm.add_role("stardelt-member")' "$file" || fail "createUserJob must create the role stardelt-member"
[ "$(printf '%s\n' "$block" | grep -cF -e 'sm.find_role("Viewer").permissions')" -eq 2 ] \
  || fail "stardelt-member and nova-service must be built from the permissions of Viewer"
[ "$(printf '%s\n' "$block" | grep -cF -e 'GLOBAL = {("can_read", "DAGs"), ("can_read", "DAG Runs")}')" -eq 1 ] \
  || fail "stardelt-member must not hold the global read on DAGs and DAG Runs"

# platform#496: Nova's service identity may trigger (can_create on DAG Runs) and pause
# (can_edit on DAGs); Nova's own routes check the caller's owner group first.
grep -qF -e 'sm.find_role("nova-service")' "$file" || fail "createUserJob must create the role nova-service"
grep -qF -e 'NOVA_WRITE = (("can_edit", "DAGs"), ("can_create", "DAG Runs"))' "$file" \
  || fail "nova-service must grant can_edit on DAGs and can_create on DAG Runs"
grep -qF -e 'sm.find_user(username=os.environ["AIRFLOW_NOVA_API_USERNAME"])' "$file" \
  || fail "nova-service must be assigned to the nova-api user"
grep -qF -e 'sm.update_user(user)' "$file" || fail "the nova-service assignment must be persisted"

# platform#477 S1b checks
[ "$(grep -cF -e 'AUTH_ROLES_MAPPING = {_admin_group: ["Admin"]}' "$file")" -eq 0 ] \
  || fail "webserver_config.py must map roles dynamically (not only the admin group)"
grep -qF -e '_AuthRolesMapping' "$file" || fail "webserver_config.py must use a dict subclass for lazy role mapping"
grep -qF -e 'stardelt-group-' "$file" || fail "webserver_config.py must map stardelt-group- roles"
grep -qF -e '"stardelt-member"' "$file" || fail "group mapping must grant stardelt-member"
grep -qF -e 'get_all_roles' "$file" || fail "mapping must query roles via get_all_roles()"

manifest=manifests/airflow-group-roles.yaml
[ -f "$manifest" ] || fail "missing $manifest"
grep -qF -e 'name: airflow-group-roles' "$manifest" || fail "manifest must define ServiceAccount airflow-group-roles"
grep -qF -e 'name: airflow-pipeline-reader' "$manifest" || fail "manifest must bind to existing Role airflow-pipeline-reader"
# digest must match helm-values/airflow.yaml
hv_digest="$(grep -A2 'repository: ghcr.io/stardelt/airflow' "$file" | grep 'digest:' | awk '{print $2}')"
[ -n "$hv_digest" ] || fail "could not read airflow image digest from helm-values"
grep -qF -e "airflow:demo@$hv_digest" "$manifest" || grep -qF -e "$hv_digest" "$manifest" || fail "manifest Airflow image digest must match helm-values/airflow.yaml digest"
grep -qF -e 'schedule: "*/5 * * * *"' "$manifest" || fail "CronJob must run every 5 minutes"
grep -qF -e 'concurrencyPolicy: Forbid' "$manifest" || fail "CronJob must have concurrencyPolicy: Forbid"
grep -qF -e 'successfulJobsHistoryLimit: 1' "$manifest" || fail "CronJob must have successfulJobsHistoryLimit: 1"
grep -qF -e 'failedJobsHistoryLimit: 3' "$manifest" || fail "CronJob must have failedJobsHistoryLimit: 3"
grep -qF -e 'backoffLimit: 1' "$manifest" || fail "CronJob must have backoffLimit: 1"
grep -qF -e 'restartPolicy: Never' "$manifest" || fail "CronJob must have restartPolicy: Never"
grep -qF -e 'serviceAccountName: airflow-group-roles' "$manifest" || fail "CronJob must use ServiceAccount airflow-group-roles"
grep -qF -e 'airflow-metadata' "$manifest" || fail "manifest must wire AIRFLOW__DATABASE__SQL_ALCHEMY_CONN from airflow-metadata/connection"
grep -qF -e 'connection' "$manifest" || fail "manifest must wire AIRFLOW__DATABASE__SQL_ALCHEMY_CONN from airflow-metadata/connection"
grep -qF -e 'airflow-webserver-key' "$manifest" || fail "manifest must wire AIRFLOW__API__SECRET_KEY"
grep -qF -e 'api-secret-key' "$manifest" || fail "manifest must wire AIRFLOW__API__SECRET_KEY"
grep -qF -e 'airflow-jwt-secret' "$manifest" || fail "manifest must wire AIRFLOW__API_AUTH__JWT_SECRET"
grep -qF -e 'jwt-secret' "$manifest" || fail "manifest must wire AIRFLOW__API_AUTH__JWT_SECRET"
grep -qF -e 'airflow-fernet-key' "$manifest" || fail "manifest must wire AIRFLOW__CORE__FERNET_KEY"
grep -qF -e 'fernet-key' "$manifest" || fail "manifest must wire AIRFLOW__CORE__FERNET_KEY"

echo "check-airflow-users: OK"
