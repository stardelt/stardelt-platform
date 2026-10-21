"""Unit tests for the permission oracle (scripts/lib/catalog-layout.py, platform#365).

Standard library only, like the module: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. They pin the rule the live probe and the bridge replay share — the
union of a person's groups' grants with `write ⇒ select ⇒ browse` and
`create ⇒ browse`, admins everywhere, Ready Catalogs only — without a cluster.
"""
import importlib.util
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "lib" / "catalog-layout.py"
_spec = importlib.util.spec_from_file_location("catalog_layout", MODULE)
catalog_layout = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(catalog_layout)


def catalog(name, grants, phase="Ready"):
    return {
        "metadata": {"name": name},
        "spec": {"grants": [{"group": group, "verb": verb} for group, verb in grants]},
        "status": {"phase": phase},
    }


def doc(*items):
    return {"items": list(items)}


UNIFORM = [("stardelt-users", verb) for verb in ("browse", "select", "write", "create")]
FINOPS = [("finops", "browse"), ("finops", "select"), ("finops", "write"), ("finops", "create")]

PEOPLE = [
    {"name": "dev-finops", "groups": ["stardelt-users", "finops"]},
    {"name": "dev-outsider", "groups": ["stardelt-users"]},
    {"name": "admin", "groups": ["stardelt-admins"]},
]


class HeldVerbs(unittest.TestCase):
    def test_write_implies_select_implies_browse(self):
        self.assertEqual(catalog_layout.held({"write"}), {"write", "select", "browse"})

    def test_create_implies_browse(self):
        self.assertEqual(catalog_layout.held({"create"}), {"create", "browse"})

    def test_manage_is_not_a_data_verb(self):
        self.assertEqual(catalog_layout.held({"manage"}), {"manage"})


class Expectations(unittest.TestCase):
    def test_uniform_grants_give_every_person_everything(self):
        result = catalog_layout.expectations(doc(catalog("gold", UNIFORM)), PEOPLE)
        self.assertEqual(result["skipped"], [])
        for person in ("dev-finops", "dev-outsider"):
            self.assertEqual(
                result["catalogs"][0]["expect"][person],
                {"browse": True, "select": True, "write": True, "create": True},
            )

    def test_differentiated_grants_follow_the_groups(self):
        result = catalog_layout.expectations(
            doc(catalog("finance", FINOPS + [("analytics", "browse"), ("analytics", "select")])),
            PEOPLE,
        )
        expect = result["catalogs"][0]["expect"]
        # finops has all four verbs; select/write imply browse but not each other.
        self.assertEqual(expect["dev-finops"], {"browse": True, "select": True, "write": True, "create": True})
        # dev-outsider is only in stardelt-users, which this catalog does not grant.
        self.assertEqual(expect["dev-outsider"], {"browse": False, "select": False, "write": False, "create": False})

    def test_browse_only_group_gets_no_implied_select(self):
        result = catalog_layout.expectations(
            doc(catalog("product", FINOPS + [("stardelt-users", "browse")])),
            PEOPLE,
        )
        self.assertEqual(
            result["catalogs"][0]["expect"]["dev-outsider"],
            {"browse": True, "select": False, "write": False, "create": False},
        )

    def test_admin_is_always_allowed(self):
        result = catalog_layout.expectations(doc(catalog("bronze", [])), PEOPLE)
        self.assertEqual(
            result["catalogs"][0]["expect"]["admin"],
            {"browse": True, "select": True, "write": True, "create": True},
        )
        self.assertEqual(
            result["catalogs"][0]["expect"]["dev-outsider"],
            {"browse": False, "select": False, "write": False, "create": False},
        )

    def test_owner_group_is_not_a_data_grant(self):
        item = catalog("finance", [])
        item["spec"]["owner"] = "finops"
        result = catalog_layout.expectations(doc(item), PEOPLE)
        self.assertEqual(
            result["catalogs"][0]["expect"]["dev-finops"],
            {"browse": False, "select": False, "write": False, "create": False},
        )

    def test_not_ready_catalogs_are_skipped(self):
        result = catalog_layout.expectations(
            doc(catalog("gold", UNIFORM), catalog("pending", UNIFORM, phase="Pending")),
            PEOPLE,
        )
        self.assertEqual([entry["name"] for entry in result["catalogs"]], ["gold"])
        self.assertEqual(result["skipped"], [{"name": "pending", "phase": "Pending"}])

    def test_catalogs_are_sorted_by_name(self):
        result = catalog_layout.expectations(
            doc(catalog("silver", UNIFORM), catalog("bronze", UNIFORM)),
            PEOPLE,
        )
        self.assertEqual([entry["name"] for entry in result["catalogs"]], ["bronze", "silver"])


if __name__ == "__main__":
    unittest.main()
