"""`make trino` refuses to render an identity ConfigMap without `tokenEndpoint` (platform#1093)."""

import os
import pathlib
import subprocess
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "identity-contract-preflight.sh"

KUBECTL = """#!/usr/bin/env bash
if [ "$1" = "-n" ]; then shift 2; fi
if [ "$1" != "get" ]; then echo "unexpected: $*" >&2; exit 2; fi
if [ "${FAKE_CM_PRESENT:-1}" != 1 ]; then
  echo 'Error from server (NotFound): configmaps "stardelt-identity" not found' >&2
  exit 1
fi
tok="${FAKE_TOKEN_ENDPOINT:-}"
if [ -n "${FAKE_BOOTSTRAP_MARKER:-}" ] && [ -f "${FAKE_BOOTSTRAP_MARKER}" ]; then
  tok="https://id.example/realms/stardelt/protocol/openid-connect/token"
fi
case "$*" in
  *jsonpath=*tokenEndpoint*) printf '%s' "$tok" ;;
  *jsonpath=*trinoUrl*) printf '%s' "${FAKE_TRINO_URL:-}" ;;
esac
exit 0
"""

BOOTSTRAP = """#!/usr/bin/env bash
touch "${FAKE_BOOTSTRAP_MARKER:?}"
"""


class IdentityContractPreflightTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)
        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        (bin_dir / "kubectl").write_text(KUBECTL)
        (bin_dir / "kubectl").chmod(0o755)
        (self.dir / "identity-bootstrap.sh").write_text(BOOTSTRAP)
        (self.dir / "identity-bootstrap.sh").chmod(0o755)
        self.marker = self.dir / "marker"

    def tearDown(self):
        self.tmp.cleanup()

    def run_preflight(self, **env):
        base = os.environ.copy()
        base.update(
            {
                "PATH": f"{self.dir / 'bin'}:{base['PATH']}",
                "IDENTITY_BOOTSTRAP": str(self.dir / "identity-bootstrap.sh"),
                "FAKE_BOOTSTRAP_MARKER": str(self.marker),
            }
        )
        base.update(env)
        return subprocess.run(
            ["bash", str(SCRIPT)], cwd=REPO_ROOT, env=base, capture_output=True, text=True
        )

    def test_no_configmap_is_a_no_op(self):
        out = self.run_preflight(FAKE_CM_PRESENT="0")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("no platform IdP", out.stdout)
        self.assertFalse(self.marker.exists())

    def test_both_keys_present_is_ok(self):
        out = self.run_preflight(
            FAKE_TOKEN_ENDPOINT="https://id.example/token",
            FAKE_TRINO_URL="https://trino.example:8443",
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("OK", out.stdout)
        self.assertFalse(self.marker.exists())

    def test_a_missing_key_is_repaired_by_the_bootstrap(self):
        out = self.run_preflight(FAKE_TRINO_URL="https://trino.example:8443", BASE_DOMAIN="example.dev")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("running", out.stdout)
        self.assertIn("repaired", out.stdout)
        self.assertTrue(self.marker.exists())

    def test_a_missing_key_without_a_base_domain_fails(self):
        out = self.run_preflight(FAKE_TRINO_URL="https://trino.example:8443", BASE_DOMAIN="")
        self.assertEqual(out.returncode, 1)
        self.assertIn("identity-bootstrap.sh", out.stderr)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
