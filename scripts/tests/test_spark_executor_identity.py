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

    def test_the_driver_mounts_and_selects_the_executor_pod_template(self):
        data = self.by_name("ConfigMap", "spark-connect-config")["data"]
        self.assertIn("executor-pod-template.yaml", data)

        conf = data["spark-defaults.conf"]
        line = next(l for l in conf.splitlines()
                    if l.strip().startswith("spark.kubernetes.executor.podTemplateFile"))
        self.assertEqual(line.split()[-1], "/opt/spark/conf/executor-pod-template.yaml")

        deployment = self.by_name("Deployment", "spark-connect")
        container = next(
            c for c in deployment["spec"]["template"]["spec"]["containers"]
            if c["name"] == "spark-connect"
        )
        mounts = [m for m in container["volumeMounts"]
                  if m["mountPath"] == "/opt/spark/conf/executor-pod-template.yaml"]
        self.assertEqual(len(mounts), 1, "the driver must mount the executor pod template")
        self.assertEqual(mounts[0]["subPath"], "executor-pod-template.yaml")
        self.assertIs(mounts[0]["readOnly"], True)

    def test_the_executor_pod_template_declares_the_restricted_fields(self):
        data = self.by_name("ConfigMap", "spark-connect-config")["data"]
        pod = yaml.safe_load(data["executor-pod-template.yaml"])
        self.assertEqual(pod["spec"]["securityContext"], {
            "runAsNonRoot": True,
            "runAsUser": 185,
            "fsGroup": 185,
            "seccompProfile": {"type": "RuntimeDefault"},
        })
        containers = pod["spec"]["containers"]
        self.assertEqual(len(containers), 1)
        self.assertEqual(containers[0]["name"], "spark-kubernetes-executor")
        self.assertEqual(containers[0]["securityContext"], {
            "allowPrivilegeEscalation": False,
            "capabilities": {"drop": ["ALL"]},
        })

    def test_the_runtime_catalogue_gate_excludes_the_template_key(self):
        script = (REPO_ROOT / "scripts" / "check-spark-runtimes.sh").read_text()
        exclusions = script.split("excluded_keys=$(cat <<'EOF'", 1)[1].split("EOF", 1)[0]
        keys = [line.strip() for line in exclusions.splitlines() if line.strip()]
        self.assertIn("spark.kubernetes.executor.podTemplateFile", keys,
                      "check-spark-runtimes.sh must allow the shared server's template difference")
