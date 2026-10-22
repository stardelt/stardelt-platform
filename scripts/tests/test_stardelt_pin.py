"""The library pin check: the Dockerfile's pin and the Makefile's must agree.

The notebook helper lives in its own repository (``stardelt/stardelt-python``)
and the platform consumes one pinned release of it (platform#417). The pin
lives in two places — the ``Makefile`` (``STARDELT_LIB_REF``, the source of
truth) and the ``Dockerfile`` (the build arg's default) — and
``scripts/check-stardelt-pin.sh`` is what keeps them from drifting.

The script is exercised against a copy of the real tree, so the check the
repository runs in CI is the one the tests describe.
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-stardelt-pin.sh"

SHA = "978c7d1a46beefe68f564349668ffb43f4cd86d0"
OTHER_SHA = "1111111111111111111111111111111111111111"


class StardeltPinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="stardelt-pin-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.makefile = self.tmp / "Makefile"
        self.dockerfile = self.tmp / "images" / "jupyter" / "Dockerfile"
        self.dockerfile.parent.mkdir(parents=True)
        self.makefile.write_text(
            "STARDELT_LIB_REF := {sha}\nSTARDELT_LIB_TAG := v0.1.0\n".format(sha=SHA)
        )
        self.dockerfile.write_text(
            "# the release v0.1.0\n"
            "ARG STARDELT_LIB_REF={sha}\n"
            'RUN pip install "stardelt @ git+https://github.com/stardelt/'
            'stardelt-python@${{STARDELT_LIB_REF}}"\n'.format(sha=SHA)
        )
        # The script reads the tree it is run from, so it is copied next to it.
        self.scripts = self.tmp / "scripts"
        self.scripts.mkdir()
        shutil.copy(SCRIPT, self.scripts / SCRIPT.name)

    def run_check(self):
        return subprocess.run(
            ["bash", str(self.scripts / SCRIPT.name)],
            cwd=self.tmp,
            capture_output=True,
            text=True,
        )

    def test_the_real_tree_passes(self):
        proc = subprocess.run(
            ["bash", str(SCRIPT)], cwd=REPO, capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("OK", proc.stdout)

    def test_equal_pins_pass(self):
        proc = self.run_check()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(SHA, proc.stdout)

    def test_a_drifted_makefile_pin_fails(self):
        self.makefile.write_text(
            "STARDELT_LIB_REF := {sha}\nSTARDELT_LIB_TAG := v0.1.0\n".format(sha=OTHER_SHA)
        )
        proc = self.run_check()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(OTHER_SHA, proc.stderr)
        self.assertIn(SHA, proc.stderr)

    def test_a_drifted_dockerfile_pin_fails(self):
        text = self.dockerfile.read_text().replace(SHA, OTHER_SHA)
        self.dockerfile.write_text(text)
        proc = self.run_check()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("but", proc.stderr)

    def test_a_tag_is_not_a_pin(self):
        text = self.dockerfile.read_text().replace(SHA, "v0.1.0")
        self.dockerfile.write_text(text)
        proc = self.run_check()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not a full commit SHA", proc.stderr)

    def test_a_second_copy_of_the_commit_in_the_dockerfile_fails(self):
        text = self.dockerfile.read_text() + "# and again {sha}\n".format(sha=SHA)
        self.dockerfile.write_text(text)
        proc = self.run_check()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("commit SHAs", proc.stderr)

    def test_a_hardcoded_commit_in_the_install_line_fails(self):
        text = self.dockerfile.read_text().replace(
            "@${STARDELT_LIB_REF}", "@" + SHA
        )
        self.dockerfile.write_text(text)
        proc = self.run_check()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("STARDELT_LIB_REF", proc.stderr)

    def test_a_pin_without_a_release_named_next_to_it_fails(self):
        text = self.dockerfile.read_text().replace("# the release v0.1.0\n", "")
        self.dockerfile.write_text(text)
        proc = self.run_check()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("v0.1.0", proc.stderr)

    def test_a_missing_pin_fails(self):
        self.makefile.write_text("STARDELT_LIB_TAG := v0.1.0\n")
        proc = self.run_check()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("STARDELT_LIB_REF", proc.stderr)


if __name__ == "__main__":
    unittest.main()
