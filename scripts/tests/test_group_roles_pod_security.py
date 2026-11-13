"""Tests for the two group-roles CronJobs' pod security contexts (platform#1176).

Standard library + PyYAML: `python3 -m unittest scripts.tests.test_group_roles_pod_security -v`.

Both images already run non-root (measured on the lab 2026-11-13: Airflow as 50000,
Superset as 1000:1000), so the pods only have to declare the UID to satisfy Pod Security
`restricted` (platform#1096 question 5).  The container-level fields stay as they are.
"""
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]

CONTAINER_SECURITY_CONTEXT = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
}


def pod_security_context(manifest_name, cron_job_name):
    path = REPO / "manifests" / manifest_name
    with path.open() as handle:
        for document in yaml.safe_load_all(handle):
            if not document or document.get("kind") != "CronJob":
                continue
            if document["metadata"]["name"] != cron_job_name:
                continue
            spec = document["spec"]["jobTemplate"]["spec"]["template"]["spec"]
            return spec["securityContext"], spec["containers"]
    raise AssertionError(f"CronJob {cron_job_name} not found in {manifest_name}")


def pod_context(manifest_name, cron_job_name):
    return pod_security_context(manifest_name, cron_job_name)[0]


def sync_container(manifest_name, cron_job_name):
    for container in pod_security_context(manifest_name, cron_job_name)[1]:
        if container["name"] == "sync":
            return container
    raise AssertionError(f"container sync not found in CronJob {cron_job_name}")


class TestGroupRolesPodSecurity(unittest.TestCase):
    def test_the_airflow_pod_declares_run_as_non_root(self):
        self.assertEqual(
            pod_context("airflow-group-roles.yaml", "airflow-group-roles"),
            {
                "runAsNonRoot": True,
                "runAsUser": 50000,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
        )

    def test_the_airflow_container_keeps_the_restricted_fields(self):
        self.assertEqual(
            sync_container("airflow-group-roles.yaml", "airflow-group-roles")[
                "securityContext"
            ],
            CONTAINER_SECURITY_CONTEXT,
        )

    def test_the_superset_pod_declares_run_as_non_root(self):
        self.assertEqual(
            pod_context("superset-group-roles.yaml", "superset-group-roles"),
            {
                "runAsNonRoot": True,
                "runAsUser": 1000,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
        )

    def test_the_superset_container_keeps_the_restricted_fields(self):
        self.assertEqual(
            sync_container("superset-group-roles.yaml", "superset-group-roles")[
                "securityContext"
            ],
            CONTAINER_SECURITY_CONTEXT,
        )


if __name__ == "__main__":
    unittest.main()
