"""Unit tests for scripts/demo-access.sh (stardelt-platform#469): everything it does before it talks to Keycloak.

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v` runs them in
CI. `kubectl` is a shell shim first on PATH that records every call, so no cluster is touched and no credential
exists anywhere in the test. The Keycloak half (group, members, principal, wait, access sync) is proved on a
cluster by running `make demo-access YES=1` twice; what can be decided offline is decided here: the checks, the
plan, and the manifest Nova will look for.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "demo-access.sh"

SHIM = """#!/usr/bin/env bash
set -euo pipefail
# Fake kubectl: every call is appended to FAKE_LOG; `get catalogs.stardelt.io NAME` fails for the names in
# FAKE_MISSING (space separated); anything else that writes is recorded and answered with success.
echo "$*" >>"$FAKE_LOG"
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n | --namespace) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "${args[0]-}" = get ] && [ "${args[1]-}" = catalogs.stardelt.io ]; then
  for name in ${FAKE_MISSING:-}; do
    [ "${args[2]-}" != "$name" ] || exit 1
  done
fi
exit 0
"""


class DemoAccess(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        shim = self.dir / "kubectl"
        shim.write_text(SHIM)
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR)
        self.log = self.dir / "kubectl.log"
        self.log.write_text("")

    def run_script(self, *arguments, **extra):
        env = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}", NAMESPACE="stardelt", FAKE_LOG=str(self.log))
        env.pop("GROUP", None)
        env.pop("MEMBERS", None)
        env.pop("YES", None)
        env.update(extra)
        return subprocess.run(["bash", str(SCRIPT), *arguments], env=env, capture_output=True, text=True, timeout=60)

    def calls(self):
        return [line for line in self.log.read_text().splitlines() if line]

    def test_the_manifest_is_the_resource_nova_looks_for_and_changes_nothing(self):
        done = self.run_script("--manifest")
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertIn("kind: ServicePrincipal", done.stdout)
        self.assertIn("name: pipeline-demo", done.stdout)
        self.assertIn("ownerGroup: demo", done.stdout)
        self.assertIn("purpose: pipeline", done.stdout)
        self.assertEqual(self.calls(), [], "--manifest asks nobody")
        shop = self.run_script("--manifest", GROUP="shop", NAMESPACE="other")
        self.assertIn("name: pipeline-shop", shop.stdout)
        self.assertIn("ownerGroup: shop", shop.stdout)
        self.assertIn("namespace: other", shop.stdout)

    def test_a_group_that_cannot_be_part_of_a_kubernetes_name_is_refused_before_anything_is_asked(self):
        for bad in ("Demo", "demo team", "-demo", "demo-", "a" * 41, "demo/x"):
            done = self.run_script(GROUP=bad)
            self.assertEqual(done.returncode, 1, bad)
            self.assertIn("GROUP must be 1 to 40 lower-case letters, digits and dashes", done.stderr, bad)
        self.assertEqual(self.calls(), [])

    def test_a_member_name_that_is_not_a_user_name_is_refused(self):
        done = self.run_script(MEMBERS="ada,bo; rm -rf /")
        self.assertEqual(done.returncode, 1)
        self.assertIn("MEMBERS must be a comma-separated list of user names", done.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_layer_catalogs_are_named_and_nothing_is_changed(self):
        done = self.run_script(YES="1", FAKE_MISSING="silver gold")
        self.assertEqual(done.returncode, 1)
        self.assertIn("the Catalogs silver gold do not exist in namespace stardelt", done.stderr)
        self.assertIn("nothing was changed", done.stderr)
        self.assertTrue(all(call.startswith("-n stardelt get catalogs.stardelt.io") for call in self.calls()), self.calls())

    def test_without_yes_it_prints_the_plan_asks_only_the_catalogs_and_exits_1(self):
        done = self.run_script(MEMBERS="ada,bo")
        self.assertEqual(done.returncode, 1)
        self.assertIn("catalogs bronze silver gold: present", done.stdout)
        self.assertIn("would: ensure group demo, add members (ada,bo), converge principal pipeline-demo", done.stdout)
        self.assertIn("re-run with YES=1", done.stdout)
        self.assertEqual(
            self.calls(),
            [f"-n stardelt get catalogs.stardelt.io {name}" for name in ("bronze", "silver", "gold")],
            "the plan reads three Catalogs and writes nothing",
        )

    def test_an_unknown_argument_is_refused(self):
        done = self.run_script("--delete")
        self.assertEqual(done.returncode, 1)
        self.assertIn("unexpected argument '--delete' (accepted: --manifest)", done.stderr)


if __name__ == "__main__":
    unittest.main()
