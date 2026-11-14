"""Tests for scripts/check-python-parity.sh (platform#1291, rule of platform#369).

Standard library only, like the other tests here: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. Each test writes two fixture Dockerfiles into a fresh `tempfile.mkdtemp()` and runs
the script against them through NOTEBOOK_DOCKERFILE / SPARK_DOCKERFILE. No image is built and no
cluster is touched.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-python-parity.sh"

NOTEBOOK = """FROM quay.io/jupyter/scipy-notebook:2024-10-07
ARG STARDELL_PYTHON_MINOR={minor}
RUN echo build
"""

SPARK = """FROM apache/spark:4.1.3
ADD --checksum=sha256:deadbeef \\
    https://github.com/astral-sh/python-build-standalone/releases/download/20261020/cpython-{archive}%2B20261020-x86_64-unknown-linux-gnu-install_only.tar.gz \\
    /tmp/python.tar.gz
"""


class PythonParity(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)

    def run_script(self, notebook=None, archive="3.11.17"):
        notebook_file = self.dir / "notebook.Dockerfile"
        spark_file = self.dir / "spark.Dockerfile"
        notebook_file.write_text(NOTEBOOK.format(minor=notebook) if notebook else "FROM scratch\n")
        spark_file.write_text(SPARK.format(archive=archive))
        env = dict(os.environ, NOTEBOOK_DOCKERFILE=str(notebook_file), SPARK_DOCKERFILE=str(spark_file))
        return subprocess.run(["bash", str(SCRIPT)], cwd=REPO, env=env, capture_output=True, text=True, timeout=60)

    def test_the_same_minor_passes(self):
        done = self.run_script(notebook="3.11", archive="3.11.17")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("check-python-parity: OK", done.stdout)

    def test_a_different_minor_fails_and_names_both_versions(self):
        done = self.run_script(notebook="3.11", archive="3.13.2")
        self.assertEqual(done.returncode, 1)
        self.assertIn("3.11", done.stderr)
        self.assertIn("3.13", done.stderr)
        self.assertIn("PYTHON_VERSION_MISMATCH", done.stderr)

    def test_a_missing_arg_in_the_notebook_fails_with_the_expected_message(self):
        done = self.run_script(notebook=None, archive="3.11.17")
        self.assertEqual(done.returncode, 1)
        self.assertIn("no 'ARG STARDELL_PYTHON_MINOR=", done.stderr)


if __name__ == "__main__":
    unittest.main()
