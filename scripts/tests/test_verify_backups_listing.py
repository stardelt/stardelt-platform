"""Tests for the listing pod of scripts/verify-backups-all.sh (platform#466).

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. `kubectl` is replaced by a shell shim that is first on PATH: it serves one PVC and
one CronJob, makes the listing pod (`kubectl run`) fail as many times as the test asks, and records
the pod names it was given. No cluster is touched.
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
SCRIPT = REPO / "scripts" / "verify-backups-all.sh"

SHIM = """#!/usr/bin/env bash
set -u
# Fake kubectl: `-n NS get pvc|cronjob -o json` serve canned files, every other `get` fails (the CNPG
# kinds and the off-site Secret are absent), `run NAME ...` is the listing pod: it fails with 30 lines of
# noise while fewer than FAKE_FAILS runs happened, else it prints what the real pod prints.
shift 2
verb="${1-}"
case "$verb" in
  get)
    case "${2-}" in
      pvc) cat "$FAKE_DIR/pvc.json" ;;
      cronjob) cat "$FAKE_DIR/cronjob.json" ;;
      *) exit 1 ;;
    esac
    ;;
  run)
    echo "$2" >> "$FAKE_DIR/run-names"
    count="$(wc -l < "$FAKE_DIR/run-names")"
    if [ "$count" -le "${FAKE_FAILS:-0}" ]; then
      for i in $(seq 1 30); do echo "pod noise line $i"; done
      exit 1
    fi
    now="$(date -u +%s)"
    printf 'NOW %s\\nSOURCE pgdump/airflow %s dump.sql.gz\\n' "$now" "$now"
    ;;
  delete)
    echo "$3" >> "$FAKE_DIR/deleted"
    ;;
esac
"""


class ListingPod(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        shim = self.dir / "kubectl"
        shim.write_text(SHIM)
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR)
        (self.dir / "pvc.json").write_text(json.dumps({"items": [{"metadata": {"name": "data-airflow-postgresql-0"}}]}))
        (self.dir / "cronjob.json").write_text(
            json.dumps({"items": [{"metadata": {"name": "airflow-pg-dump"}, "status": {}}]})
        )

    def run_script(self, fails, **extra):
        env = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}", NAMESPACE="stardelt",
                   FAKE_DIR=str(self.dir), FAKE_FAILS=str(fails))
        env.update(extra)
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)

    def names(self):
        path = self.dir / "run-names"
        return path.read_text().split() if path.exists() else []

    def test_a_pod_that_works_is_run_once_and_nothing_is_said_about_attempts(self):
        done = self.run_script(0)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(len(self.names()), 1)
        self.assertNotIn("attempt", done.stderr)

    def test_a_pod_that_fails_once_is_tried_again_under_a_new_name_and_its_whole_output_is_shown(self):
        done = self.run_script(1)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("verify-backups-all: PASS", done.stdout)
        first, second = self.names()
        self.assertNotEqual(first, second)
        self.assertTrue(first.endswith("-1") and second.endswith("-2"), self.names())
        self.assertIn("the listing pod failed (attempt 1 of 3); its whole output:", done.stderr)
        self.assertIn("    pod noise line 1\n", done.stderr, "the first line, which `tail -n 20` used to cut off")
        self.assertIn("    pod noise line 30\n", done.stderr)
        self.assertIn(first, (self.dir / "deleted").read_text().split(), "the failed attempt's pod is deleted")

    def test_three_failures_end_with_a_sentence_that_says_what_was_not_checked(self):
        done = self.run_script(99)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(len(self.names()), 3)
        self.assertIn("the listing pod failed (attempt 3 of 3); its whole output:", done.stderr)
        self.assertIn("the listing pod failed 3 time(s), its output is printed above; this backup was NOT checked", done.stderr)
        self.assertNotIn("see above", done.stderr)

    def test_the_number_of_attempts_is_a_setting_and_is_checked(self):
        done = self.run_script(1, LIST_ATTEMPTS="1")
        self.assertEqual((done.returncode, len(self.names())), (1, 1))
        self.assertIn("failed 1 time(s)", done.stderr)
        for bad in ("0", "6", "x", ""):
            refused = self.run_script(0, LIST_ATTEMPTS=bad) if bad else None
            if refused is not None:
                self.assertEqual(refused.returncode, 2, bad)
                self.assertIn("LIST_ATTEMPTS must be a number from 1 to 5", refused.stderr)


if __name__ == "__main__":
    unittest.main()
