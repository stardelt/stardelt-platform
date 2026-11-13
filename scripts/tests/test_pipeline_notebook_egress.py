"""Egress from a scheduled notebook pod: Trino, the S3 gateway, DNS and the public internet.

A `notebook` task runs a pod labelled `app.kubernetes.io/name: pipeline-notebook` that
executes a person's code. Without an egress policy it reaches every address the network
allows, including the platform's databases (platform#1100, measured 2026-11-13: nova-pg
and openfga-pg answered). The policy allows exactly the governed query path (Trino 8443),
the object store's S3 gateway (8333) for the presigned notebook GET/PUT, DNS, and the
public internet — no other private address.

The same object exists three times: `manifests/pipeline-notebook-egress.yaml` (the
Makefile path), this chart's template, and the operator (stardelt-operator#649). They must
agree, so both install-path copies are asserted here.

Needs Helm and the sub-charts fetched into `chart/charts/*.tgz` (gitignored;
`helm dependency update chart`). The `lint` job runs `unittest discover` as well and does
not fetch them, so the module skips itself there; the `helm-lint` job has both.
"""

import pathlib
import shutil
import subprocess
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# The `lint` job runs `unittest discover` without Helm; the `helm-lint` job has it.
HELM = shutil.which("helm")

MANIFEST = REPO_ROOT / "manifests" / "pipeline-notebook-egress.yaml"
NAME = "pipeline-notebook-egress"
SELECTOR = {"app.kubernetes.io/name": "pipeline-notebook"}
PUBLIC_EXCEPT = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.169.254/32"]


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


def policies(docs):
    return [d for d in docs if d.get("kind") == "NetworkPolicy"]


def notebook_policies(docs):
    return [d for d in policies(docs) if d.get("metadata", {}).get("name") == NAME]


def to_peers(rule):
    return rule.get("to") or []


def port_tuple(port):
    return (port.get("protocol"), port.get("port"))


class ManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(MANIFEST, encoding="utf-8") as handle:
            cls.documents = [d for d in yaml.safe_load_all(handle) if d]

    def test_exactly_one_policy_with_the_expected_selector(self):
        rendered = policies(self.documents)
        self.assertEqual(len(rendered), 1, f"expected one NetworkPolicy, got {len(rendered)}")
        policy = rendered[0]
        self.assertEqual(policy["metadata"]["name"], NAME)
        self.assertEqual(policy["metadata"]["namespace"], "stardelt")
        self.assertEqual(policy["spec"]["podSelector"]["matchLabels"], SELECTOR)
        self.assertEqual(policy["spec"]["policyTypes"], ["Egress"])

    def test_four_rules_in_order(self):
        rules = policies(self.documents)[0]["spec"]["egress"]
        self.assertEqual(len(rules), 4, f"expected four egress rules, got {len(rules)}")

        dns = rules[0]
        peers = to_peers(dns)
        self.assertTrue(
            any(p.get("namespaceSelector", {}).get("matchLabels", {})
                .get("kubernetes.io/metadata.name") == "kube-system" for p in peers),
            f"the DNS rule must reach the kube-system resolver, peers: {peers}")
        ports = {port_tuple(p) for p in dns["ports"]}
        self.assertEqual(ports, {("UDP", 53), ("TCP", 53)},
                         f"DNS is 53 UDP and TCP, got {ports}")

        trino = rules[1]
        self.assertEqual(to_peers(trino), [{"podSelector": {"matchLabels": {
            "app.kubernetes.io/name": "trino",
            "app.kubernetes.io/component": "coordinator"}}}])
        self.assertEqual([port_tuple(p) for p in trino["ports"]], [("TCP", 8443)])

        s3 = rules[2]
        self.assertEqual(to_peers(s3), [{"podSelector": {"matchLabels": {
            "app.kubernetes.io/name": "seaweedfs",
            "app.kubernetes.io/component": "s3"}}}])
        self.assertEqual([port_tuple(p) for p in s3["ports"]], [("TCP", 8333)])

        public = rules[3]
        self.assertEqual(len(to_peers(public)), 1)
        block = to_peers(public)[0]["ipBlock"]
        self.assertEqual(block["cidr"], "0.0.0.0/0")
        self.assertEqual(block["except"], PUBLIC_EXCEPT)

    def test_no_rule_opens_every_namespace(self):
        for index, rule in enumerate(policies(self.documents)[0]["spec"]["egress"]):
            for peer in to_peers(rule):
                self.assertNotEqual(
                    peer.get("namespaceSelector"), {},
                    f"egress rule {index} has an empty namespaceSelector, which selects "
                    f"every namespace: {peer}")

    def test_every_peer_is_named_narrowly(self):
        rules = policies(self.documents)[0]["spec"]["egress"]
        private = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
        for index, peer in enumerate(to_peers(rules[0])):  # DNS
            if "ipBlock" in peer:
                self.assertIn(peer["ipBlock"]["cidr"], private, f"rule 0: {peer}")
            else:
                self.assertTrue(peer.get("namespaceSelector", {}).get("matchLabels"),
                                f"rule 0: an unnamed namespace selector: {peer}")
        for index in (1, 2):  # Trino and the S3 gateway
            for peer in to_peers(rules[index]):
                self.assertTrue(peer.get("podSelector", {}).get("matchLabels"),
                                f"rule {index}: an empty pod selector: {peer}")


class ChartTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if HELM is None:
            raise unittest.SkipTest("helm is not on PATH")
        missing = missing_subcharts()
        if missing:
            print(f"skip: chart/charts/ lacks {', '.join(missing)} "
                  "(run `helm dependency update chart`)")
            raise unittest.SkipTest(f"chart dependencies not fetched: {', '.join(missing)}")

    def test_the_chart_renders_the_same_object_with_airflow(self):
        out, docs = render("--set", "airflow.enabled=true")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        rendered = notebook_policies(docs)
        self.assertEqual(len(rendered), 1, f"expected one {NAME}, got {len(rendered)}")
        policy = rendered[0]
        self.assertEqual(policy["metadata"]["namespace"], "stardelt")
        self.assertEqual(policy["spec"]["podSelector"]["matchLabels"], SELECTOR)
        self.assertEqual(policy["spec"]["policyTypes"], ["Egress"])

        with open(MANIFEST, encoding="utf-8") as handle:
            manifest = [d for d in yaml.safe_load_all(handle) if d]
        self.assertEqual(policy["spec"]["egress"],
                         policies(manifest)[0]["spec"]["egress"],
                         "the chart twin and the manifest drifted apart")

    def test_no_airflow_means_no_policy(self):
        out, docs = render("--set", "airflow.enabled=false")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        self.assertEqual(notebook_policies(docs), [],
                         f"{NAME} must render only with airflow.enabled")


if __name__ == "__main__":
    unittest.main()
