"""Tests for the OpenBao group-policies CronJob's pod security context (platform#1172).

Standard library + PyYAML: `python3 -m unittest scripts.tests.test_openbao_group_policies_pod -v`.

The image (`alpine/k8s:1.37.1`) runs as root, so the pod has to choose a non-root UID
itself to satisfy Pod Security `restricted` (platform#1096 question 5). 65534 was measured
on the lab (2026-11-13) for both the discovery reads and `kubectl exec openbao-0` with this
Job's ServiceAccount. The image has no writable home for that UID, so the container needs
HOME=/tmp: kubectl writes its discovery cache under $HOME.
"""
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "manifests" / "openbao-group-policies.yaml"

POD_SECURITY_CONTEXT = {
    "runAsNonRoot": True,
    "runAsUser": 65534,
    "seccompProfile": {"type": "RuntimeDefault"},
}
POD_CONTAINER_SECURITY_CONTEXT = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
}


def load_cronjob():
    with MANIFEST.open() as handle:
        for document in yaml.safe_load_all(handle):
            if document and document.get("kind") == "CronJob":
                if document["metadata"]["name"] == "openbao-group-policies":
                    return document
    raise AssertionError("CronJob openbao-group-policies not found in the manifest")


def pod_spec():
    return load_cronjob()["spec"]["jobTemplate"]["spec"]["template"]["spec"]


def sync_container():
    for container in pod_spec()["containers"]:
        if container["name"] == "sync":
            return container
    raise AssertionError("container sync not found in the CronJob's pod template")


class TestOpenBaoGroupPoliciesPod(unittest.TestCase):
    def test_the_job_declares_run_as_non_root(self):
        self.assertEqual(pod_spec()["securityContext"], POD_SECURITY_CONTEXT)

    def test_the_sync_container_keeps_the_restricted_fields(self):
        self.assertEqual(
            sync_container()["securityContext"], POD_CONTAINER_SECURITY_CONTEXT
        )

    def test_the_container_has_a_writable_home(self):
        env = sync_container()["env"]
        self.assertIn({"name": "HOME", "value": "/tmp"}, env)


if __name__ == "__main__":
    unittest.main()
