"""The Lakekeeper catalog pod and migration Job declare the Pod Security `restricted` fields (platform#1096)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]

POD = {
    "runAsNonRoot": True,
    "seccompProfile": {"type": "RuntimeDefault"},
}
CONTAINER = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}


class LakekeeperPodSecurityTest(unittest.TestCase):
    def setUp(self):
        with open(ROOT / "helm-values" / "lakekeeper.yaml", encoding="utf-8") as handle:
            self.catalog = yaml.safe_load(handle)["catalog"]

    def test_the_pod_and_container_blocks(self):
        # Both keys are the chart's camelCase catalog keys; snake_case does nothing.
        self.assertEqual(self.catalog["podSecurityContext"], POD)
        self.assertEqual(self.catalog["containerSecurityContext"], CONTAINER)

    def test_wait_for_idp_carries_its_own_block(self):
        # The whole extraInitContainers list is a value: an entry without this block loses it.
        init_containers = self.catalog["extraInitContainers"]
        names = [c["name"] for c in init_containers]
        self.assertIn("wait-for-idp", names)
        wait = next(c for c in init_containers if c["name"] == "wait-for-idp")
        self.assertEqual(
            wait["securityContext"],
            {
                # numeric: the pod-level `runAsNonRoot` (required by `restricted`) makes the
                # kubelet refuse a named image user it cannot verify (platform#1202).
                "runAsUser": 1000,
                "runAsNonRoot": True,
                "allowPrivilegeEscalation": False,
                "capabilities": {"drop": ["ALL"]},
                "seccompProfile": {"type": "RuntimeDefault"},
            },
        )


if __name__ == "__main__":
    unittest.main()
