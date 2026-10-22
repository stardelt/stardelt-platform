"""Unit tests for scripts/recovery-secrets.sh (platform#396).

Standard library only, like the other tests here: `python3 -m unittest discover
-s scripts/tests -v` runs them in CI.

The real `openssl` is used — the point of several tests is that what lands on
disk cannot be read back without the passphrase. `kubectl` is replaced by a
shell shim that is first on PATH, serves canned Secret JSON from a directory and
records the document an apply receives, so no cluster is touched and no value
ever leaves the test.
"""
import base64
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "recovery-secrets.sh"
REPO = Path(__file__).resolve().parents[2]

PASSPHRASE = "correct horse battery staple"  # 28 chars, above the 16 minimum

# A value no other field in a Secret could produce: grepping for it (or for its
# base64 form) in the exported file must find nothing.
S3_SECRET = "canned-s3-secret-key-value-9f2b1c"

# The seven names the script exports by default, with the keys the live cluster
# holds (names only; the values are invented here).
CANNED = {
    "openbao-seal-key": {"key": "canned-seal-key-0123456789abcdef"},
    "openbao-init": {"recovery-key": "canned-recovery-key", "root-token": "canned-root-token"},
    "lakekeeper-postgres-encryption": {"encryptionKey": "canned-warehouse-key"},
    "airflow-fernet-key": {"fernet-key": "canned-fernet-key"},
    "stardelt-s3-creds": {
        "access-key": "canned-access-key",
        "secret-key": S3_SECRET,
        "bucket": "canned-bucket",
        "endpoint": "http://canned-s3:8333",
        "region": "us-east-1",
    },
    "keycloak-admin": {"username": "canned-keycloak-user", "password": "canned-keycloak-password"},
    "stardelt-realm-admin": {"username": "canned-realm-user", "password": "canned-realm-password"},
}

# Everything a real `kubectl get secret -o json` carries that must not survive
# the reduction: these strings fail the test if they appear in the decrypted list.
NOISE = ("11111111-2222-3333-4444-555555555555", "987654", "owner-of", "kubectl.kubernetes.io/last-applied", "managedFields")

SHIM = """#!/usr/bin/env bash
set -euo pipefail
# Fake kubectl: `get secret NAME [-o json]` serves a canned file, `apply -f -`
# records its stdin. Anything else is a test bug.
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n | --namespace | -o | --output | -f | --filename) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
verb="${args[0]-}"
case "$verb" in
  get)
    name="${args[2]-}"
    file="$FAKE_KUBECTL_SECRETS/$name.json"
    if [ ! -f "$file" ]; then
      echo "Error from server (NotFound): secrets \\"$name\\" not found" >&2
      exit 1
    fi
    cat "$file"
    ;;
  apply)
    cat > "$FAKE_KUBECTL_APPLIED"
    echo "secret applied (fake)"
    ;;
  *)
    echo "fake kubectl: unsupported invocation: $verb $*" >&2
    exit 96
    ;;
esac
"""


def secret_doc(name, data, namespace="stardelt"):
    """A Secret the way kubectl prints it: base64 data plus the metadata noise."""
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "uid": "11111111-2222-3333-4444-555555555555",
            "resourceVersion": "987654",
            "creationTimestamp": "2026-10-01T10:00:00Z",
            "ownerReferences": [{"apiVersion": "v1", "kind": "Pod", "name": "owner-of-" + name}],
            "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{}"},
            "labels": {"app.kubernetes.io/part-of": "stardelt"},
            "managedFields": [{"manager": "kubectl"}],
        },
        "type": "Opaque",
        "data": {key: base64.b64encode(value.encode()).decode() for key, value in data.items()},
    }


class RecoverySecretsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="recovery-secrets-test-"))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        shim = self.bin / "kubectl"
        shim.write_text(SHIM)
        shim.chmod(0o755)
        self.secrets = self.tmp / "secrets"
        self.secrets.mkdir()
        self.applied = self.tmp / "applied.json"
        self.file = self.tmp / "recovery.enc"
        self.write_secrets(CANNED)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers ---------------------------------------------------------
    def write_secrets(self, secrets):
        for name, data in secrets.items():
            (self.secrets / f"{name}.json").write_text(json.dumps(secret_doc(name, data)))

    def env(self, passphrase=PASSPHRASE, **extra):
        env = os.environ.copy()
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        env["FAKE_KUBECTL_SECRETS"] = str(self.secrets)
        env["FAKE_KUBECTL_APPLIED"] = str(self.applied)
        env.pop("RECOVERY_PASSPHRASE", None)
        env.pop("FORCE", None)
        if passphrase is not None:
            env["RECOVERY_PASSPHRASE"] = passphrase
        env.update({key: str(value) for key, value in extra.items()})
        return env

    def run_script(self, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            env=self.env(**env),
            capture_output=True,
            text=True,
            check=False,
        )

    def export(self, path=None, **env):
        return self.run_script("export", str(path or self.file), **env)

    def check(self, path=None, **env):
        return self.run_script("import", "--check", str(path or self.file), **env)

    def decrypt(self, path=None, passphrase=PASSPHRASE):
        """The plaintext list, read exactly the way `import` reads it."""
        result = subprocess.run(
            ["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "600000", "-salt",
             "-pass", "env:RECOVERY_PASSPHRASE", "-in", str(path or self.file)],
            env={**os.environ, "RECOVERY_PASSPHRASE": passphrase},
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def decrypted_list(self, path=None):
        return json.loads(self.decrypt(path))

    def ok(self, result):
        self.assertEqual(result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}")

    # -- tests -----------------------------------------------------------
    def test_export_then_check_lists_the_names(self):
        result = self.export()
        self.ok(result)
        self.assertEqual(result.stderr, "")
        self.assertIn(f"exported {len(CANNED)} secrets to {self.file}", result.stdout)
        for name in CANNED:
            self.assertIn(name, result.stdout, "the export line names every Secret")

        # 0600 from the moment it exists: the file is a key backup.
        mode = stat.S_IMODE(self.file.stat().st_mode)
        self.assertEqual(mode, 0o600, f"mode is {oct(mode)}")

        checked = self.check()
        self.ok(checked)
        self.assertIn(f"checked {len(CANNED)} secrets in {self.file}", checked.stdout)
        for name in CANNED:
            self.assertIn(name, checked.stdout)
        self.assertFalse(self.applied.exists(), "--check must not apply anything")

    def test_export_file_has_no_plaintext_value(self):
        self.ok(self.export())
        raw = self.file.read_bytes()
        self.assertNotIn(S3_SECRET.encode(), raw, "a plaintext value is in the exported file")
        self.assertNotIn(base64.b64encode(S3_SECRET.encode()), raw, "the base64 form is in the exported file")
        self.assertNotIn(b"kind: List", raw)
        self.assertNotIn(b"openbao-seal-key", raw, "even the Secret name is inside the ciphertext")

    def test_wrong_passphrase_fails_check(self):
        self.ok(self.export())
        result = self.check(passphrase="this is not the passphrase")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot decrypt", result.stderr)
        self.assertNotIn("checked", result.stdout)

    def test_short_or_missing_passphrase_is_refused(self):
        for passphrase in (None, "", "fifteen-chars-"):
            with self.subTest(passphrase=passphrase):
                result = self.export(passphrase=passphrase)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("RECOVERY_PASSPHRASE", result.stderr)
                self.assertFalse(self.file.exists(), "no file is written without a passphrase")

        # Sixteen characters is the boundary the message promises, so it works.
        self.ok(self.export(passphrase="sixteen-chars-ok"))

    def test_file_inside_the_repo_is_refused(self):
        target = REPO / "scripts" / "tests" / ".recovery-test-should-not-exist.enc"
        try:
            result = self.export(path=target)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("inside the repository work tree", result.stderr)
            self.assertFalse(target.exists(), "the refused file must not be created")
        finally:
            target.unlink(missing_ok=True)

    def test_existing_file_needs_force(self):
        self.file.write_text("older export")
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exists", result.stderr)
        self.assertIn("FORCE=1", result.stderr)
        self.assertEqual(self.file.read_text(), "older export", "the existing file is untouched")

        self.ok(self.export(FORCE=1))
        self.assertEqual(stat.S_IMODE(self.file.stat().st_mode), 0o600)
        self.assertEqual(len(self.decrypted_list()["items"]), len(CANNED))

    def test_metadata_is_reduced(self):
        self.ok(self.export())
        text = self.decrypt().decode()
        for noise in NOISE:
            self.assertNotIn(noise, text, f"{noise!r} must not survive the reduction")

        document = json.loads(text)
        self.assertEqual(document["kind"], "List")
        self.assertEqual(len(document["items"]), len(CANNED))
        for item in document["items"]:
            self.assertEqual(sorted(item), ["apiVersion", "data", "kind", "metadata", "type"])
            self.assertEqual(sorted(item["metadata"]), ["name", "namespace"])
            self.assertEqual(item["metadata"]["namespace"], "stardelt")
            self.assertEqual(item["kind"], "Secret")

    def test_output_never_contains_a_secret_value(self):
        self.ok(self.export())
        wrong = self.check(passphrase="wrong passphrase for the redaction test")
        short = self.export(passphrase="too-short")
        everything = [
            ("names", self.run_script("names")),
            ("export", self.export(FORCE=1)),
            ("check", self.check()),
            ("wrong passphrase", wrong),
            ("short passphrase", short),
        ]
        for label, result in everything:
            combined = result.stdout + result.stderr
            for value in (S3_SECRET, "canned-seal-key-0123456789abcdef", "canned-keycloak-password"):
                self.assertNotIn(value, combined, f"{label} printed a secret value")
                self.assertNotIn(base64.b64encode(value.encode()).decode(), combined,
                                 f"{label} printed a base64 value")

    def test_import_applies_into_the_requested_namespace(self):
        self.ok(self.export())
        result = self.run_script("import", str(self.file), NAMESPACE="stardelt-restore")
        self.ok(result)
        self.assertIn(f"applied {len(CANNED)} secrets to namespace stardelt-restore", result.stdout)
        applied = json.loads(self.applied.read_text())
        self.assertEqual(len(applied["items"]), len(CANNED))
        self.assertEqual({item["metadata"]["namespace"] for item in applied["items"]}, {"stardelt-restore"})

    def test_missing_secret_is_reported_not_invented(self):
        partial = {name: data for name, data in CANNED.items() if name not in ("openbao-init", "keycloak-admin")}
        shutil.rmtree(self.secrets)
        self.secrets.mkdir()
        self.write_secrets(partial)

        result = self.export()
        self.ok(result)
        self.assertIn("skipped openbao-init", result.stderr)
        self.assertIn("skipped keycloak-admin", result.stderr)
        self.assertIn(f"exported {len(partial)} secrets", result.stdout)

        document = self.decrypted_list()
        names = sorted(item["metadata"]["name"] for item in document["items"])
        self.assertEqual(names, sorted(partial))
        self.assertNotIn("openbao-init", names, "a missing Secret must not appear in the export")

        # Nothing at all is an error, not an empty file that looks like a backup.
        shutil.rmtree(self.secrets)
        self.secrets.mkdir()
        empty = self.export(FORCE=1)
        self.assertNotEqual(empty.returncode, 0)
        self.assertIn("none of the recovery Secrets exist", empty.stderr)


if __name__ == "__main__":
    unittest.main()
