"""Unit tests for scripts/public-demo.sh (stardelt-platform#896): everything it does before it talks to Keycloak.

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v` runs them in
CI. `kubectl` is a shell shim first on PATH that records every call, so no cluster is touched and no credential
exists anywhere in the test. The Keycloak half (the person, its memberships, roles and password) and the live
steps (grants, apply, configmap, access sync) are proved on a cluster by running `make public-demo YES=1`; what
can be decided offline is decided here: the checks, the plan, the kill switch and the manifest it applies.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "public-demo.sh"

SHIM = """#!/usr/bin/env bash
set -euo pipefail
# Fake kubectl: every call is appended to FAKE_LOG; `get catalogs.stardelt.io NAME` fails for the names in
# FAKE_MISSING (space separated) and answers a Catalog without grants; `get serviceprincipals...` answers ready;
# anything else that writes is recorded and answered with success.
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
  case "${args[*]}" in
    *"-o json") printf '{"spec":{"grants":[]}}' ;;
  esac
  exit 0
fi
if [ "${args[0]-}" = get ] && [ "${args[1]-}" = serviceprincipals.stardelt.io ]; then
  printf 'true'
fi
if [ "${args[0]-}" = get ] && [ "${args[1]-}" = configmap ] && [ "${args[2]-}" = keycloak-env ]; then
  exit 1
fi
# The nightly reset's CronJob status: `-o jsonpath={.status.lastSuccessfulTime}` answers
# FAKE_LAST_SUCCESS (empty when unset), so row 12 can be driven from both sides.
if [ "${args[0]-}" = get ] && { [ "${args[1]-}" = cronjobs.batch ] || [ "${args[1]-}" = cronjob ]; }; then
  case "${args[*]}" in
    *lastSuccessfulTime*) printf '%s' "${FAKE_LAST_SUCCESS:-}" ;;
  esac
  exit 0
fi
exit 0
"""


class PublicDemo(unittest.TestCase):
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
        for name in ("YES", "REALM"):
            env.pop(name, None)
        env.update(extra)
        return subprocess.run(["bash", str(SCRIPT), *arguments], env=env, capture_output=True, text=True, timeout=60)

    def calls(self):
        return [line for line in self.log.read_text().splitlines() if line]

    def test_without_yes_it_prints_the_plan_and_the_warning_and_writes_nothing(self):
        done = self.run_script()
        self.assertEqual(done.returncode, 1)
        self.assertIn("WARNING: EVERY SCHEMA IN bronze, silver AND gold BECOMES READABLE BY ANYONE ON THE INTERNET", done.stdout)
        self.assertIn("would: create the person demo", done.stdout)
        self.assertIn("would: grant visitors browse and select on bronze silver gold", done.stdout)
        self.assertIn("would: apply the Catalog playground and the SqlWarehouse demo (xs)", done.stdout)
        self.assertIn("re-run with YES=1", done.stdout)
        self.assertEqual(
            self.calls(),
            [f"-n stardelt get catalogs.stardelt.io {name}" for name in ("bronze", "silver", "gold")]
            + ["-n stardelt get serviceprincipals.stardelt.io pipeline-demo -o jsonpath={.status.ready}"],
            "the plan reads three Catalogs and one ServicePrincipal, and writes nothing",
        )

    def test_a_missing_catalog_is_named_and_nothing_is_written(self):
        done = self.run_script(YES="1", FAKE_MISSING="silver")
        self.assertEqual(done.returncode, 1)
        self.assertIn("the Catalogs silver do not exist in namespace stardelt", done.stderr)
        self.assertIn("nothing was changed", done.stderr)
        writes = [call for call in self.calls() if " apply " in call or " patch " in call]
        self.assertEqual(writes, [], "a missing Catalog is found before any write")

    def test_the_manifest_is_the_catalog_and_the_warehouse_and_changes_nothing(self):
        done = self.run_script("--manifest")
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertIn("kind: Catalog", done.stdout)
        self.assertIn("name: playground", done.stdout)
        self.assertIn("kind: SqlWarehouse", done.stdout)
        self.assertIn("size: xs", done.stdout)
        self.assertIn('memoryShare: "10%"', done.stdout)
        self.assertNotIn("stardelt-users", done.stdout)
        self.assertEqual(self.calls(), [], "--manifest asks nobody")

    def test_the_script_parses(self):
        done = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, done.stderr), (0, ""))

    def test_the_kill_switch_without_yes_prints_the_plan_and_asks_nobody(self):
        done = self.run_script("--off")
        self.assertEqual(done.returncode, 1)
        self.assertIn("would: disable demo", done.stdout)
        self.assertEqual(self.calls(), [])

    def test_the_script_resets_a_permanent_password_and_removes_the_default_role(self):
        text = SCRIPT.read_text()
        self.assertIn('"temporary":false', text)
        self.assertIn("default-roles-stardelt", text)

    def test_row_12_reports_a_reset_that_last_succeeded_two_days_ago(self):
        stale = (datetime.now(timezone.utc) - timedelta(hours=48)).strftime("%Y-%m-%dT%H:%M:%SZ")
        done = self.run_script("--check", FAKE_LAST_SUCCESS=stale)
        self.assertEqual(done.returncode, 1)
        self.assertIn(f"MISSING  12  the last successful demo reset was {stale}", done.stdout)

    def test_row_12_passes_when_the_reset_succeeded_an_hour_ago(self):
        fresh = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        done = self.run_script("--check", FAKE_LAST_SUCCESS=fresh)
        self.assertIn(f"PASS     12  the nightly reset last succeeded at {fresh}", done.stdout)


if __name__ == "__main__":
    unittest.main()
