#!/usr/bin/env bash
# Discover owner groups from Catalogs, Pipelines, ServicePrincipals and reconcile OpenBao policies.
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"
POD="${POD:-openbao-0}"
CONTAINER="${CONTAINER:-openbao}"
INIT_SECRET=openbao-init

for tool in kubectl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "openbao-group-policies: $tool not found" >&2; exit 1; }
done

# Exit cleanly if store not installed
if ! kubectl -n "$NAMESPACE" get pod "$POD" >/dev/null 2>&1; then
  echo "openbao-group-policies: openbao pod not found, exiting cleanly"
  exit 0
fi
if ! kubectl -n "$NAMESPACE" get secret "$INIT_SECRET" >/dev/null 2>&1; then
  echo "openbao-group-policies: $INIT_SECRET not found, exiting cleanly"
  exit 0
fi

# Discover groups
groups_raw=$(python3 -c "
import json,subprocess,sys
ns='${NAMESPACE}'
result=set()
# Catalogs
try:
  out=subprocess.check_output(['kubectl','-n',ns,'get','catalogs','-o','json'],stderr=subprocess.DEVNULL)
  data=json.loads(out)
  for item in data.get('items',[]):
    spec=item.get('spec',{})
    grants=spec.get('grants',[]) or []
    for g in grants:
      owner=g.get('owner')
      if owner:
        result.add(owner)
except Exception:
  pass
# Pipelines
try:
  out=subprocess.check_output(['kubectl','-n',ns,'get','pipelines','-o','json'],stderr=subprocess.DEVNULL)
  data=json.loads(out)
  for item in data.get('items',[]):
    spec=item.get('spec',{})
    og=spec.get('ownerGroup')
    if og:
      result.add(og)
except Exception:
  pass
# ServicePrincipals
try:
  out=subprocess.check_output(['kubectl','-n',ns,'get','serviceprincipals','-o','json'],stderr=subprocess.DEVNULL)
  data=json.loads(out)
  for item in data.get('items',[]):
    spec=item.get('spec',{})
    og=spec.get('ownerGroup')
    if og:
      result.add(og)
except Exception:
  pass
# Exclude
exclude=set(['stardelt-users','stardelt-admins'])
for r in sorted(list(result-exclude)):
  print(r)
")

groups=()
while IFS= read -r line; do
  [ -n "$line" ] && groups+=("$line")
done <<< "$groups_raw"

if [ ${#groups[@]} -eq 0 ]; then
  echo "openbao-group-policies: no owner groups discovered"
  # Still run connections script with empty to ensure shared policies/admin wiring? The script accepts empty groups
  NAMESPACE="$NAMESPACE" OWNER_GROUPS="" bash /opt/scripts/openbao-connections.sh || true
  exit 0
fi

echo "openbao-group-policies: discovered groups: ${groups[*]}"
NAMESPACE="$NAMESPACE" OWNER_GROUPS="${groups[*]}" bash /opt/scripts/openbao-connections.sh
