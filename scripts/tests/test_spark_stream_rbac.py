"""The StreamApp driver has its own identity and executor Secret scope (platform#1298)."""

import pathlib
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "manifests" / "spark-stream-rbac.yaml"
DOCS = [d for d in yaml.safe_load_all(MANIFEST.read_text()) if d]

WIDENED_SECRET_KEY_REF = (
    "object.spec.containers.all(c, !has(c.env) || c.env.all(e, !has(e.valueFrom)"
    " || !has(e.valueFrom.secretKeyRef) || e.valueFrom.secretKeyRef.name == 'stardelt-s3-creds'"
    " || e.valueFrom.secretKeyRef.name.startsWith('sp-pipeline-')))"
)
WIDENED_SECRET_REF = (
    "object.spec.containers.all(c, !has(c.envFrom) || c.envFrom.all(e, !has(e.secretRef)"
    " || e.secretRef.name == 'stardelt-s3-creds' || e.secretRef.name.startsWith('sp-pipeline-')))"
)
CONNECT_ONLY_SECRET_KEY_REF = (
    "object.spec.containers.all(c, !has(c.env) || c.env.all(e, !has(e.valueFrom)"
    " || !has(e.valueFrom.secretKeyRef) || e.valueFrom.secretKeyRef.name == 'stardelt-s3-creds'))"
)


class SparkStreamRbacTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = DOCS
        cls.policy = cls.by_name("ValidatingAdmissionPolicy", "spark-stream-executor-pods")
        cls.binding = cls.by_name("ValidatingAdmissionPolicyBinding", "spark-stream-executor-pods")
        cls.configmap_policy = cls.by_name("ValidatingAdmissionPolicy", "spark-stream-configmaps")
        cls.configmap_binding = cls.by_name(
            "ValidatingAdmissionPolicyBinding", "spark-stream-configmaps")
        cls.role = next(d for d in cls.docs if d.get("kind") == "Role")
        cls.role_binding = next(d for d in cls.docs if d.get("kind") == "RoleBinding")
        cls.service_account = next(d for d in cls.docs if d.get("kind") == "ServiceAccount")

    @staticmethod
    def by_name(kind, name):
        for doc in DOCS:
            if doc.get("kind") == kind and doc.get("metadata", {}).get("name") == name:
                return doc
        raise AssertionError(f"no {kind} named {name} in {MANIFEST}")

    def test_the_file_holds_exactly_the_seven_objects(self):
        self.assertEqual(
            [(d["kind"], d["metadata"]["name"]) for d in self.docs],
            [
                ("ServiceAccount", "spark-stream-driver"),
                ("Role", "spark-stream-driver"),
                ("RoleBinding", "spark-stream-driver"),
                ("ValidatingAdmissionPolicy", "spark-stream-executor-pods"),
                ("ValidatingAdmissionPolicyBinding", "spark-stream-executor-pods"),
                ("ValidatingAdmissionPolicy", "spark-stream-configmaps"),
                ("ValidatingAdmissionPolicyBinding", "spark-stream-configmaps"),
            ],
        )

    def test_every_object_is_labelled_as_part_of_the_platform(self):
        for doc in self.docs:
            self.assertEqual(doc["metadata"].get("labels"),
                             {"app.kubernetes.io/part-of": "stardelt"}, doc["kind"])

    def test_the_namespaced_objects_live_in_stardelt(self):
        for doc in (self.service_account, self.role, self.role_binding):
            self.assertEqual(doc["metadata"]["namespace"], "stardelt")

    def test_the_driver_mounts_its_token(self):
        self.assertIsNot(self.service_account.get("automountServiceAccountToken"), False)

    def test_the_driver_role_grants_pods_and_configmaps_only(self):
        self.assertEqual(self.role["rules"], [
            {"apiGroups": [""], "resources": ["pods"],
             "verbs": ["get", "list", "watch", "create", "delete", "deletecollection"]},
            {"apiGroups": [""], "resources": ["configmaps"],
             "verbs": ["get", "list", "create", "delete"]},
        ])

    def test_the_role_binding_names_the_stream_driver(self):
        self.assertEqual(self.role_binding["subjects"], [
            {"kind": "ServiceAccount", "name": "spark-stream-driver", "namespace": "stardelt"},
        ])
        self.assertEqual(self.role_binding["roleRef"],
                         {"kind": "Role", "name": "spark-stream-driver",
                          "apiGroup": "rbac.authorization.k8s.io"})

    def test_the_policy_is_cluster_scoped_and_fails_closed(self):
        self.assertEqual(self.policy["metadata"]["name"], "spark-stream-executor-pods")
        self.assertNotIn("namespace", self.policy["metadata"])
        self.assertEqual(self.policy["spec"]["failurePolicy"], "Fail")

    def test_the_policy_applies_to_the_stream_driver_only(self):
        conditions = self.policy["spec"]["matchConditions"]
        self.assertEqual(conditions, [{
            "name": "created-by-spark-stream-driver",
            "expression": "request.userInfo.username == 'system:serviceaccount:'"
                          " + request.namespace + ':spark-stream-driver'",
        }])

    def test_the_executor_secret_scope_is_widened_to_the_stream_catalog(self):
        expressions = [v["expression"] for v in self.policy["spec"]["validations"]]
        self.assertIn(WIDENED_SECRET_KEY_REF, expressions)
        self.assertIn(WIDENED_SECRET_REF, expressions)
        self.assertNotIn(CONNECT_ONLY_SECRET_KEY_REF, expressions)

    def test_every_other_connect_validation_is_unchanged(self):
        expressions = [v["expression"] for v in self.policy["spec"]["validations"]]
        self.assertEqual(len(expressions), 12)
        for expression in [
            "object.spec.serviceAccountName == 'spark-executor'",
            "!has(object.spec.hostNetwork) || object.spec.hostNetwork == false",
            "!has(object.spec.hostPID) || object.spec.hostPID == false",
            "!has(object.spec.hostIPC) || object.spec.hostIPC == false",
            "!has(object.spec.initContainers) || object.spec.initContainers.size() == 0",
            "!has(object.spec.ephemeralContainers) || object.spec.ephemeralContainers.size() == 0",
            "object.spec.containers.all(c, c.image.startsWith('ghcr.io/stardelt/spark:'))",
            "object.spec.containers.all(c, !has(c.securityContext) || !has(c.securityContext.privileged)"
            " || c.securityContext.privileged != true)",
            "object.spec.containers.all(c, !has(c.ports) || c.ports.all(p, !has(p.hostPort) || p.hostPort == 0))",
            "!has(object.spec.volumes) || object.spec.volumes.all(v, has(v.configMap) || has(v.emptyDir))",
        ]:
            self.assertIn(expression, expressions)

    def test_the_policy_covers_pods_and_ephemeral_containers(self):
        self.assertEqual(self.policy["spec"]["matchConstraints"]["resourceRules"], [
            {"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["pods"]},
            {"apiGroups": [""], "apiVersions": ["v1"], "operations": ["UPDATE"],
             "resources": ["pods/ephemeralcontainers"]},
        ])

    def test_the_binding_denies_in_the_platform_namespace(self):
        self.assertEqual(self.binding["metadata"]["name"], "spark-stream-executor-pods")
        self.assertNotIn("namespace", self.binding["metadata"])
        self.assertEqual(self.binding["spec"]["policyName"], "spark-stream-executor-pods")
        self.assertEqual(self.binding["spec"]["validationActions"], ["Deny"])
        selector = self.binding["spec"]["matchResources"]["namespaceSelector"]
        self.assertEqual(selector["matchLabels"]["kubernetes.io/metadata.name"], "stardelt")

    def test_the_config_map_policy_matches_only_the_stream_driver(self):
        policy = self.configmap_policy
        self.assertEqual(policy["metadata"]["name"], "spark-stream-configmaps")
        self.assertNotIn("namespace", policy["metadata"])
        self.assertEqual(policy["spec"]["failurePolicy"], "Fail")
        self.assertEqual(policy["spec"]["matchConstraints"]["resourceRules"], [
            {"apiGroups": [""], "apiVersions": ["v1"],
             "operations": ["CREATE", "DELETE"], "resources": ["configmaps"]},
        ])
        conditions = policy["spec"]["matchConditions"]
        self.assertEqual(len(conditions), 1)
        self.assertIn(":spark-stream-driver'", conditions[0]["expression"])
        self.assertNotIn(":spark-connect'", conditions[0]["expression"])
        self.assertNotIn(":spark-batch-driver'", conditions[0]["expression"])
        validations = policy["spec"]["validations"]
        self.assertEqual(len(validations), 1)
        self.assertEqual(validations[0]["expression"],
                         "request.name.startsWith('spark-') && request.name.endsWith('-conf-map')")

    def test_the_config_map_binding_denies_in_this_namespace(self):
        binding = self.configmap_binding
        self.assertEqual(binding["spec"]["policyName"], "spark-stream-configmaps")
        self.assertEqual(binding["spec"]["validationActions"], ["Deny"])
        selector = binding["spec"]["matchResources"]["namespaceSelector"]
        self.assertEqual(selector["matchLabels"]["kubernetes.io/metadata.name"], "stardelt")

    def test_make_install_applies_it_inside_the_admission_policy_block(self):
        makefile = (REPO_ROOT / "Makefile").read_text()
        install_spark = makefile.split("install-spark:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("kubectl apply -f manifests/spark-stream-rbac.yaml", install_spark)
        uninstall = makefile.split("uninstall:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("kubectl delete -f manifests/spark-stream-rbac.yaml --ignore-not-found", uninstall)


if __name__ == "__main__":
    unittest.main()
