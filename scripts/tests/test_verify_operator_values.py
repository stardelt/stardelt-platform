"""Tests for scripts/verify-operator-values.sh re-reading a component once (platform#781).

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. `kubectl` is replaced by a shell shim that is first on PATH: `get deploy` succeeds
and `exec … stardelt-operator values <component> full …` prints a fixture document, so no cluster is
touched. The fixture documents are built here and carry the same image digests the script reads from
`helm-values/`, so a pin bump does not break the test.
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
SCRIPT = REPO / "scripts" / "verify-operator-values.sh"

SHIM = """#!/usr/bin/env bash
set -u
# Fake kubectl: `-n NS get deploy stardelt-operator` succeeds; `-n NS exec deploy/stardelt-operator --
# stardelt-operator values <component> full [--identity DOMAIN]` prints $FAKE_DIR/<component>-<mode>.yaml
# and logs the call. When FAKE_TRUNCATE asks for it, the trino identity document is cut short: a
# `kubectl exec` stream can lose its tail, and the script must re-read before it reports a miss.
case "${3-}" in
  get)
    exit 0
    ;;
  exec)
    component="${8-}"
    mode=plain
    if [ "${10-}" = "--identity" ]; then
      mode=identity
    fi
    printf '%s %s\\n' "$component" "$mode" >> "$FAKE_KUBECTL_LOG"
    file="$FAKE_DIR/$component-$mode.yaml"
    truncate=0
    if [ "$component" = trino ] && [ "$mode" = identity ]; then
      calls="$(grep -c '^trino identity$' "$FAKE_KUBECTL_LOG")"
      case "${FAKE_TRUNCATE:-none}" in
        first) [ "$calls" -eq 1 ] && truncate=1 ;;
        always) truncate=1 ;;
      esac
    fi
    if [ "$truncate" = 1 ]; then
      head -n -20 "$file"
    else
      cat "$file"
    fi
    exit 0
    ;;
esac
exit 1
"""


def digest_of(path):
    """The first image digest of a helm values file, as the script's `digest_of` takes it."""
    match = re.search(r"sha256:[0-9a-f]{64}", (REPO / path).read_text())
    if not match:
        raise AssertionError(f"no digest in {path}")
    return match.group(0)


def fixtures():
    loader = digest_of("helm-values/airflow.yaml")
    notebook = digest_of("helm-values/jupyterhub.yaml")
    superset = digest_of("helm-values/superset.yaml")
    # The trino identity document keeps the three needles the truncated read must still satisfy
    # before it misses `passwordAuthSecret` in the removed tail.
    trino_identity = "\n".join(
        [
            "apiVersion: v1",
            "kind: ConfigMap",
            "metadata:",
            "  name: trino",
            "data:",
            "  server:",
            "    https:",
            "      port: 8443",
            "    authenticationType: PASSWORD,OAUTH2",
            "  accessControl:",
            '    "original_user": "superset"',
        ]
        + [f"    catalog.probe.{i}: value" for i in range(25)]
        + ["  password: trino-password-db", "    passwordAuthSecret: trino-password-db"]
    )
    return {
        "airflow-plain.yaml": "\n".join(
            [
                "apiVersion: v1",
                "kind: ConfigMap",
                "data:",
                "  serviceAccount:",
                "    name: stardelt-nova-operator",
                "  loader:",
                f"    image: ghcr.io/stardelt/airflow-loader:dev@{loader}",
            ]
        )
        + "\n",
        "airflow-identity.yaml": "data:\n  oidc:\n    secretName: stardelt-oidc-clients\n",
        "jupyterhub-plain.yaml": "\n".join(
            [
                "storage:",
                "  capacity: 2Gi",
                "singleuser:",
                f"  image: ghcr.io/stardelt/notebook:dev@{notebook}",
            ]
        )
        + "\n",
        "jupyterhub-identity.yaml": "singleuser:\n  oidc:\n    secretName: stardelt-oidc-clients\n",
        "superset-plain.yaml": "image:\n  repository: ghcr.io/stardelt/superset\n"
        f"  tag: dev@{superset}\n",
        "superset-identity.yaml": "extraConfig:\n  trino_uri: trino.example.test:443\n",
        "seaweedfs-plain.yaml": "\n".join(
            [
                "apiVersion: v1",
                "kind: ConfigMap",
                "volume:",
                "  name: data",
                "  size: 20Gi",
                "  storageClassName: local-path",
            ]
        )
        + "\n",
        "trino-plain.yaml": "data:\n  catalog: {}\n",
        "trino-identity.yaml": trino_identity + "\n",
    }


class TestVerifyOperatorValues(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        shim = self.dir / "kubectl"
        shim.write_text(SHIM)
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR)
        for name, text in fixtures().items():
            (self.dir / name).write_text(text)
        self.log = self.dir / "kubectl.log"

    def run_script(self, truncate="none"):
        env = dict(
            os.environ,
            PATH=f"{self.dir}:{os.environ['PATH']}",
            NAMESPACE="stardelt",
            FAKE_DIR=str(self.dir),
            FAKE_KUBECTL_LOG=str(self.log),
            FAKE_TRUNCATE=truncate,
        )
        env.pop("BASE_DOMAIN", None)
        return subprocess.run(
            ["bash", str(SCRIPT)], cwd=REPO, env=env, capture_output=True, text=True, timeout=60
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_a_full_document_passes_every_probe_without_a_retry(self):
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("verify-operator-values: PASS (14 probes)", done.stdout)
        self.assertNotIn("re-reading values once", done.stderr)
        self.assertEqual(len(self.calls()), 8, "four plain reads and four with --identity")

    def test_a_first_read_that_misses_the_tail_is_re_read_and_passes(self):
        done = self.run_script("first")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("verify-operator-values: PASS (14 probes)", done.stdout)
        self.assertIn("re-reading values once", done.stderr)
        self.assertEqual(self.calls().count("trino identity"), 2)

    def test_a_second_read_that_also_misses_fails_once(self):
        done = self.run_script("always")
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("verify-operator-values: FAIL (1 of 14 probes)", done.stdout)
        self.assertEqual((done.stdout + done.stderr).count("trino identity: password file"), 1)
        self.assertIn("is not in the running operator", done.stderr)
        self.assertEqual(self.calls().count("trino identity"), 2)


if __name__ == "__main__":
    unittest.main()
