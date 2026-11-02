#!/usr/bin/env bash
# Nova's Kubernetes permissions must be the same whether the platform is installed from
# the manifests (`make install`) or from the umbrella chart.
#
#   bash scripts/check-nova-rbac-parity.sh      # needs helm, python3 with PyYAML, and `helm dependency update chart`
#
# It collects every (apiGroup, resource, verb) that a Role grants to ServiceAccount `nova`
# through a RoleBinding, in manifests/nova-deployment.yaml and in the chart rendered with
# Airflow and the secret store switched on (the chart grants those Roles only then), and
# fails when the two sets differ. platform#473: the manifest could not patch Connections
# (the break-glass notice) and the chart could not list SqlWarehouses.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - <<'PY'
import subprocess
import sys

import yaml


def grants(documents):
    roles = {}
    for doc in documents:
        if doc and doc.get("kind") == "Role":
            roles[doc["metadata"]["name"]] = doc.get("rules", [])
    pairs = set()
    for doc in documents:
        if not doc or doc.get("kind") != "RoleBinding":
            continue
        bound = [s for s in doc.get("subjects", []) if s.get("kind") == "ServiceAccount" and s.get("name") == "nova"]
        if not bound:
            continue
        for rule in roles.get(doc["roleRef"]["name"], []):
            for group in rule.get("apiGroups", []):
                for resource in rule.get("resources", []):
                    for verb in rule.get("verbs", []):
                        pairs.add((group or "core", resource, verb))
    return pairs


with open("manifests/nova-deployment.yaml", encoding="utf-8") as handle:
    manifest = grants(list(yaml.safe_load_all(handle)))
rendered = subprocess.run(
    [
        "helm", "template", "stardelt", "chart", "-n", "stardelt",
        "--show-only", "templates/nova.yaml",
        "--set", "nova.airflow.url=http://airflow:8080",
        "--set", "nova.secretStore.url=http://store:8200",
    ],
    check=True, capture_output=True, text=True,
).stdout
chart = grants(list(yaml.safe_load_all(rendered)))

if not manifest or not chart:
    sys.exit("check-nova-rbac-parity: found no permission for ServiceAccount nova (manifest %d, chart %d)" % (len(manifest), len(chart)))
if manifest != chart:
    for label, pairs in (("only in manifests/nova-deployment.yaml", manifest - chart), ("only in the chart", chart - manifest)):
        for group, resource, verb in sorted(pairs):
            print("check-nova-rbac-parity: %s: %s %s.%s" % (label, verb, resource, group), file=sys.stderr)
    sys.exit(1)
print("check-nova-rbac-parity: OK (%d permissions, manifest and chart agree)" % len(manifest))
PY
