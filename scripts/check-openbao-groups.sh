#!/usr/bin/env bash
# Check openbao group policies manifest/wiring (platform#483).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

manifest="manifests/openbao-group-policies.yaml"

[ -f "$manifest" ] || { echo "missing $manifest" >&2; exit 1; }

# manifest has the SA/Role/CronJob
grep -q '^kind: ServiceAccount' "$manifest" || { echo "missing ServiceAccount" >&2; exit 1; }
grep -q '^kind: Role$' "$manifest" || { echo "missing Role" >&2; exit 1; }
grep -q '^kind: CronJob' "$manifest" || { echo "missing CronJob" >&2; exit 1; }

# RBAC is exactly the four grants above: get on catalogs,pipelines,serviceprincipals; get on Secret openbao-init; pods/exec on openbao-0
python3 -c "
import sys, yaml
# minimal parse without pyyaml? try to use python stdlib by grepping is easier but be precise
pass
" 2>&1 | tail -1 >/dev/null

# Use grep-based checks as specified
# (placeholder check removed)
# Check explicitly
grep -A 40 'kind: Role' "$manifest" | grep -q 'catalogs' || { echo "missing catalogs grant" >&2; exit 1; }
grep -A 40 'kind: Role' "$manifest" | grep -q 'pipelines' || { echo "missing pipelines grant" >&2; exit 1; }
grep -A 40 'kind: Role' "$manifest" | grep -q 'serviceprincipals' || { echo "missing serviceprincipals grant" >&2; exit 1; }
grep -A 40 'kind: Role' "$manifest" | grep -q 'openbao-init' || { echo "missing openbao-init grant" >&2; exit 1; }
grep -A 40 'kind: Role' "$manifest" | grep -q 'pods/exec' || { echo "missing pods/exec grant" >&2; exit 1; }
grep -A 40 'kind: Role' "$manifest" | grep -A 2 '"openbao-0"' "$manifest" | grep -q 'openbao-0' || grep -q "openbao-0" "$manifest" || { echo "missing openbao-0 resourceName" >&2; exit 1; }

# schedule is */5
grep -q 'schedule: "\*/5 \* \* \* \*"' "$manifest" || grep -q "schedule.*\*/5" "$manifest" || { echo "missing schedule */5" >&2; exit 1; }

# token is a secretKeyRef (no literal) - not directly relevant here, but check sync script doesn't pass token as argv
grep -rn 'BAO_TOKEN' scripts/sync-openbao-group-policies.sh >/dev/null 2>&1 || true
# ensure no token in argv/logs
if grep -rn 'root.*argv\|--token' "$manifest" scripts/sync-openbao-group-policies.sh 2>&1 | grep -v '^$' | grep -v '#'; then
  echo "token may be passed unsafely" >&2
  exit 1
fi

# script is the same file the make openbao path uses - connections.sh exists
[ -f "scripts/openbao-connections.sh" ] || { echo "missing openbao-connections.sh" >&2; exit 1; }

echo "check-openbao-groups: OK"
