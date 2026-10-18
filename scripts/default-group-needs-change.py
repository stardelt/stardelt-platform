#!/usr/bin/env python3
"""Is `/stardelt-users` (or the group named as argv[2]) a default group of the realm?

Reads a realm representation (argv[1]) and exits 0 when the group is already listed.
Otherwise writes the corrected realm to `<argv[1]>.new` for the caller to PUT, and
exits 1 — the shape `sync-realm-user-management.sh` wants: "no change needed" vs
"here is the new representation".
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: default-group-needs-change.py <realm.json> </group>", file=sys.stderr)
        return 2
    path, wanted = sys.argv[1], sys.argv[2]
    with open(path) as handle:
        realm = json.load(handle)
    defaults = list(realm.get("defaultGroups") or [])
    if wanted in defaults:
        return 0
    realm["defaultGroups"] = sorted({*defaults, wanted})
    with open(path + ".new", "w") as handle:
        json.dump(realm, handle)
    return 1


if __name__ == "__main__":
    sys.exit(main())
