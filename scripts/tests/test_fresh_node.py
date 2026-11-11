"""The throwaway-cluster wrapper: it must be unable to reach the dev cluster.

``dev/hetzner-k3s/fresh-node.sh`` renders its own config and never updates DNS, so a
fresh-node run cannot orphan the dev cluster or point ``alpha.dev`` at a server that is
deleted an hour later (platform#1018). Two things are easy to get wrong and expensive
when they are:

* the dev config — ``dev/hetzner-k3s/cluster.yaml`` is the only record ``make dev-down``
  has of what to delete, so a fresh-node call must leave it byte-identical (or, on a
  checkout that has none, must not create it);
* the name — everything that is not ``stardelt-fresh-*`` is refused before
  ``destroy.sh`` is reached, so passing ``FRESH_NAME=stardelt-dev`` (or a config that
  describes it) deletes nothing.

Every case here runs ``DRY_RUN=1``: the tests never create a server and never call
``hetzner-k3s``, ``hcloud`` or DNS. ``ALLOW_IPV4``/``ALLOW_IPV6`` and ``CF_ENV`` are set
so the scripts do not look up the caller's address or read the caller's credentials.
"""

import filecmp
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "dev" / "hetzner-k3s" / "fresh-node.sh"
DEV_CONFIG = REPO / "dev" / "hetzner-k3s" / "cluster.yaml"


class FreshNode(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.config = self.tmp / "fresh.yaml"
        self.kubeconfig = self.tmp / "kubeconfig.yaml"

    def tearDown(self):
        self._tmp.cleanup()

    def run_script(self, *args, **env):
        """Run fresh-node.sh with every path pointed inside the temporary directory."""
        base = {
            "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
            "HOME": str(self.home),
            "CF_ENV": str(self.tmp / "absent-cloudflare.env"),
            "HETZNER_ENV": str(self.tmp / "absent-hetzner.env"),
            # No network: the allowed networks are the ones a real run would discover.
            "ALLOW_IPV4": "203.0.113.7/32",
            "ALLOW_IPV6": "2001:db8::/128",
            "FRESH_NAME": "stardelt-fresh-test",
            "FRESH_CONFIG": str(self.config),
            "FRESH_KUBECONFIG": str(self.kubeconfig),
            "DRY_RUN": "1",
        }
        base.update(env)
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=str(REPO),
            env=base,
            capture_output=True,
            text=True,
        )

    def write_config(self, cluster_name):
        self.config.write_text(
            "---\n"
            "cluster_name: {name}\n"
            "kubeconfig_path: {kube}\n".format(name=cluster_name, kube=self.kubeconfig)
        )

    # -- up -----------------------------------------------------------------
    def test_dry_run_up_does_not_touch_the_dev_config(self):
        before = self.tmp / "cluster.yaml.before"
        existed = DEV_CONFIG.exists()
        if existed:
            before.write_bytes(DEV_CONFIG.read_bytes())

        result = self.run_script("up")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "would write {} for cluster stardelt-fresh-test".format(self.config),
            result.stdout,
        )
        self.assertIn("would run: hetzner-k3s create", result.stdout)
        # Nothing was written: no config, no kubeconfig directory, no dev config.
        self.assertFalse(self.config.exists())
        self.assertFalse(self.kubeconfig.exists())
        self.assertFalse((self.home / ".kube").exists())
        if existed:
            self.assertTrue(
                filecmp.cmp(before, DEV_CONFIG, shallow=False),
                "the dev cluster.yaml changed during a fresh-node dry run",
            )
        else:
            self.assertFalse(DEV_CONFIG.exists(), "the dev cluster.yaml was created")

    def test_up_refuses_an_existing_config(self):
        self.write_config("stardelt-fresh-test")

        result = self.run_script("up")

        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing:", result.stderr)
        # It stopped before rendering: no plan of a second cluster in the output.
        self.assertNotIn("would run: hetzner-k3s create", result.stdout)

    # -- down ---------------------------------------------------------------
    def test_down_refuses_the_dev_cluster(self):
        self.write_config("stardelt-dev")

        result = self.run_script("down")

        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing:", result.stderr)
        # destroy.sh was never reached: it would have printed its plan first.
        self.assertNotIn("About to delete", result.stdout)
        self.assertTrue(self.config.exists())

    def test_dry_run_down_keeps_the_config(self):
        self.write_config("stardelt-fresh-test")

        result = self.run_script("down")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would run: hetzner-k3s delete", result.stdout)
        self.assertTrue(self.config.exists(), "a dry run removed the config")


if __name__ == "__main__":
    unittest.main()
