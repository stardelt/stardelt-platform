"""The Trino pods declare the Pod Security `restricted` fields (platform#1096)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]

POD = {
    "runAsUser": 1000,
    "runAsGroup": 1000,
    "runAsNonRoot": True,
    "seccompProfile": {"type": "RuntimeDefault"},
}
CONTAINER = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}


class TrinoPodSecurityTest(unittest.TestCase):
    def setUp(self):
        with open(ROOT / "helm-values" / "trino.yaml", encoding="utf-8") as handle:
            self.values = yaml.safe_load(handle)

    def test_the_pod_block_keeps_the_image_ids_and_adds_run_as_non_root(self):
        # The block replaces the chart's default, so 1000/1000 must stay explicit.
        self.assertEqual(self.values["securityContext"], POD)

    def test_the_container_block_repeats_the_chart_fields_and_adds_seccomp(self):
        # containerSecurityContext replaces the chart's block: APE and capabilities must stay.
        self.assertEqual(self.values["containerSecurityContext"], CONTAINER)

    def test_the_identity_overlays_give_the_init_container_its_own_block(self):
        # Init containers inherit nothing from the chart's keys; the block is the only one
        # (platform#1096). The wait-for-idp entry is a whole-list value, so it must carry it.
        for name in ("trino-identity.yaml", "trino-identity-file-only.yaml"):
            with open(ROOT / "helm-values" / name, encoding="utf-8") as handle:
                values = yaml.safe_load(handle)
            wait = next(
                c for c in values["initContainers"]["coordinator"] if c["name"] == "wait-for-idp"
            )
            self.assertEqual(
                wait["securityContext"],
                {
                    "runAsNonRoot": True,
                    "allowPrivilegeEscalation": False,
                    "capabilities": {"drop": ["ALL"]},
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
                name,
            )


if __name__ == "__main__":
    unittest.main()
