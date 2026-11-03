#!/usr/bin/env bash
# Fail when the Superset per-group role changes are missing or inconsistent.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

file=helm-values/superset.yaml
analyst=scripts/superset-analyst-role.py
groups=scripts/superset-group-roles.py
manifest=manifests/superset-group-roles.yaml

fail() {
  echo "check-superset-roles: $1" >&2
  exit 1
}

[ -f "$analyst" ] || fail "missing $analyst"
grep -qF -e 'catalog_from_uri' "$analyst" || fail "analyst script must filter to shared catalog"
grep -qF -e '"shared"' "$analyst" || fail "analyst script must match only shared"
grep -qF -e 'no Trino database for catalog shared' "$analyst" || fail "analyst script must error when shared missing"

[ -f "$groups" ] || fail "missing $groups"
grep -qF -e 'stardelt-group-' "$groups" || fail "group roles script must create stardelt-group- roles"
grep -qF -e 'catalogs.stardelt.io' "$groups" || fail "group roles script must list catalogs"
grep -qF -e 'dashboard_roles' "$groups" || fail "group roles script must converge dashboard roles"
grep -qF -e 'published' "$groups" || fail "only published dashboards are converged"

grep -qF -e '_AuthRolesMapping' "$file" || fail "superset values must use _AuthRolesMapping"
grep -qF -e 'stardelt-group-' "$file" || fail "mapping must add group roles"

grep -qF -e 'superset-group-roles.py' "$file" || fail "init job must run superset-group-roles.py"
grep -qF -e 'serviceAccountName: superset' "$file" || fail "superset values must run the pods as the superset ServiceAccount"

[ -f "$manifest" ] || fail "missing $manifest"
grep -qF -e 'name: superset-group-roles' "$manifest" || fail "manifest must define superset-group-roles"
if ! (grep -qF -e 'catalogs' "$manifest" && grep -qF -e 'get' "$manifest" && grep -qF -e 'list' "$manifest"); then
  fail "manifest must grant get/list on catalogs"
fi
grep -qF -e 'CronJob' "$manifest" || fail "manifest must define a CronJob"
grep -qF -e 'concurrencyPolicy: Forbid' "$manifest" || fail "cronjob must have concurrencyPolicy: Forbid"
grep -qF -e 'serviceAccountName: superset' "$manifest" || fail "the Job must run as the superset ServiceAccount"
grep -qF -e 'name: ghcr-creds' "$manifest" || fail "the Job must use the image pull secret"
grep -qF -e 'name: superset-env' "$manifest" || fail "the Job must read the chart's superset-env Secret"
grep -qF -e 'name: superset-secret-key' "$manifest" || fail "the Job must set SUPERSET_SECRET_KEY"
grep -qF -e 'secretName: superset-config' "$manifest" || fail "the Job must mount the Superset config Secret"
grep -qF -e '/app/configs/superset-group-roles.py' "$manifest" || fail "the Job must run the chart-mounted script"
if grep -qF -e 'placeholder' "$manifest"; then fail "the manifest still carries the placeholder ConfigMap"; fi

hv_digest="$(grep 'tag:' "$file" | grep -o 'sha256:[0-9a-f]\{64\}' | head -1)"
[ -n "$hv_digest" ] || fail "could not find superset image digest in values"
if grep -q 'superset-group-roles' "$manifest"; then
  grep -q "$hv_digest" "$manifest" || fail "manifest image digest must match helm-values/superset.yaml"
fi

echo "check-superset-roles: OK"
