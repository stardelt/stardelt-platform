"""Keycloak's management port answers only a scraper (#607)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "manifests" / "keycloak-network-policy.yaml"


def policy():
    documents = [d for d in yaml.safe_load_all(MANIFEST.read_text(encoding="utf-8")) if d]
    policies = [d for d in documents if d.get("kind") == "NetworkPolicy"]
    assert len(policies) == 1, documents
    return policies[0]


class KeycloakPolicyTest(unittest.TestCase):
    def test_it_selects_the_keycloak_pod(self):
        self.assertEqual(policy()["spec"]["podSelector"]["matchLabels"],
                         {"app.kubernetes.io/name": "keycloak"})

    def test_the_sign_in_port_stays_open_to_every_source(self):
        rule = policy()["spec"]["ingress"][0]
        self.assertNotIn("from", rule)
        self.assertEqual(rule["ports"], [{"protocol": "TCP", "port": 8080}])

    def test_the_management_port_answers_only_the_scraper(self):
        rule = policy()["spec"]["ingress"][1]
        self.assertEqual(rule["from"], [{
            "namespaceSelector": {},
            "podSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}},
        }])
        self.assertEqual(rule["ports"], [{"protocol": "TCP", "port": 9000}])

    def test_only_the_scrape_rule_crosses_namespaces(self):
        ingress = policy()["spec"]["ingress"]
        peers = [peer for rule in ingress for peer in rule.get("from") or []]
        crossing = [peer for peer in peers if "namespaceSelector" in peer]
        self.assertEqual(crossing, [{
            "namespaceSelector": {},
            "podSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}},
        }])
        self.assertEqual([peer for peer in peers if "ipBlock" in peer], [])
        ports = [port["port"] for rule in ingress for port in rule.get("ports") or []]
        self.assertEqual(ports, [8080, 9000])


if __name__ == "__main__":
    unittest.main()
