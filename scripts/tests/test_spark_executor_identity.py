"""Executors run without the platform's API rights (platform#1096 slice 1)."""

import pathlib
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "manifests" / "spark.yaml"


class SparkExecutorIdentityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = [d for d in yaml.safe_load_all(MANIFEST.read_text()) if d]

    def by_name(self, kind, name):
        for doc in self.docs:
            if doc.get("kind") == kind and doc.get("metadata", {}).get("name") == name:
                return doc
        self.fail(f"no {kind} named {name} in {MANIFEST}")

    def test_the_executor_service_account_mounts_no_token(self):
        sa = self.by_name("ServiceAccount", "spark-executor")
        self.assertIs(sa.get("automountServiceAccountToken"), False)

    def test_no_role_binding_names_the_executor(self):
        for doc in self.docs:
            for subject in (doc.get("subjects") or []) if doc.get("kind") == "RoleBinding" else []:
                self.assertNotEqual(subject.get("name"), "spark-executor")

    def test_the_executor_uses_its_own_service_account(self):
        conf = self.by_name("ConfigMap", "spark-connect-config")["data"]["spark-defaults.conf"]
        line = next(l for l in conf.splitlines()
                    if l.strip().startswith("spark.kubernetes.authenticate.executor.serviceAccountName"))
        self.assertEqual(line.split()[-1], "spark-executor")

    def test_the_driver_keeps_its_service_account(self):
        sa = self.by_name("ServiceAccount", "spark-connect")
        self.assertIsNot(sa.get("automountServiceAccountToken"), False)

    def test_the_driver_role_grants_no_services_and_no_pvcs(self):
        role = self.by_name("Role", "spark-connect")
        resources = [r["resources"] for r in role["rules"]]
        self.assertEqual(resources, [["pods"], ["configmaps"]])

    def test_the_driver_role_cannot_update_or_collect_delete_configmaps(self):
        role = self.by_name("Role", "spark-connect")
        configmaps = next(r for r in role["rules"] if r["resources"] == ["configmaps"])
        self.assertEqual(configmaps["verbs"], ["get", "list", "create", "delete"])

    def test_the_ingress_policy_still_admits_executors(self):
        policy = self.by_name("NetworkPolicy", "spark-connect-ingress")
        rules = policy["spec"]["ingress"]
        labels = [p["podSelector"]["matchLabels"]
                  for rule in rules for p in (rule.get("from") or [])]
        self.assertIn({"stardelt.io/spark-connect": "executor"}, labels)
