"""Every platform Cluster backs up through the barman-cloud plugin (platform#192).

A revert to `spec.backup.barmanObjectStore` is valid YAML and would keep
`helm lint`/yamllint green, so it is pinned here instead: CloudNativePG 1.32
removes that field, and a silent no-op archiver is what platform#59 cost.
"""
import pathlib
import unittest

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
CLUSTERS = ["cnpg-postgres.yaml", "openfga-pg.yaml", "keycloak.yaml", "nova-pg.yaml"]
SCHEDULES = ["cnpg-backup-schedule.yaml", "keycloak.yaml"]
PLUGIN = "barman-cloud.cloudnative-pg.io"


def documents(name):
    path = REPO / "manifests" / name
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


class Clusters(unittest.TestCase):
    def test_every_cluster_uses_the_plugin_and_names_its_object_store(self):
        for name in CLUSTERS:
            for document in documents(name):
                if document.get("kind") != "Cluster":
                    continue
                spec = document["spec"]
                self.assertNotIn("barmanObjectStore", spec["backup"], name)
                plugin = spec["plugins"][0]
                self.assertEqual(plugin["name"], PLUGIN, name)
                self.assertTrue(plugin["enabled"], name)
                self.assertTrue(plugin["isWALArchiver"], name)
                self.assertEqual(
                    plugin["parameters"]["barmanObjectName"],
                    f'{document["metadata"]["name"]}-backups',
                    name,
                )


class Schedules(unittest.TestCase):
    def test_every_schedule_carries_the_plugin_configuration(self):
        for name in SCHEDULES:
            for document in documents(name):
                if document.get("kind") != "ScheduledBackup":
                    continue
                spec = document["spec"]
                self.assertEqual(spec["method"], "plugin", name)
                self.assertEqual(spec["pluginConfiguration"]["name"], PLUGIN, name)
