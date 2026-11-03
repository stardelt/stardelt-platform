"""Dashboard visibility follows the catalog group role (platform#508)."""

import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "superset-group-roles.py"
spec = importlib.util.spec_from_file_location("superset_group_roles", SCRIPT)
roles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roles)


class DashboardRolesTest(unittest.TestCase):
    def test_a_dashboard_on_one_catalog_is_visible_to_that_catalog_group_only(self):
        chart_databases = {"[Trino Mobility].(id:2)"}
        role_databases = {
            "stardelt-group-mobility-analytics": {chart_databases.pop() if False else "[Trino Mobility].(id:2)"},
            "stardelt-group-retail-analytics": {"[Trino Retail].(id:4)"},
        }
        # build properly
        role_databases = {
            "stardelt-group-mobility-analytics": {"[Trino Mobility].(id:2)"},
            "stardelt-group-retail-analytics": {"[Trino Retail].(id:4)"},
        }
        self.assertEqual(roles.dashboard_roles({"[Trino Mobility].(id:2)"}, role_databases), ["stardelt-group-mobility-analytics"])

    def test_a_dashboard_spanning_two_catalogs_is_admin_only(self):
        chart_databases = {"[Trino Mobility].(id:2)", "[Trino Retail].(id:4)"}
        role_databases = {
            "stardelt-group-mobility-analytics": {"[Trino Mobility].(id:2)"},
            "stardelt-group-retail-analytics": {"[Trino Retail].(id:4)"},
        }
        self.assertEqual(roles.dashboard_roles(chart_databases, role_databases), [])

    def test_a_dashboard_without_charts_is_admin_only(self):
        self.assertEqual(roles.dashboard_roles(set(), {}), [])
