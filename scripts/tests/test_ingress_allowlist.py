"""The source-range allow-list reaches every public Ingress (platform#427).

`ingress.allowedCidrs` renders `nginx.ingress.kubernetes.io/whitelist-source-range`
on every Ingress the umbrella chart renders, refuses more than 64 entries and
refuses an entry that is not a CIDR. That is the administrator's one list; a
template that forgets the annotation, or a renamed values key, would leave one
endpoint open, and on a real install the administrator would learn it only by
being locked out. So the check is a render, not a running cluster.

Needs Helm and the sub-charts fetched into `chart/charts/*.tgz` (gitignored;
`helm dependency update chart`). The `lint` job runs `unittest discover` as
well and does not fetch them, so the module skips itself there; the
`helm-lint` job runs it after its dependency step and has both.
"""

import pathlib
import shutil
import subprocess
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# The `lint` job runs `unittest discover` without Helm; the `helm-lint` job has it.
HELM = shutil.which("helm")

ANNOTATION = "nginx.ingress.kubernetes.io/whitelist-source-range"
CIDRS = ["203.0.113.0/24", "198.51.100.0/24"]
CIDR_SET = "{" + ",".join(CIDRS) + "}"


def missing_subcharts():
    """Sub-chart names `chart/Chart.yaml` declares but `chart/charts/` lacks."""
    with open(REPO_ROOT / "chart" / "Chart.yaml", encoding="utf-8") as handle:
        deps = yaml.safe_load(handle).get("dependencies") or []
    present = [p.name for p in (REPO_ROOT / "chart" / "charts").glob("*.tgz")]
    return [d["name"] for d in deps
            if not any(p.startswith(d["name"] + "-") for p in present)]



def render(*settings):
    """Render the umbrella chart and return (completed process, documents)."""
    cmd = [HELM, "template", "stardelt", "chart", "-n", "stardelt",
           "--set", "ingress.enabled=true",
           "--set", "platform.baseDomain=example.com",
           "--set", "identity.mode=platform",
           "--set", "ingress.exposeUnauthenticated={trino,superset,airflow,jupyterhub}",
           *settings]
    out = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)
    return out, [d for d in yaml.safe_load_all(out.stdout) if d]


def ingresses(docs):
    return [d for d in docs if d.get("kind") == "Ingress"]


def annotation_of(doc):
    return (doc.get("metadata", {}).get("annotations") or {}).get(ANNOTATION)


class IngressAllowListTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if HELM is None:
            raise unittest.SkipTest("helm is not on PATH")
        missing = missing_subcharts()
        if missing:
            print(f"skip: chart/charts/ lacks {', '.join(missing)} "
                  "(run `helm dependency update chart`)")
            raise unittest.SkipTest(f"chart dependencies not fetched: {', '.join(missing)}")

    def test_every_public_ingress_carries_the_list(self):
        out, docs = render("--set", f"ingress.allowedCidrs={CIDR_SET}")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = ingresses(docs)
        names = {d["metadata"]["name"] for d in rendered}
        self.assertEqual(names, {"nova", "trino", "keycloak"},
                         f"the default values render these Ingresses: {sorted(names)}")
        expected = ",".join(CIDRS)
        for doc in rendered:
            name = doc["metadata"]["name"]
            self.assertEqual(
                annotation_of(doc), expected,
                f"Ingress {name} ({doc['spec'].get('rules', [{}])[0].get('host')}) does not "
                f"carry {ANNOTATION}={expected!r}")

    def test_an_empty_list_renders_no_annotation(self):
        out, docs = render()
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        for doc in ingresses(docs):
            name = doc["metadata"]["name"]
            self.assertNotIn(
                ANNOTATION, (doc.get("metadata", {}).get("annotations") or {}),
                f"no allowedCidrs must mean no annotation, but Ingress {name} has one")

    def test_a_heavy_component_is_covered_too(self):
        out, docs = render("--set", "superset.enabled=true",
                           "--set", "ingress.exposeUnauthenticated={trino,superset}",
                           "--set", f"ingress.allowedCidrs={CIDR_SET}")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = ingresses(docs)
        names = {d["metadata"]["name"] for d in rendered}
        self.assertEqual(len(rendered), 4,
                         f"expected nova, trino, superset and keycloak; got {sorted(names)}")
        superset = [d for d in rendered if d["metadata"]["name"] == "superset"]
        self.assertEqual(len(superset), 1, f"no superset Ingress in {sorted(names)}")
        self.assertEqual(
            annotation_of(superset[0]), ",".join(CIDRS),
            "the superset Ingress does not carry the allow-list")

    def test_more_than_64_entries_fail_the_render(self):
        entries = "{" + ",".join(f"10.0.{i}.0/24" for i in range(65)) + "}"
        out, _ = render("--set", f"ingress.allowedCidrs={entries}")
        self.assertNotEqual(out.returncode, 0, "65 entries must fail the render")
        self.assertIn("ingress.allowedCidrs: at most 64 entries", out.stdout + out.stderr)

    def test_a_non_cidr_fails_the_render(self):
        out, _ = render("--set", "ingress.allowedCidrs={example.com}")
        self.assertNotEqual(out.returncode, 0, "a non-CIDR entry must fail the render")
        self.assertIn("is not a CIDR such as 203.0.113.0/24", out.stdout + out.stderr)


if __name__ == "__main__":
    unittest.main()
