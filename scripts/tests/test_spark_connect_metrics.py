"""The Spark Connect driver serves its metrics on the UI port (#607, platform#1160).

Spark 4.1 answers `/metrics/executors/prometheus` on 4040 with plain samples and no
`# TYPE`/`# HELP` lines; the first sample is `spark_info`. The setting has to be on, the
Service has to publish the port, and the NetworkPolicy has to admit exactly the scraper —
without inheriting into the per-user SparkCluster servers, whose catalogue entry stays
dark (platform#1158).
"""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "manifests" / "spark.yaml"
CATALOGUE = ROOT / "chart" / "files" / "spark-runtimes.json"
GATE = ROOT / "scripts" / "check-spark-runtimes.sh"

SCRAPER = {"app.kubernetes.io/name": "prometheus"}
METRICS_PORT = 4040
CONNECT_PORT = 15002


def load_documents():
    with open(MANIFEST, encoding="utf-8") as handle:
        return [document for document in yaml.safe_load_all(handle) if document]


def one_of(documents, kind, name):
    found = [d for d in documents
             if d.get("kind") == kind and (d.get("metadata") or {}).get("name") == name]
    if len(found) != 1:
        raise AssertionError("spark.yaml: expected one %s/%s, found %d"
                             % (kind, name, len(found)))
    return found[0]


def spark_defaults(documents):
    """`spark-defaults.conf` as a {key: value} dict of its non-comment lines."""
    config_map = one_of(documents, "ConfigMap", "spark-connect-config")
    conf = (config_map.get("data") or {}).get("spark-defaults.conf") or ""
    defaults = {}
    for line in conf.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition(" ")
        defaults[key] = value.strip()
    return defaults


def ingress_rules(documents):
    return (one_of(documents, "NetworkPolicy", "spark-connect-ingress")
            .get("spec") or {}).get("ingress") or []


def rule_ports(rule):
    return [(port or {}).get("port") for port in rule.get("ports") or []]


class SparkConnectMetricsTest(unittest.TestCase):
    def setUp(self):
        self.documents = load_documents()

    def test_the_defaults_turn_the_ui_and_its_metrics_on(self):
        defaults = spark_defaults(self.documents)
        self.assertEqual("true", defaults.get("spark.ui.enabled"),
                         "spark.ui.enabled must be true or nothing listens on 4040")
        self.assertEqual("true", defaults.get("spark.ui.prometheus.enabled"),
                         "spark.ui.prometheus.enabled must be true or 4040 has no /metrics")

    def test_the_service_publishes_the_metrics_port(self):
        service = one_of(self.documents, "Service", "spark-connect")
        ports = service.get("spec", {}).get("ports") or []
        self.assertEqual(
            [{"name": "metrics", "port": METRICS_PORT,
              "targetPort": METRICS_PORT, "protocol": "TCP"}],
            [port for port in ports if port.get("name") == "metrics"],
            "Service/spark-connect needs exactly one named 'metrics' port on 4040")
        self.assertEqual(
            [{"name": "connect", "port": CONNECT_PORT,
              "targetPort": "connect", "protocol": "TCP"}],
            [port for port in ports if port.get("name") == "connect"],
            "the connect port 15002 needs exactly one entry")

    def test_the_scrape_rule_is_the_only_peer_on_4040(self):
        rules = [rule for rule in ingress_rules(self.documents)
                 if METRICS_PORT in rule_ports(rule)]
        self.assertEqual(1, len(rules), "exactly one ingress rule may mention 4040")
        rule = rules[0]
        self.assertEqual([{"protocol": "TCP", "port": METRICS_PORT}], rule.get("ports"))
        self.assertEqual([{"namespaceSelector": {}, "podSelector": {"matchLabels": SCRAPER}}],
                         rule.get("from"),
                         "the 4040 rule admits the scraper-labelled pod, nothing else")

    def test_the_notebook_rule_is_unchanged(self):
        rules = [rule for rule in ingress_rules(self.documents)
                 if CONNECT_PORT in rule_ports(rule)]
        self.assertEqual(1, len(rules), "exactly one ingress rule may mention 15002")
        rule = rules[0]
        self.assertEqual([{"protocol": "TCP", "port": CONNECT_PORT}], rule.get("ports"))
        peers = rule.get("from") or []
        self.assertEqual(1, len(peers), "the 15002 rule has exactly one peer")
        selector = peers[0].get("podSelector") or {}
        self.assertEqual({"component": "singleuser-server"},
                         selector.get("matchLabels") or {},
                         "15002 stays limited to members' notebook pods")
        self.assertIn({"key": "stardelt.io/group.visitors", "operator": "DoesNotExist"},
                      selector.get("matchExpressions") or [],
                      "the public demo's visitor pod is still refused on 15002")
        self.assertNotIn("namespaceSelector", peers[0],
                         "the notebook rule must not widen to other namespaces")
        self.assertNotEqual(SCRAPER, selector.get("matchLabels"),
                           "the notebook rule must not admit the scraper")

    def test_the_per_user_catalogue_keeps_the_ui_dark(self):
        with open(CATALOGUE, encoding="utf-8") as handle:
            catalogue = yaml.safe_load(handle)
        self.assertEqual(1, len(catalogue), "the catalogue carries exactly one runtime")
        spark_conf = next(iter(catalogue.values()))["sparkConf"]
        self.assertEqual("false", spark_conf.get("spark.ui.enabled"),
                         "per-user SparkCluster servers must not expose a UI")
        self.assertIn(spark_conf.get("spark.ui.prometheus.enabled"), (None, "false"),
                      "per-user SparkCluster servers must not serve Prometheus text")

    def test_the_gate_excludes_the_ui_setting(self):
        script = GATE.read_text(encoding="utf-8")
        exclusions = script.split("excluded_keys=$(cat <<'EOF'", 1)[1].split("EOF", 1)[0]
        keys = [line.strip() for line in exclusions.splitlines() if line.strip()]
        self.assertIn("spark.ui.enabled", keys,
                      "check-spark-runtimes.sh must allow the shared server's UI difference")
        self.assertIn("spark.ui.prometheus.enabled", keys,
                      "check-spark-runtimes.sh must allow the shared server's servlet difference")


if __name__ == "__main__":
    unittest.main()
