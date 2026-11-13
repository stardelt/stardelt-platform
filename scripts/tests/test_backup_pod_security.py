"""Tests for the object-store backup CronJob's pod security context (platform#1177).

Standard library + PyYAML: `python3 -m unittest scripts.tests.test_backup_pod_security -v`.

The image (`amazon/aws-cli:2.17.0`) runs as root, so the pod has to choose a non-root UID
itself to satisfy Pod Security `restricted` (platform#1096 question 5). 65534 was measured
on the lab (2026-11-13) for listing and syncing the bucket. The image has no writable home
for that UID, so the container needs HOME=/tmp: aws-cli writes its cache under $HOME.
"""
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "manifests" / "object-store-backup.yaml"

POD_SECURITY_CONTEXT = {
    "runAsNonRoot": True,
    "runAsUser": 65534,
    "runAsGroup": 65534,
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
                if document["metadata"]["name"] == "lakehouse-backup":
                    return document
    raise AssertionError("CronJob lakehouse-backup not found in the manifest")


def pod_spec():
    return load_cronjob()["spec"]["jobTemplate"]["spec"]["template"]["spec"]


def sync_container():
    for container in pod_spec()["containers"]:
        if container["name"] == "s3-sync":
            return container
    raise AssertionError("container s3-sync not found in the CronJob's pod template")


class TestBackupPodSecurity(unittest.TestCase):
    def test_the_pod_declares_run_as_non_root(self):
        self.assertEqual(pod_spec()["securityContext"], POD_SECURITY_CONTEXT)

    def test_the_container_declares_the_restricted_fields(self):
        self.assertEqual(
            sync_container()["securityContext"], POD_CONTAINER_SECURITY_CONTEXT
        )

    def test_the_container_has_a_writable_home(self):
        env = sync_container()["env"]
        self.assertIn({"name": "HOME", "value": "/tmp"}, env)


if __name__ == "__main__":
    unittest.main()
