#!/usr/bin/env python3
"""The permission oracle: what a person may do with a catalog, from the live objects.

`make verify-catalog-permissions` and `make bridge-replay` ask the OPA bridge the
questions Trino asks; this module says what the answer must be, so neither script
carries a hard-coded matrix (platform#365). The input is the live Catalog set and
the live group memberships; the output is one boolean per (person, catalog, verb).

    python3 scripts/lib/catalog-layout.py \
      --catalogs  <(kubectl -n stardelt get catalogs.stardelt.io -o json) \
      --principals <people.json>

`people.json` is `[{"name": "dev-finops", "groups": ["finops", "stardelt-users"]}, …]`.

The rule (ticket platform#365): a person may do a verb on a catalog when the union
of the verbs granted to their groups holds it, with the implications
`write ⇒ select ⇒ browse` and `create ⇒ browse`; a member of `stardelt-admins`
may do everything (the sync gives that group `project_admin`). Ownership is not
a data verb — the owner group gets `manage_grants` only (design §5.3).

Only Ready Catalogs are in the answer: a Catalog that is not Ready is not rendered
into Trino or the bridge, and the bridge's `allowUnmanagedCatalogs` would answer
`true` for it regardless of its grants. The skipped ones are reported separately
so a caller can say why it did not ask.
"""

import argparse
import json
import sys

ADMIN_GROUP = "stardelt-admins"
VERBS = ("browse", "select", "write", "create")
IMPLIED = {
    "write": ("select", "browse"),
    "select": ("browse",),
    "create": ("browse",),
}


def held(verbs):
    """The verbs a group's grants imply: closure over IMPLIED."""
    held_verbs = set(verbs)
    changed = True
    while changed:
        changed = False
        for verb in list(held_verbs):
            for implied in IMPLIED.get(verb, ()):
                if implied not in held_verbs:
                    held_verbs.add(implied)
                    changed = True
    return held_verbs


def expectations(catalogs_doc, principals, verbs=VERBS):
    """`{"catalogs": [...], "skipped": [...]}` with one row per person and verb."""
    catalogs = []
    skipped = []
    for item in catalogs_doc.get("items") or []:
        name = (item.get("metadata") or {}).get("name")
        if not name:
            continue
        phase = (item.get("status") or {}).get("phase")
        if phase != "Ready":
            skipped.append({"name": name, "phase": phase or "Pending"})
            continue
        spec = item.get("spec") or {}
        by_group = {}
        for grant in spec.get("grants") or []:
            group = grant.get("group")
            verb = grant.get("verb")
            if group and verb:
                by_group.setdefault(group, set()).add(verb)

        per_person = {}
        for principal in principals:
            person = principal.get("name")
            if not person:
                continue
            groups = principal.get("groups") or []
            is_admin = ADMIN_GROUP in groups
            allowed = set(verbs) if is_admin else set()
            if not is_admin:
                for group in groups:
                    allowed |= held(by_group.get(group, set()))
            per_person[person] = {
                verb: bool(is_admin or verb in allowed) for verb in verbs
            }
        catalogs.append({"name": name, "expect": per_person})

    catalogs.sort(key=lambda catalog: catalog["name"])
    return {"catalogs": catalogs, "skipped": skipped}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalogs", required=True,
                        help="`kubectl get catalogs.stardelt.io -o json` output")
    parser.add_argument("--principals", required=True,
                        help='JSON list of {"name": …, "groups": […]}, one per person')
    parser.add_argument("--verbs", default=",".join(VERBS),
                        help="comma-separated verbs to answer for (default: the four data verbs)")
    args = parser.parse_args(argv)

    verbs = tuple(verb for verb in args.verbs.split(",") if verb)
    with open(args.catalogs, encoding="utf-8") as catalogs_file:
        catalogs_doc = json.load(catalogs_file)
    with open(args.principals, encoding="utf-8") as principals_file:
        principals = json.load(principals_file)
    if not isinstance(principals, list) or not principals:
        sys.exit("catalog-layout: the principals file must be a non-empty JSON list")

    json.dump(expectations(catalogs_doc, principals, verbs), sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
