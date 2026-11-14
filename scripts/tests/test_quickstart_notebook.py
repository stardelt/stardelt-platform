"""The seeded quickstart notebook runs for the person who gets it (platform#1317).

Every spawn copies `images/jupyter/notebooks/warehouse-quickstart.ipynb` into the
user's home, so the notebook must work for a `stardelt-users` member and for the
public demo's `visitors` — not only for an administrator. Two rules make the
difference, and both are checked here without a cluster:

* it must not touch the administrators-only `warehouse` catalog;
* it must not drop a table — since platform#1130 a `write` grant is Lakekeeper
  `write`, and drop/rename need `modify`, which only administrators hold.

The identity cells are the proof the notebook carries, so they must stay.
"""

import json
import pathlib
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
NOTEBOOK = REPO / "images" / "jupyter" / "notebooks" / "warehouse-quickstart.ipynb"


def _cells():
    with open(NOTEBOOK, encoding="utf-8") as handle:
        return json.load(handle)["cells"]


def _sources():
    return ["".join(cell["source"]) for cell in _cells()]


class QuickstartNotebookTest(unittest.TestCase):
    def test_it_never_drops_a_table(self):
        for index, source in enumerate(_sources()):
            with self.subTest(cell=index):
                self.assertNotIn("drop table", source.lower())
                self.assertNotIn('mode="overwrite"', source)

    def test_it_never_names_the_administrators_catalog(self):
        for index, source in enumerate(_sources()):
            with self.subTest(cell=index):
                self.assertNotIn("warehouse.", source)
                self.assertNotIn("FROM warehouse", source)

    def test_it_picks_a_catalog_its_audience_may_write(self):
        sources = _sources()
        self.assertTrue(
            [source for source in sources if '("shared", "playground")' in source],
            "no cell picks between `shared` and `playground`",
        )
        self.assertTrue(
            [source for source in sources if "SHOW CATALOGS" in source],
            "no cell asks Trino which catalogs the account can see",
        )

    def test_the_identity_cells_are_unchanged(self):
        sources = _sources()
        self.assertIn("def sql(query)", sources[1])
        self.assertIn("SELECT current_user AS signed_in_as", sources[2])
        self.assertIn("IDENTITIES", sources[2])


if __name__ == "__main__":
    unittest.main()
