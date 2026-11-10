#!/usr/bin/env python3
"""Check the notebook configuration agrees with itself (platform#818, #839, #841).

    python3 scripts/check-hub-config.py        # PASS, exit 0; any ✗ means exit 1

Reads the two values files, the umbrella chart and Nova's manifest. Does not need a
cluster or `helm`: the point is to fail before a rollout, in CI, when the four copies
of one number drift apart. PyYAML is already required by yamllint in the Lint job.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHART = yaml.safe_load((ROOT / "chart/values.yaml").read_text())
HELM = yaml.safe_load((ROOT / "helm-values/jupyterhub.yaml").read_text())
NOVA = next(
    d
    for d in yaml.safe_load_all((ROOT / "manifests/nova-deployment.yaml").read_text())
    if d and d.get("kind") == "Deployment"
)

failures = []


def check(label, ok, detail=""):
    print(("✓ " if ok else "✗ ") + label + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(label)


chart_hub = (CHART.get("jupyterhub") or {}).get("hub") or {}
helm_hub = HELM.get("hub") or {}

check(
    "hub roles: helm-values/jupyterhub.yaml and chart/values.yaml agree",
    helm_hub.get("loadRoles") == chart_hub.get("loadRoles")
    and helm_hub.get("services") == chart_hub.get("services"),
    f"loadRoles={sorted(helm_hub.get('loadRoles') or {})}",
)

timeouts = {
    "helm-values cull.timeout": HELM.get("cull", {}).get("timeout"),
    "chart jupyterhub.cull.timeout": (CHART.get("jupyterhub") or {}).get("cull", {}).get("timeout"),
    "chart nova.workspace.idleSeconds": (CHART.get("nova") or {}).get("workspace", {}).get("idleSeconds"),
}
env = ((NOVA.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers") or []
nova_env = {e["name"]: e.get("value") for c in env for e in (c.get("env") or [])}
timeouts["manifests NOVA_WORKSPACE_IDLE_SECONDS"] = nova_env.get("NOVA_WORKSPACE_IDLE_SECONDS")
values = {str(v) for v in timeouts.values()}
check(
    "idle timeout: the culler, the chart and Nova's countdown are one number",
    len(values) == 1 and None not in timeouts.values(),
    ", ".join(f"{k}={v}" for k, v in timeouts.items()),
)

token = next(
    (e for c in env for e in (c.get("env") or []) if e["name"] == "NOVA_JUPYTERHUB_API_TOKEN"),
    {},
)
source = ((token.get("valueFrom") or {}).get("secretKeyRef")) or {}
check(
    "nova hub env: the API URL and the `hub` service token are mounted",
    nova_env.get("NOVA_JUPYTERHUB_API_URL") == "http://hub:8081/hub/api"
    and source.get("name") == "hub"
    and source.get("key") == "hub.services.nova.apiToken",
    f"url={nova_env.get('NOVA_JUPYTERHUB_API_URL')} secret={source.get('name')}/{source.get('key')}",
)

hook = str((helm_hub.get("extraConfig") or {}).get("26-spark-labels") or "")
check(
    "notebook pod labels: 26-spark-labels uses the V1Pod object API (#841)",
    "pod.metadata.labels" in hook and "setdefault(" not in hook,
    "found setdefault()" if "setdefault(" in hook else "",
)

print("\nPASS" if not failures else f"\nFAIL ({len(failures)} check(s))")
sys.exit(0 if not failures else 1)
