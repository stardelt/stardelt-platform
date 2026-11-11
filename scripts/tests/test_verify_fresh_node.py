"""Tests for scripts/verify-fresh-node.sh (platform#1017).

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. `kubectl` and `curl` are replaced by small shell stubs first on PATH, so no
cluster is touched: `kubectl get` prints a fixture from `$FAKE_DIR`, `wait` succeeds and
`port-forward` just sleeps until the script's trap kills it; `curl` prints the endpoint fixture
that matches its URL.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "verify-fresh-node.sh"

KUBECTL_STUB = """#!/usr/bin/env bash
# Fake kubectl: fixtures come from $FAKE_DIR, so each test case answers differently.
set -u
case " $* " in
  *" wait "*) exit 0 ;;
  *" port-forward "*) exec sleep 60 ;;
esac
case "$*" in
  *"get lakehouse"*)
    [ -f "$FAKE_DIR/lakehouse" ] && exit 0
    exit 1
    ;;
  *"get platforminstance"*)
    case "$*" in
      *status.components*) cat "$FAKE_DIR/components" ;;
      *baseDomain*) [ -f "$FAKE_DIR/base_domain" ] && cat "$FAKE_DIR/base_domain" ;;
      *) [ -f "$FAKE_DIR/instance_fail" ] && exit 1; exit 0 ;;
    esac
    ;;
  *"get deploy"*) cat "$FAKE_DIR/deploy" ;;
  *"get pods"*) cat "$FAKE_DIR/pods" ;;
esac
exit 1
"""

CURL_STUB = """#!/usr/bin/env bash
# Fake curl: the last argument is the URL; print the fixture that belongs to it.
set -u
url="${!#}"
case "$url" in
  */api/health) cat "$FAKE_DIR/health" ;;
  */v1/info) cat "$FAKE_DIR/trino_info" ;;
  */.well-known/openid-configuration) cat "$FAKE_DIR/oidc" ;;
  *) exit 1 ;;
esac
"""

GOOD_FILES = {
    "components": "airflow\ttrue\nkeycloak\ttrue\nnova\ttrue\ntrino\ttrue\n",
    "deploy": "airflow-dag-processor\t1\t1\nnova\t2\t2\ntrino\t1\t1\n",
    "pods": "nova-7d9f\t\t\ntrino-0\t\t\n",
    "base_domain": "dev.stardelt.io",
    "health": '{"status":"ok","db":"up"}',
    "trino_info": '{"nodeId":"trino-0","state":"ACTIVE","starting":false,"coordinator":true}',
    "oidc": '{"issuer":"https://id.dev.stardelt.io/realms/stardelt"}',
}


class FreshNodeTest(unittest.TestCase):
    """Runs the script against stub tools; every case starts from the all-good fixtures."""

    def run_script(self, overrides=None, remove=None, marker=None):
        files = dict(GOOD_FILES)
        files.update(overrides or {})
        for name in remove or []:
            files.pop(name, None)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake = root / "fixtures"
            fake.mkdir()
            for name, content in (("kubectl", KUBECTL_STUB), ("curl", CURL_STUB)):
                path = bin_dir / name
                path.write_text(content)
                path.chmod(0o755)
            for name, content in files.items():
                (fake / name).write_text(content)
            if marker:
                (fake / marker).write_text("")
            env = dict(os.environ)
            env.pop("BASE_DOMAIN", None)
            env.update(
                {
                    "PATH": f"{bin_dir}{os.pathsep}{env.get('PATH', '')}",
                    "FAKE_DIR": str(fake),
                    "NAMESPACE": "stardelt",
                    "WAIT": "5s",
                    "PORT_WAIT_SECONDS": "2",
                }
            )
            done = subprocess.run(
                ["bash", str(SCRIPT)],
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
        return done.returncode, done.stdout + done.stderr

    def test_all_good(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("verify-fresh-node: PASS", out)
        self.assertIn("✓ deploy 3/3 available", out)
        self.assertIn("✓ pods none waiting", out)
        self.assertIn("✓ components 4/4 (airflow, keycloak, nova, trino)", out)
        self.assertIn("✓ nova answers", out)
        self.assertIn("✓ trino answers", out)
        self.assertIn("✓ keycloak answers", out)
        self.assertIn("? lakehouse \"not installed\"", out)
        self.assertIn("the fresh-node run still needs a person (not checked here):", out)
        self.assertIn(
            "1. sign in at https://nova.dev.stardelt.io as the realm admin "
            "(Secret stardelt-realm-admin)",
            out,
        )
        self.assertIn("2. a Trino query answers in Nova's SQL editor", out)
        self.assertIn("3. a second group is refused a table it has no grant for", out)
        self.assertIn(
            "4. a scheduled pipeline runs and its log shows in Nova; a notebook publishes",
            out,
        )

    def test_a_short_deployment_fails(self):
        code, out = self.run_script(
            overrides={"deploy": "nova\t2\t2\ntrino\t1\t1\nbroken\t\t1\n"}
        )
        self.assertEqual(code, 1, out)
        self.assertIn("✗ deploy broken 0/1", out)
        self.assertIn("verify-fresh-node: FAIL", out)

    def test_unreadable_instance_is_unverified(self):
        code, out = self.run_script(marker="instance_fail")
        self.assertEqual(code, 3, out)
        self.assertIn("? instance", out)
        self.assertIn("verify-fresh-node: UNVERIFIED", out)

    def test_nova_degraded_fails(self):
        code, out = self.run_script(overrides={"health": '{"status":"degraded"}'})
        self.assertEqual(code, 1, out)
        self.assertIn("✗ nova", out)
        self.assertIn("verify-fresh-node: FAIL", out)

    def test_a_base_domain_that_is_not_set_prints_the_placeholder(self):
        code, out = self.run_script(remove=["base_domain"])
        self.assertEqual(code, 0, out)
        self.assertIn("1. sign in at https://nova.<base domain> as the realm admin", out)


if __name__ == "__main__":
    unittest.main()
