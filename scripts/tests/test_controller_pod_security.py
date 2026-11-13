"""OpenFGA, Reloader and OpenBao declare the Pod Security `restricted` fields (platform#1096)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]

CONTAINER = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}


def load(name):
    with open(ROOT / "helm-values" / name, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


class ControllerPodSecurityTest(unittest.TestCase):
    def test_openfga_pod_and_container(self):
        values = load("openfga.yaml")
        self.assertEqual(
            values["podSecurityContext"],
            {
                "runAsNonRoot": True,
                "runAsUser": 65532,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
        )
        self.assertEqual(values["securityContext"], CONTAINER)

    def test_reloader_container(self):
        values = load("reloader.yaml")
        self.assertEqual(
            values["reloader"]["deployment"]["containerSecurityContext"], CONTAINER
        )

    def test_openbao_container(self):
        values = load("openbao.yaml")
        self.assertEqual(
            values["server"]["statefulSet"]["securityContext"]["container"], CONTAINER
        )


if __name__ == "__main__":
    unittest.main()
