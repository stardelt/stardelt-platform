"""The object store's unsigned ports are closed to every pod but SeaweedFS (platform#1100).

SeaweedFS's S3 gateway (8333) checks an access key; the filer (8888), master (9333)
and volume servers (8080) check nothing with the chart's defaults. Any pod in the
namespace could therefore read and delete every catalog's objects through the filer,
past every Catalog grant. ``manifests/seaweedfs-network-policy.yaml`` is the only gate
on those ports until JWT signing or scoped S3 identities land, so this test pins its
shape:

* only master/filer/volume are selected as targets — the S3 gateway and the admin UI
  stay reachable in the namespace (8333 checks keys; the admin UI is not a data path);
* the first ingress rule admits SeaweedFS pods on *all* ports — the components use HTTP
  and gRPC ports alike (8888/18888, 9333/19333, 8080/18080), so a ``ports`` list would
  cut one of them off;
* the second rule admits the customer's Prometheus on 9327 only, where master, filer
  and volume answer Prometheus text (stardelt-operator#607);
* the third rule admits only the chart's bucket-hook Job (`job-name:
  seaweedfs-bucket-hook`) on the four ports `weed shell` uses (9333, 8888,
  19333, 18888); it runs during `helm upgrade`, so it meets the policy of the
  previous install (platform#1244);
* the policy is ingress-only, the second (scrape) rule is the only peer that crosses
  namespaces, on 9327 only, and there is no ``ipBlock``.

The installer has to apply it and the teardown to remove it, otherwise the gate exists
only where someone applied it by hand.
"""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "manifests" / "seaweedfs-network-policy.yaml"
MAKEFILE = ROOT / "Makefile"

TARGET = "seaweedfs-internal"
TARGETED_COMPONENTS = ["master", "filer", "volume"]


def policy():
    documents = [doc for doc in yaml.safe_load_all(MANIFEST.read_text()) if doc]
    assert len(documents) == 1, f"{MANIFEST} carries {len(documents)} documents"
    return documents[0]


def recipe(target):
    """The tab-indented lines of one Makefile target, without comments."""
    lines = MAKEFILE.read_text().splitlines()
    body, inside = [], False
    for line in lines:
        if re.match(r"^[A-Za-z0-9_.%/-]+:", line):
            if inside:
                break
            inside = line.startswith(f"{target}:")
            continue
        if inside:
            body.append(line)
    assert body, f"{MAKEFILE} has no recipe for target {target}"
    return "\n".join(body)


class Shape(unittest.TestCase):
    def test_it_is_one_ingress_only_policy(self):
        doc = policy()
        self.assertEqual(doc["kind"], "NetworkPolicy")
        self.assertEqual(doc["metadata"]["name"], TARGET)
        self.assertEqual(doc["spec"]["policyTypes"], ["Ingress"])
        self.assertNotIn("egress", doc["spec"])

    def test_only_the_unsigned_components_are_targets(self):
        selector = policy()["spec"]["podSelector"]
        self.assertEqual(
            selector["matchLabels"], {"app.kubernetes.io/name": "seaweedfs"}
        )
        expressions = selector["matchExpressions"]
        self.assertEqual(len(expressions), 1, expressions)
        expression = expressions[0]
        self.assertEqual(expression["key"], "app.kubernetes.io/component")
        self.assertEqual(expression["operator"], "In")
        self.assertEqual(sorted(expression["values"]), sorted(TARGETED_COMPONENTS))

    def test_the_first_rule_admits_only_seaweedfs_on_every_port(self):
        ingress = policy()["spec"]["ingress"]
        self.assertEqual(len(ingress), 3, ingress)
        rule = ingress[0]
        self.assertEqual(
            rule["from"],
            [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "seaweedfs"}}}],
            "the only admitted peer of the first rule is a SeaweedFS pod selector",
        )
        self.assertNotIn(
            "ports",
            rule,
            "a ports list would cut off one of the HTTP/gRPC ports "
            "(8888/18888, 9333/19333, 8080/18080)",
        )

    def test_only_the_scrape_rule_crosses_namespaces_or_uses_an_address(self):
        self.assertEqual(
            policy()["spec"]["ingress"][1]["from"],
            [
                {
                    "namespaceSelector": {},
                    "podSelector": {
                        "matchLabels": {"app.kubernetes.io/name": "prometheus"}
                    },
                }
            ],
            "the scrape rule admits a labelled Prometheus in every namespace",
        )
        self.assertEqual(
            policy()["spec"]["ingress"][1]["ports"],
            [{"protocol": "TCP", "port": 9327}],
            "the scrape rule opens 9327 only",
        )
        self.assertEqual(
            MANIFEST.read_text().count("namespaceSelector"),
            1,
            "only the scrape rule may cross namespaces",
        )
        self.assertNotIn("ipBlock", MANIFEST.read_text())

    def test_the_scrape_rule_opens_9327_and_not_the_unsigned_ports(self):
        ports = [
            entry["port"]
            for rule in policy()["spec"]["ingress"]
            for entry in rule.get("ports", [])
        ]
        self.assertEqual(
            ports,
            [9327, 9333, 8888, 19333, 18888],
            "the scrape rule adds 9327, the bucket-hook rule adds its four ports, "
            "and no rule names a range",
        )

    def test_the_bucket_hook_rule_admits_only_the_hook_job_on_its_four_ports(self):
        rule = policy()["spec"]["ingress"][2]
        self.assertEqual(
            rule["from"],
            [{"podSelector": {"matchLabels": {"job-name": "seaweedfs-bucket-hook"}}}],
            "the hook is identified by the Job controller's job-name label",
        )
        self.assertEqual(
            rule["ports"],
            [
                {"protocol": "TCP", "port": 9333},
                {"protocol": "TCP", "port": 8888},
                {"protocol": "TCP", "port": 19333},
                {"protocol": "TCP", "port": 18888},
            ],
            "master HTTP, filer HTTP, master gRPC, filer gRPC",
        )


class Installer(unittest.TestCase):
    def test_step_storage_applies_the_policy(self):
        self.assertIn(
            "kubectl apply -f manifests/seaweedfs-network-policy.yaml",
            recipe("step-storage"),
            "`make step-storage` installs SeaweedFS, so it must close the unsigned ports",
        )

    def test_step_storage_applies_the_policy_before_the_upgrade(self):
        body = recipe("step-storage")
        self.assertLess(
            body.index("kubectl apply -f manifests/seaweedfs-network-policy.yaml"),
            body.index("helm upgrade --install seaweedfs"),
            "an upgrade must meet the policy it ships, not the previous one",
        )

    def test_uninstall_removes_the_policy(self):
        self.assertIn(
            "kubectl delete -f manifests/seaweedfs-network-policy.yaml",
            recipe("uninstall"),
            "`make uninstall` removes the SeaweedFS release, so the policy must go too",
        )


if __name__ == "__main__":
    unittest.main()
