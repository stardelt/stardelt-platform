"""The committed Superset bundle the public demo imports (stardelt-platform#966 slice 2).

`make public-demo YES=1` imports `superset/bundles/public-demo-shop` with
`superset import-dashboards`; nobody clicks anything in Superset. The datasets list their
columns, so the import reads no metadata from Trino and the `superset` service account
needs no grant. What can be decided offline is decided here: the UUID the sync gives the
database, the catalog and schema the datasets name, the charts' datasets, the published
dashboard and the absence of a credential in any file. Standard library plus PyYAML, like
`test_notebook_labels.py`.
"""

import pathlib
import unittest

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = REPO / "superset" / "bundles" / "public-demo-shop"

# uuid5(NAMESPACE_URL, "stardelt.io/superset/database/gold") in scripts/superset-group-roles.py
# (platform#967): the same on every install, so the committed bundle can name the row.
GOLD_DATABASE_UUID = "bbb03e90-0c81-5c87-838a-0497064b6381"


def load(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def configs(directory):
    """Every YAML file under BUNDLE/directory, keyed by its path relative to the bundle."""
    root = BUNDLE / directory
    return {str(path.relative_to(BUNDLE)): load(path) for path in sorted(root.rglob("*.yaml"))}


class SupersetBundle(unittest.TestCase):
    def test_every_dataset_reads_the_shop_of_trino_gold(self):
        datasets = configs("datasets")
        self.assertTrue(datasets, "the bundle has no datasets")
        for path, dataset in datasets.items():
            with self.subTest(dataset=path):
                self.assertEqual(str(dataset["database_uuid"]), GOLD_DATABASE_UUID)
                self.assertEqual(dataset["catalog"], "gold")
                self.assertEqual(dataset["schema"], "shop")
                self.assertTrue(dataset["columns"], "a dataset lists no columns")

    def test_every_chart_points_at_a_dataset_in_the_bundle(self):
        dataset_uuids = {str(dataset["uuid"]) for dataset in configs("datasets").values()}
        charts = configs("charts")
        self.assertEqual(len(charts), 3, "the dashboard has three charts")
        for path, chart in charts.items():
            with self.subTest(chart=path):
                self.assertIn(str(chart["dataset_uuid"]), dataset_uuids)

    def test_the_dashboard_is_published_and_shows_all_three_charts(self):
        dashboards = configs("dashboards")
        self.assertEqual(len(dashboards), 1, "the bundle carries one dashboard")
        dashboard = next(iter(dashboards.values()))
        self.assertIs(dashboard["published"], True)
        self.assertEqual(dashboard["slug"], "public-demo-shop")
        chart_uuids = {str(chart["uuid"]) for chart in configs("charts").values()}
        placed = {
            str(entry["meta"]["uuid"])
            for entry in dashboard["position"].values()
            if isinstance(entry, dict) and entry.get("type") == "CHART"
        }
        self.assertEqual(placed, chart_uuids, "the position places every chart of the bundle")

    def test_no_file_carries_a_credential(self):
        self.assertTrue(BUNDLE.is_dir(), BUNDLE)
        for path in sorted(BUNDLE.rglob("*")):
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8")
            with self.subTest(file=str(path.relative_to(BUNDLE))):
                self.assertNotIn("password", text.lower())
                self.assertNotIn("XXXXXXXXXX", text)


if __name__ == "__main__":
    unittest.main()
