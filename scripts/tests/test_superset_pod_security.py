"""The Superset release declares the Pod Security `restricted` fields (platform#1096)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]

POD = {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}}
CONTAINER = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}


class SupersetPodSecurityTest(unittest.TestCase):
    def setUp(self):
        with open(ROOT / "helm-values" / "superset.yaml", encoding="utf-8") as handle:
            self.values = yaml.safe_load(handle)

    def test_the_pods_run_as_1000(self):
        self.assertEqual(self.values["runAsUser"], 1000)

    def test_every_workload_declares_the_restricted_fields(self):
        for workload in ("supersetNode", "supersetWorker", "init"):
            with self.subTest(workload=workload):
                self.assertEqual(self.values[workload]["podSecurityContext"], POD)
                self.assertEqual(self.values[workload]["containerSecurityContext"], CONTAINER)

    def test_the_init_containers_keep_the_chart_default_and_gain_the_fields(self):
        expected = {
            "supersetNode": (
                "wait-for-postgres",
                'dockerize -wait "tcp://$DB_HOST:$DB_PORT" -timeout 120s',
            ),
            "supersetWorker": (
                "wait-for-postgres-redis",
                'dockerize -wait "tcp://$DB_HOST:$DB_PORT" '
                '-wait "tcp://$REDIS_HOST:$REDIS_PORT" -timeout 120s',
            ),
            "init": (
                "wait-for-postgres",
                'dockerize -wait "tcp://$DB_HOST:$DB_PORT" -timeout 120s',
            ),
        }
        for workload, (name, command) in expected.items():
            with self.subTest(workload=workload):
                containers = self.values[workload]["initContainers"]
                self.assertEqual(len(containers), 1)
                self.assertEqual(containers[0]["name"], name)
                self.assertEqual(containers[0]["image"], "apache/superset:dockerize")
                self.assertEqual(containers[0]["command"], ["/bin/sh", "-c", command])
                self.assertEqual(containers[0]["securityContext"], CONTAINER)
                self.assertEqual(
                    containers[0]["envFrom"], [{"secretRef": {"name": "superset-env"}}]
                )

    def test_the_bundled_redis_stays_at_1001_and_declares_the_fields(self):
        master = self.values["redis"]["master"]
        self.assertEqual(master["podSecurityContext"], {"fsGroup": 1001, **POD})
        self.assertEqual(master["containerSecurityContext"], {"runAsUser": 1001, **CONTAINER})


if __name__ == "__main__":
    unittest.main()
