"""The Superset analyst role grants every Trino database and dataset (platform#482).

`superset init` and the init Job converge `stardelt-analyst` to exactly one permission set. When that
set named only the first Trino database, a dashboard on a second one disappeared for every normal user
after the next init. The pure parts of the script are tested here without Superset.
"""

import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "superset-analyst-role.py"
spec = importlib.util.spec_from_file_location("superset_analyst_role", SCRIPT)
role = importlib.util.module_from_spec(spec)
spec.loader.exec_module(role)

WAREHOUSE = "[Trino Warehouse].(id:1)"
MOBILITY = "[Trino Mobility].(id:2)"
TRIPS = "[Trino Mobility].[trips](id:7)"


class TrinoDatabasesTest(unittest.TestCase):
    def test_a_trino_uri_is_recognised_whatever_its_case_and_anything_else_is_not(self):
        self.assertTrue(role.is_trino("trino://svc@trino:8080/warehouse"))
        self.assertTrue(role.is_trino("Trino://svc@trino:8080/mobility"))
        self.assertFalse(role.is_trino("postgresql://user@db:5432/app"))
        self.assertFalse(role.is_trino(None))
        self.assertFalse(role.is_trino(""))

    def test_the_script_can_be_loaded_without_superset(self):
        self.assertFalse([name for name in sys.modules if name == "superset" or name.startswith("superset.")])


class GrantsTest(unittest.TestCase):
    def test_every_database_and_every_dataset_is_granted_and_a_dataset_without_a_name_is_skipped(self):
        self.assertEqual(
            role.grants([WAREHOUSE, MOBILITY], [TRIPS, None, ""]),
            {("database_access", WAREHOUSE), ("database_access", MOBILITY), ("datasource_access", TRIPS)},
        )


class ConvergeTest(unittest.TestCase):
    def test_a_grant_on_a_second_trino_database_survives_the_convergence(self):
        granted = role.grants([WAREHOUSE, MOBILITY], [TRIPS])
        want = {("can_read", "Dashboard")}
        current = want | granted
        self.assertEqual(role.converge(current, want, granted), ([], []))

    def test_a_missing_permission_is_added_whether_it_is_wanted_or_granted(self):
        granted = role.grants([MOBILITY], [])
        want = {("can_read", "Dashboard")}
        self.assertEqual(
            role.converge(set(), want, granted),
            ([("can_read", "Dashboard"), ("database_access", MOBILITY)], []),
        )

    def test_drift_is_removed(self):
        want = {("can_read", "Dashboard")}
        current = want | {("can_write", "Database"), ("all_database_access", "all_database_access")}
        self.assertEqual(
            role.converge(current, want, set()),
            ([], [("all_database_access", "all_database_access"), ("can_write", "Database")]),
        )


if __name__ == "__main__":
    unittest.main()
