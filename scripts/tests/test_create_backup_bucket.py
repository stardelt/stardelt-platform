"""Unit tests for scripts/create-backup-bucket.sh and its place in `make step-storage` (platform#462).

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. `kubectl` is replaced by a shell shim that is first on PATH and records the Pod the
script applies, so no cluster is touched and no credential exists anywhere in the test.
"""
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "create-backup-bucket.sh"

SHIM = """#!/usr/bin/env bash
set -euo pipefail
# Fake kubectl: `get secret` answers by FAKE_SECRET_PRESENT, `apply -f FILE` copies the file to
# FAKE_APPLIED, `wait` succeeds unless FAKE_WAIT_FAIL is set, `logs` prints one canned line.
args=()
file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n | --namespace) shift 2 ;;
    -f | --filename) file="$2"; shift 2 ;;
    --timeout=* | --for=*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
verb="${args[0]-}"
case "$verb" in
  get) [ "${FAKE_SECRET_PRESENT:-1}" = 1 ] ;;
  apply) cp "$file" "$FAKE_APPLIED" ;;
  wait) [ -z "${FAKE_WAIT_FAIL:-}" ] ;;
  logs) echo "› bucket lakehouse-backup: present (fake)" ;;
  delete) ;;
  *) echo "fake kubectl: unsupported invocation: $verb" >&2; exit 2 ;;
esac
"""


class CreateBackupBucket(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        shim = self.dir / "kubectl"
        shim.write_text(SHIM)
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR)
        self.applied = self.dir / "applied.yaml"

    def run_script(self, **extra):
        env = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}", NAMESPACE="stardelt",
                   FAKE_APPLIED=str(self.applied))
        env.update(extra)
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)

    def test_creates_the_bucket_and_does_not_turn_versioning_on(self):
        done = self.run_script()
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertIn("bucket lakehouse-backup", done.stdout)
        pod = self.applied.read_text()
        self.assertIn('create-bucket --bucket "lakehouse-backup"', pod)
        self.assertNotIn("put-bucket-versioning", pod, "the archive is append-only: no second copy of every object")
        self.assertIn("namespace: stardelt", pod)
        self.assertIn("automountServiceAccountToken: false", pod)

    def test_credentials_come_from_the_secret_never_as_literals(self):
        self.run_script()
        pod = self.applied.read_text()
        self.assertEqual(pod.count("secretKeyRef"), 4)
        self.assertEqual(re.findall(r"^\s+value:", pod, flags=re.M), [], "no literal value in the Pod")

    def test_a_missing_secret_stops_before_any_pod(self):
        done = self.run_script(FAKE_SECRET_PRESENT="0")
        self.assertEqual(done.returncode, 1)
        self.assertIn("Secret stardelt-s3-creds is missing", done.stderr)
        self.assertFalse(self.applied.exists(), "no Pod is created without the credentials")

    def test_a_pod_that_does_not_succeed_fails_the_script(self):
        done = self.run_script(FAKE_WAIT_FAIL="1")
        self.assertEqual(done.returncode, 1)
        self.assertIn("the S3 pod did not succeed", done.stderr)


@unittest.skipUnless(shutil.which("make"), "make is not installed")
class StepStorage(unittest.TestCase):
    def test_the_storage_step_creates_the_bucket_before_it_applies_the_archive_job(self):
        done = subprocess.run(["make", "-n", "step-storage", "NAMESPACE=stardelt"], cwd=REPO,
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        out = done.stdout
        notebooks = out.index("create-notebooks-bucket.sh")
        bucket = out.index("create-backup-bucket.sh")
        job = out.index("kubectl apply -f manifests/object-store-backup.yaml")
        self.assertLess(notebooks, bucket)
        self.assertLess(bucket, job, "a CronJob that syncs into a missing bucket fails on every run")


if __name__ == "__main__":
    unittest.main()
