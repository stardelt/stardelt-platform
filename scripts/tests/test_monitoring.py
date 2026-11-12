"""The chart renders the object store's four ServiceMonitors (platform#1146).

`monitoring.enabled` turns on one ServiceMonitor per SeaweedFS role that exposes
Prometheus metrics on a `metrics` Service port — master, filer, volume and s3 —
so the customer's Prometheus Operator can select them. The switch is off by
default: without the `monitoring.coreos.com/v1` CRDs `helm install` fails, and a
stock cluster has no Prometheus Operator. The operator path (stardelt-operator)
renders the same four objects from PlatformInstance.spec.monitoring, so names,
selectors and endpoints are asserted here: the two install paths must agree.

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
ENDPOINT = {"port": "metrics", "path": "/metrics", "interval": "30s"}


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

    def test_the_labels_reach_every_object(self):
        out, docs = render("--set", "monitoring.enabled=true",
                           "--set", "monitoring.labels.release=kube-prometheus-stack")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = monitors(docs)
        self.assertEqual(len(rendered), 4, "expected four ServiceMonitors")
        for doc in rendered:
            name = doc["metadata"]["name"]
            self.assertEqual(doc["metadata"]["labels"].get("release"), "kube-prometheus-stack",
                             f"ServiceMonitor {name} does not carry the customer's label")
            self.assertEqual(doc["metadata"]["labels"].get("app.kubernetes.io/part-of"), "stardelt",
                             f"ServiceMonitor {name} lost app.kubernetes.io/part-of")


if __name__ == "__main__":
    unittest.main()
