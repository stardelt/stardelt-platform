"""The two metrics endpoints a scraper may read (stardelt-platform#1128, operator#607).

Two things have to be true at once, or the endpoints stay dark:

  * the chart values turn the endpoint on (OpenFGA's metrics server is off by
    default; Lakekeeper's metrics server is always on, but the chart only adds the
    `metrics` Service port when `catalog.prometheus.setScrapeAnnotations` is set);
  * the ingress policy admits the scraper and nothing else, so "the catalog
    answers 5xx" is observable without opening the ports to every pod.

Standard library + PyYAML only.
"""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]

SCRAPER = {"app.kubernetes.io/name": "prometheus"}


def load_values(name):
    with open(ROOT / "helm-values" / name, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def load_policy(name):
    with open(ROOT / "manifests" / name, encoding="utf-8") as handle:
        documents = [d for d in yaml.safe_load_all(handle) if d]
    policies = [d for d in documents if d.get("kind") == "NetworkPolicy"]
    if len(policies) != 1:
        raise AssertionError("%s: expected one NetworkPolicy, found %d"
                             % (name, len(policies)))
    return policies[0]


class ValuesTest(unittest.TestCase):
    def test_the_values_turn_the_two_endpoints_on(self):
        openfga = load_values("openfga.yaml")
        self.assertIs(openfga["telemetry"]["metrics"]["enabled"], True)

        lakekeeper = load_values("lakekeeper.yaml")
        self.assertIs(lakekeeper["catalog"]["prometheus"]["setScrapeAnnotations"], True)


class PolicyTest(unittest.TestCase):
    def assert_only_a_scraper(self, name, port):
        policy = load_policy(name)
        rules = policy["spec"]["ingress"]

        scrape = [rule for rule in rules
                  if rule.get("ports") == [{"protocol": "TCP", "port": port}]]
        self.assertEqual(len(scrape), 1,
                         "%s: expected exactly one rule on port %d, found %d"
                         % (name, port, len(scrape)))
        self.assertEqual(scrape[0]["from"],
                         [{"namespaceSelector": {}, "podSelector": {"matchLabels": SCRAPER}}],
                         "%s: port %d must be open to exactly the scraper label" % (name, port))

        for rule in rules:
            if rule is scrape[0]:
                continue
            for peer in rule.get("from") or []:
                self.assertNotIn("namespaceSelector", peer,
                                 "%s: a caller rule must stay same-namespace" % name)

    def test_the_policies_admit_only_a_prometheus_scraper(self):
        self.assert_only_a_scraper("lakekeeper-network-policy.yaml", 9000)
        self.assert_only_a_scraper("openfga-network-policy.yaml", 2112)


if __name__ == "__main__":
    unittest.main()
