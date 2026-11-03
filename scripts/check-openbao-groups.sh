#!/usr/bin/env bash
# Check the OpenBao group-policy sync manifest and wiring (platform#483).
#
# The Job runs `sync.sh`, which calls `kubectl`, `python3` and `base64`; the image must carry all
# three. It reads the group from each Catalog grant's `group` field (not `owner`), which is the
# field the Catalog CRD uses.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

manifest="manifests/openbao-group-policies.yaml"
sync="scripts/sync-openbao-group-policies.sh"

[ -f "$manifest" ] || { echo "missing $manifest" >&2; exit 1; }
[ -f "$sync" ] || { echo "missing $sync" >&2; exit 1; }

# The objects and the wiring.
grep -q '^kind: ServiceAccount' "$manifest" || { echo "missing ServiceAccount" >&2; exit 1; }
grep -q '^kind: Role$' "$manifest" || { echo "missing Role" >&2; exit 1; }
grep -q '^kind: CronJob' "$manifest" || { echo "missing CronJob" >&2; exit 1; }
grep -q 'name: openbao-group-policies-script' "$manifest" || { echo "CronJob must mount openbao-group-policies-script" >&2; exit 1; }
grep -q 'sync.sh' "$manifest" || { echo "CronJob must run sync.sh" >&2; exit 1; }

# RBAC: the three List kinds, the one Secret, and exec on the one pod.
role="$(sed -n '/^kind: Role$/,/^---$/p' "$manifest")"
for want in catalogs pipelines serviceprincipals openbao-init pods pods/exec openbao-0; do
  printf '%s' "$role" | grep -q "$want" || { echo "Role is missing $want" >&2; exit 1; }
done
printf '%s' "$role" | grep -q 'verbs: \["get", "list"\]' || { echo "Role must grant get/list on the group sources" >&2; exit 1; }
# `kubectl exec` reads the pod first; without this one read the writer cannot reach the store.
printf '%s' "$role" | grep -q 'resources: \["pods"\]' || { echo "Role must grant get on pod openbao-0 (kubectl exec reads it first)" >&2; exit 1; }

# Schedule and no parallel runs.
grep -q 'schedule: "\*/5 \* \* \* \*"' "$manifest" || { echo "missing schedule */5" >&2; exit 1; }
grep -q 'concurrencyPolicy: Forbid' "$manifest" || { echo "missing concurrencyPolicy: Forbid" >&2; exit 1; }

# The image carries the tools the script checks for. `alpine/k8s` is the tested one: kubectl,
# python3, base64 and bash (platform#483: the first image was the Airflow one, which has no kubectl).
grep -q 'image: alpine/k8s:' "$manifest" || { echo "the Job image must provide kubectl, python3 and base64 (alpine/k8s)" >&2; exit 1; }

# Discovery reads the Catalog grant field that exists. A regression to `owner` silently drops every
# catalog-only group; the unit test scripts/tests/test_openbao_group_discovery.py covers the same.
grep -q "g.get('group')" "$sync" || { echo "sync.sh must read the grant's group field" >&2; exit 1; }
if grep -q "g.get('owner')" "$sync"; then
  echo "sync.sh reads a grant's owner; the Catalog grant field is group" >&2
  exit 1
fi

# The token never reaches argv or a log line.
if grep -rn -- '--token\|root.*argv' "$manifest" "$sync" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#'; then
  echo "token may be passed unsafely" >&2
  exit 1
fi

# The writer the Job calls is the same file the manual path uses.
[ -f "scripts/openbao-connections.sh" ] || { echo "missing openbao-connections.sh" >&2; exit 1; }
grep -q 'openbao-connections.sh' "$sync" || { echo "sync.sh must call openbao-connections.sh" >&2; exit 1; }

echo "check-openbao-groups: OK"
