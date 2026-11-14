"""Unit tests for scripts/demo-reset-grant.sh (stardelt-platform#1316).

Standard library only, no network and no cluster, like the other tests here:
`python3 -m unittest discover -s scripts/tests -v` runs them in CI. What is decided here
is what a reader of the three files can check without a cluster: the grant is scoped to
the principal's user and never to a role (access-sync would revert a role grant), the
subject and the warehouse id come from the two objects that own them, and the public-demo
report has the row that asks the same question. The grant itself is proved on the cluster
by `make demo-reset-now` dropping the leftovers.
"""
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
GRANT = SCRIPTS / "demo-reset-grant.sh"
PUBLIC_DEMO = SCRIPTS / "public-demo.sh"


class Grant(unittest.TestCase):
    def test_the_grant_is_scoped_to_the_user_not_the_role(self):
        text = GRANT.read_text()
        self.assertTrue(
            '"type": "modify", "user": ' in text or '"type":"modify","user":' in text,
            "the writes payload does not name the modify type and a user",
        )
        self.assertNotIn('"role":', text, "a warehouse grant to a role is reverted by access-sync")

    def test_the_subject_comes_from_the_principal_secret(self):
        text = GRANT.read_text()
        self.assertIn("secret sp-pipeline-demo", text)
        self.assertIn("jsonpath='{.data.subject}'", text)

    def test_the_warehouse_id_comes_from_the_catalog_status(self):
        text = GRANT.read_text()
        self.assertIn('get catalog "$WAREHOUSE_NAME"', text)
        self.assertIn("CatalogReady", text)


class PublicDemoCheck(unittest.TestCase):
    def test_public_demo_check_renders_row_13(self):
        text = PUBLIC_DEMO.read_text()
        self.assertIn("13) check_13 || rc=1 ;;", text)
        self.assertIn("\n  render 13\n", text)
        check = text.split("check_13() {", 1)[1].split("\n  }", 1)[0]
        self.assertIn("demo-reset-grant.sh --check", check)


if __name__ == "__main__":
    unittest.main()
