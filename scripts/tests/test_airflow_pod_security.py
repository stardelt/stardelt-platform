"""The Airflow pods declare the Pod Security `restricted` fields (platform#1096)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]

POD = {
    "runAsUser": 50000,
    "fsGroup": 0,
    "runAsNonRoot": True,
    "seccompProfile": {"type": "RuntimeDefault"},
}
CONTAINER = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}
STATSD_POD = {
    "runAsUser": 65534,
    "runAsNonRoot": True,
    "seccompProfile": {"type": "RuntimeDefault"},
}


class AirflowPodSecurityTest(unittest.TestCase):
    def setUp(self):
        with open(ROOT / "helm-values" / "airflow.yaml", encoding="utf-8") as handle:
            self.values = yaml.safe_load(handle)

    def test_the_global_block_repeats_the_ids_and_adds_run_as_non_root(self):
        # The pod block replaces the chart's uid/gid fallback, so 50000/0 must be explicit.
        self.assertEqual(self.values["securityContexts"]["pod"], POD)
        self.assertEqual(self.values["securityContexts"]["containers"], CONTAINER)

    def test_statsd_has_its_own_block(self):
        # The chart reads statsd.securityContexts; the global block does not reach statsd.
        statsd = self.values["statsd"]["securityContexts"]
        self.assertEqual(statsd["pod"], STATSD_POD)
        self.assertEqual(statsd["container"], CONTAINER)


if __name__ == "__main__":
    unittest.main()
