#!/usr/bin/env python3
import importlib.util
import os
import sys
import unittest


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join(REPO_ROOT, "scripts", "superset-group-roles.py")


class TestSupersetGroupRoles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Load the script as a module without triggering Superset imports
        spec = importlib.util.spec_from_file_location("superset_group_roles", SCRIPT)
        cls.mod = importlib.util.module_from_spec(spec)
        sys.modules["superset_group_roles"] = cls.mod
        spec.loader.exec_module(cls.mod)

    def test_module_importable(self):
        self.assertTrue(hasattr(self.mod, "main"))
        self.assertTrue(hasattr(self.mod, "database_name_for_catalog"))
        self.assertTrue(hasattr(self.mod, "database_uri_for_catalog"))
        self.assertTrue(hasattr(self.mod, "is_trino"))

    def test_the_uri_keeps_the_connection_and_changes_only_the_catalog(self):
        base = "trino://superset@trino.alpha.dev.stardelt.io:443/warehouse"
        self.assertEqual(
            self.mod.database_uri_for_catalog(base, "mobility"),
            "trino://superset@trino.alpha.dev.stardelt.io:443/mobility",
        )
        base_with_qs = "trino://superset@trino.alpha.dev.stardelt.io:443/warehouse?SSL=true"
        self.assertEqual(
            self.mod.database_uri_for_catalog(base_with_qs, "mobility"),
            "trino://superset@trino.alpha.dev.stardelt.io:443/mobility",
        )

    def test_a_non_trino_uri_is_refused(self):
        with self.assertRaises(ValueError):
            self.mod.database_uri_for_catalog("postgresql://user@db:5432/app", "mobility")

    def test_the_name_is_readable(self):
        self.assertEqual(self.mod.database_name_for_catalog("mobility"), "Trino Mobility")
        self.assertEqual(self.mod.database_name_for_catalog("mobility-lab"), "Trino Mobility Lab")


if __name__ == "__main__":
    unittest.main()
