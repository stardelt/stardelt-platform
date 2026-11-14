"""The identity checker follows the notebook it verifies (platform#1323).

`scripts/verify-notebook-identity.py` asserts against the notebook's output. The notebook's
contract changed with platform#1317 (no `warehouse` catalog, no drop, a `quickstart_smoke`
round-trip), so the script's checks must name that contract — and its negative must remove BOTH
the pod's token and the hub's renewal token, or `stardelt._token()` mints a new one through
`JUPYTERHUB_API_TOKEN` and the run never reaches Trino's 401.
"""

import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "verify-notebook-identity.py"
NOTEBOOK = REPO / "images" / "jupyter" / "notebooks" / "warehouse-quickstart.ipynb"


class VerifyNotebookIdentityTest(unittest.TestCase):
    def setUp(self):
        self.source = SCRIPT.read_text(encoding="utf-8")

    def test_it_does_not_assert_the_removed_warehouse_query(self):
        self.assertNotIn("warehouse.covid.covid_summary", self.source)

    def test_it_asserts_the_quickstart_smoke_round_trip(self):
        self.assertIn("^Catalog: (shared|playground)$", self.source)
        self.assertIn("quickstart_smoke: 3 rows written and read back", self.source)
        notebook = NOTEBOOK.read_text(encoding="utf-8")
        self.assertIn("quickstart_smoke", notebook)

    def test_the_negative_removes_the_hub_token_too(self):
        compact = re.sub(r"\s+", "", self.source)
        self.assertIn('"env","-u","TRINO_TOKEN","-u","JUPYTERHUB_API_TOKEN"', compact)
