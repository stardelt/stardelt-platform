"""Tests for the OpenBao group-policy sync's discovery (platform#483).

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. `kubectl` is a shell shim that serves canned List documents; the connections
writer is a shim that records the groups it was called with. No cluster is touched.

The bug these tests pin down: the first implementation read `owner` from a Catalog grant, but the
grant field is `group`, so a group that only had a Catalog (no Pipeline) never got a policy.
"""
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "sync-openbao-group-policies.sh"

KUBECTL = """#!/usr/bin/env bash
set -u
# fake kubectl: `-n NS get pod|secret` says present, the three List kinds serve canned files.
shift 2
[ "${1-}" = get ] || exit 1
case "${2-}" in
  pod) exit 0 ;;
  secret) [ "${FAKE_NO_SECRET-}" = 1 ] && exit 1; exit 0 ;;
  catalogs) cat "$FAKE_DIR/catalogs.json" ;;
  pipelines) cat "$FAKE_DIR/pipelines.json" ;;
  serviceprincipals) cat "$FAKE_DIR/serviceprincipals.json" ;;
  *) exit 1 ;;
esac
"""

CONNECTIONS = """#!/usr/bin/env bash
set -u
printf '%s\\n' "${OWNER_GROUPS-}" > "$FAKE_DIR/connections-args"
"""


def doc(items):
    return json.dumps({"apiVersion": "stardelt.io/v1alpha1", "kind": "List", "items": items})


class Discovery(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        kubectl = self.dir / "kubectl"
        kubectl.write_text(KUBECTL)
        kubectl.chmod(kubectl.stat().st_mode | stat.S_IXUSR)
        connections = self.dir / "connections.sh"
        connections.write_text(CONNECTIONS)
        connections.chmod(connections.stat().st_mode | stat.S_IXUSR)
        self.connections = connections
        # A Catalog grant's field is `group` (verbs are groups); `spec.owner` is the catalog's
        # owner group, not a grant, and stardelt-users/stardelt-admins are excluded.
        (self.dir / "catalogs.json").write_text(
            doc(
                [
                    {
                        "metadata": {"name": "mobility"},
                        "spec": {
                            "owner": "stardelt-admins",
                            "grants": [
                                {"group": "mobility-analytics", "verb": "browse"},
                                {"group": "stardelt-users", "verb": "browse"},
                                {"group": "stardelt-admins", "verb": "browse"},
                                {"verb": "browse"},
                            ],
                        },
                    }
                ]
            )
        )
        (self.dir / "pipelines.json").write_text(
            doc([{"metadata": {"name": "p"}, "spec": {"ownerGroup": "retail-analytics"}}])
        )
        (self.dir / "serviceprincipals.json").write_text(
            doc([{"metadata": {"name": "s"}, "spec": {"ownerGroup": "finance-analytics"}}])
        )

    def run_script(self, **extra):
        env = dict(
            os.environ,
            PATH=f"{self.dir}:{os.environ['PATH']}",
            FAKE_DIR=str(self.dir),
            NAMESPACE="stardelt",
            CONNECTIONS=str(self.connections),
        )
        env.update(extra)
        return subprocess.run(
            ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60
        )

    def test_catalog_grants_and_owner_groups_are_all_discovered_sorted_and_excluded(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "discovered groups: finance-analytics mobility-analytics retail-analytics",
            result.stdout,
        )
        self.assertEqual(
            (self.dir / "connections-args").read_text().split(),
            ["finance-analytics", "mobility-analytics", "retail-analytics"],
        )

    def test_no_store_is_a_clean_exit_and_no_writer_call(self):
        result = self.run_script(FAKE_NO_SECRET="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("openbao-init not found, exiting cleanly", result.stdout)
        self.assertFalse((self.dir / "connections-args").exists())

    def test_no_groups_still_wires_the_baseline_with_an_empty_list(self):
        (self.dir / "catalogs.json").write_text(doc([]))
        (self.dir / "pipelines.json").write_text(doc([]))
        (self.dir / "serviceprincipals.json").write_text(doc([]))
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no owner groups discovered", result.stdout)
        self.assertEqual((self.dir / "connections-args").read_text().strip(), "")


if __name__ == "__main__":
    unittest.main()
