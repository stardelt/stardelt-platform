#!/usr/bin/env python3
"""Helm post-renderer: dedupe name-keyed list entries (env, ports, volumeMounts)
so later entries override earlier ones — restoring helm v3 behavior under v4's
server-side apply.

Some upstream charts hardcode env vars in their _helpers.tpl and append
user-provided env after them. Under helm v3 the duplicates were tolerated
(kube applied last-wins); helm v4's SSA path now fails with `duplicate entries
for key`. This renderer strips earlier duplicates.
"""
from __future__ import annotations
import sys
import yaml

KEYED_LISTS = {"env", "ports", "volumeMounts", "volumeDevices"}


def dedupe(obj):
    if isinstance(obj, dict):
        for k, v in list(obj.items()):
            if k in KEYED_LISTS and isinstance(v, list):
                seen = {}
                for item in v:
                    if isinstance(item, dict) and "name" in item:
                        seen[item["name"]] = item
                    else:
                        # non-keyed entry — keep as-is under a synthetic key
                        seen[id(item)] = item
                obj[k] = list(seen.values())
            else:
                dedupe(v)
    elif isinstance(obj, list):
        for item in obj:
            dedupe(item)
    return obj


def main():
    docs = list(yaml.safe_load_all(sys.stdin))
    out = [dedupe(d) for d in docs if d is not None]
    yaml.safe_dump_all(out, sys.stdout, default_flow_style=False, sort_keys=False)


if __name__ == "__main__":
    main()
