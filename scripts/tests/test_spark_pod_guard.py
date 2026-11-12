"""The Spark Connect driver may create executor pods only (platform#1096)."""

import pathlib
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "manifests" / "spark-connect-pod-guard.yaml"

EXPRESSIONS = [
    "object.spec.serviceAccountName == 'spark-executor'",
    "!has(object.spec.hostNetwork) || object.spec.hostNetwork == false",
    "!has(object.spec.hostPID) || object.spec.hostPID == false",
    "!has(object.spec.hostIPC) || object.spec.hostIPC == false",
    "!has(object.spec.initContainers) || object.spec.initContainers.size() == 0",
    "!has(object.spec.ephemeralContainers) || object.spec.ephemeralContainers.size() == 0",
    "object.spec.containers.all(c, c.image.startsWith('ghcr.io/stardelt/spark:'))",
    "object.spec.containers.all(c, !has(c.securityContext) || !has(c.securityContext.privileged) || c.securityContext.privileged != true)",
    "object.spec.containers.all(c, !has(c.ports) || c.ports.all(p, !has(p.hostPort) || p.hostPort == 0))",
    "!has(object.spec.volumes) || object.spec.volumes.all(v, has(v.configMap) || has(v.emptyDir))",
    "object.spec.containers.all(c, !has(c.env) || c.env.all(e, !has(e.valueFrom) || !has(e.valueFrom.secretKeyRef) || e.valueFrom.secretKeyRef.name == 'stardelt-s3-creds'))",
    "object.spec.containers.all(c, !has(c.envFrom) || c.envFrom.all(e, !has(e.secretRef) || e.secretRef.name == 'stardelt-s3-creds'))",
]


class SparkPodGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = [d for d in yaml.safe_load_all(MANIFEST.read_text()) if d]
        cls.policy = next(d for d in cls.docs if d.get("kind") == "ValidatingAdmissionPolicy")
        cls.binding = next(d for d in cls.docs if d.get("kind") == "ValidatingAdmissionPolicyBinding")

    def test_the_policy_is_cluster_scoped(self):
        self.assertEqual(self.policy["metadata"]["name"], "spark-connect-executor-pods")
        self.assertNotIn("namespace", self.policy["metadata"])

    def test_the_policy_fails_closed(self):
        self.assertEqual(self.policy["spec"]["failurePolicy"], "Fail")

    def test_the_policy_covers_pods_and_ephemeral_containers(self):
        rules = self.policy["spec"]["matchConstraints"]["resourceRules"]
        self.assertIn(
            {"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["pods"]},
            rules,
        )
        self.assertIn(
            {"apiGroups": [""], "apiVersions": ["v1"], "operations": ["UPDATE"],
             "resources": ["pods/ephemeralcontainers"]},
            rules,
        )

    def test_the_policy_applies_to_the_driver_only(self):
        conditions = self.policy["spec"]["matchConditions"]
        self.assertTrue(any(":spark-connect'" in c["expression"] for c in conditions))

    def test_every_validation_is_present(self):
        expressions = [v["expression"] for v in self.policy["spec"]["validations"]]
        for expression in EXPRESSIONS:
            self.assertIn(expression, expressions)

    def test_the_binding_denies_with_the_policy(self):
        self.assertEqual(self.binding["metadata"]["name"], "spark-connect-executor-pods")
        self.assertNotIn("namespace", self.binding["metadata"])
        self.assertEqual(self.binding["spec"]["policyName"], "spark-connect-executor-pods")
        self.assertEqual(self.binding["spec"]["validationActions"], ["Deny"])

    def test_the_binding_covers_the_platform_namespace_only(self):
        selector = self.binding["spec"]["matchResources"]["namespaceSelector"]
        self.assertEqual(selector["matchLabels"]["kubernetes.io/metadata.name"], "stardelt")


if __name__ == "__main__":
    unittest.main()
