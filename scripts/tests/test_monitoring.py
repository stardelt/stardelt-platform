"""The chart's monitoring objects: four ServiceMonitors, four PodMonitors, one PrometheusRule.

`monitoring.enabled` turns on one ServiceMonitor per SeaweedFS role that exposes
Prometheus metrics on a `metrics` Service port — master, filer, volume and s3 —
one PodMonitor per CloudNative-PG cluster (the instance manager's port is on the
pod, not on a Service), and one PrometheusRule with the starter alerts. The
switch is off by default: without the `monitoring.coreos.com/v1` CRDs
`helm install` fails, and a stock cluster has no Prometheus Operator. The
operator path (stardelt-operator) renders the same objects from
PlatformInstance.spec.monitoring, so names, selectors and endpoints are asserted
here: the two install paths must agree.

Needs Helm and the sub-charts fetched into `chart/charts/*.tgz` (gitignored;
`helm dependency update chart`). The `lint` job runs `unittest discover` as well
and does not fetch them, so the module skips itself there; the `helm-lint` job
runs it after its dependency step and has both.
"""

import pathlib
import shutil
import subprocess
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# The `lint` job runs `unittest discover` without Helm; the `helm-lint` job has it.
HELM = shutil.which("helm")

COMPONENTS = ["master", "filer", "volume", "s3"]
EXPECTED_NAMES = {f"seaweedfs-{component}" for component in COMPONENTS}
CLUSTERS = ["lakekeeper-pg", "openfga-pg", "keycloak-pg", "nova-pg"]
EXPECTED_POD_MONITORS = {f"cnpg-{cluster}" for cluster in CLUSTERS}
ENDPOINT = {"port": "metrics", "path": "/metrics", "interval": "30s"}
ALERTS = {
    "StardeltMetricsTargetDown",
    "StardeltOperatorNoLeader",
    "StardeltOperatorReconcileErrors",
    "StardeltSeaweedFSMasterNotLeader",
    "StardeltCnpgCollectorDown",
    "StardeltCnpgClientsWaiting",
}


def missing_subcharts():
    """Sub-chart names `chart/Chart.yaml` declares but `chart/charts/` lacks."""
    with open(REPO_ROOT / "chart" / "Chart.yaml", encoding="utf-8") as handle:
        deps = yaml.safe_load(handle).get("dependencies") or []
    present = [p.name for p in (REPO_ROOT / "chart" / "charts").glob("*.tgz")]
    return [d["name"] for d in deps
            if not any(p.startswith(d["name"] + "-") for p in present)]


def render(*settings):
    """Render the umbrella chart and return (completed process, documents)."""
    cmd = [HELM, "template", "stardelt", "chart", "-n", "stardelt", *settings]
    out = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)
    return out, [d for d in yaml.safe_load_all(out.stdout) if d]


def monitors(docs):
    return [d for d in docs if d.get("kind") == "ServiceMonitor"]


def pod_monitors(docs):
    return [d for d in docs if d.get("kind") == "PodMonitor"]


def rules(docs):
    return [d for d in docs if d.get("kind") == "PrometheusRule"]


class MonitoringChartTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if HELM is None:
            raise unittest.SkipTest("helm is not on PATH")
        missing = missing_subcharts()
        if missing:
            print(f"skip: chart/charts/ lacks {', '.join(missing)} "
                  "(run `helm dependency update chart`)")
            raise unittest.SkipTest(f"chart dependencies not fetched: {', '.join(missing)}")

    def test_the_switch_is_off_by_default(self):
        out, docs = render()
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        self.assertEqual(monitors(docs), [],
                         "monitoring.enabled is false by default, so no ServiceMonitor may render")
        self.assertEqual(pod_monitors(docs), [],
                         "monitoring.enabled is false by default, so no PodMonitor may render")
        self.assertEqual(rules(docs), [],
                         "monitoring.enabled is false by default, so no PrometheusRule may render")

    def test_the_switch_renders_the_four_object_store_monitors(self):
        out, docs = render("--set", "monitoring.enabled=true")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = monitors(docs)
        names = {d["metadata"]["name"] for d in rendered}
        self.assertEqual(names, EXPECTED_NAMES, f"rendered monitors: {sorted(names)}")
        for doc in rendered:
            name = doc["metadata"]["name"]
            component = name.removeprefix("seaweedfs-")
            self.assertEqual(doc["metadata"]["namespace"], "stardelt",
                             f"ServiceMonitor {name} is not in the release namespace")
            self.assertEqual(doc["metadata"]["labels"],
                             {"app.kubernetes.io/part-of": "stardelt"},
                             f"ServiceMonitor {name} carries unexpected labels")
            spec = doc["spec"]
            self.assertEqual(spec["selector"]["matchLabels"],
                             {"app.kubernetes.io/name": "seaweedfs",
                              "app.kubernetes.io/component": component},
                             f"ServiceMonitor {name} selects the wrong Services")
            self.assertEqual(spec["endpoints"], [ENDPOINT],
                             f"ServiceMonitor {name} scrapes the wrong endpoint")
            self.assertNotIn("namespaceSelector", spec,
                             f"ServiceMonitor {name} must stay in the release namespace")

    def test_the_switch_renders_the_four_cnpg_pod_monitors(self):
        out, docs = render("--set", "monitoring.enabled=true")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = pod_monitors(docs)
        names = {d["metadata"]["name"] for d in rendered}
        self.assertEqual(names, EXPECTED_POD_MONITORS, f"rendered PodMonitors: {sorted(names)}")
        for doc in rendered:
            name = doc["metadata"]["name"]
            cluster = name.removeprefix("cnpg-")
            self.assertEqual(doc["metadata"]["namespace"], "stardelt",
                             f"PodMonitor {name} is not in the release namespace")
            spec = doc["spec"]
            self.assertEqual(spec["selector"]["matchLabels"],
                             {"cnpg.io/cluster": cluster},
                             f"PodMonitor {name} selects the wrong pods")
            self.assertEqual(spec["podMetricsEndpoints"], [ENDPOINT],
                             f"PodMonitor {name} scrapes the wrong endpoint")
            self.assertNotIn("namespaceSelector", spec,
                             f"PodMonitor {name} must stay in the release namespace")

    def test_the_switch_renders_the_starter_alerts(self):
        out, docs = render("--set", "monitoring.enabled=true")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = rules(docs)
        self.assertEqual(len(rendered), 1, "expected one PrometheusRule")
        rule = rendered[0]
        self.assertEqual(rule["metadata"]["name"], "stardelt-alerts")
        self.assertEqual(rule["metadata"]["namespace"], "stardelt")
        groups = rule["spec"]["groups"]
        self.assertEqual([group["name"] for group in groups], ["stardelt"])
        alerts = {alert["alert"] for group in groups for alert in group["rules"]}
        self.assertEqual(alerts, ALERTS, f"rendered alerts: {sorted(alerts)}")
        for group in groups:
            for alert in group["rules"]:
                self.assertIn('namespace="stardelt"', alert["expr"],
                              f"{alert['alert']} does not name its namespace")
                self.assertIn("for", alert, f"{alert['alert']} has no duration")
                self.assertEqual(alert["annotations"]["runbook_url"],
                                 "https://stardelt.io/docs/operations/monitoring/")

    def test_the_labels_reach_every_object(self):
        out, docs = render("--set", "monitoring.enabled=true",
                           "--set", "monitoring.labels.release=kube-prometheus-stack")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = monitors(docs) + pod_monitors(docs) + rules(docs)
        self.assertEqual(len(rendered), 9,
                         "expected four ServiceMonitors, four PodMonitors and one rule")
        for doc in rendered:
            name = doc["metadata"]["name"]
            self.assertEqual(doc["metadata"]["labels"].get("release"), "kube-prometheus-stack",
                             f"{name} does not carry the customer's label")
            self.assertEqual(doc["metadata"]["labels"].get("app.kubernetes.io/part-of"), "stardelt",
                             f"{name} lost app.kubernetes.io/part-of")


if __name__ == "__main__":
    unittest.main()
