import re, unittest
from pathlib import Path

DOCKERFILE = Path(__file__).resolve().parents[2] / "images" / "jupyter" / "Dockerfile"

class JupyterBuildGatesTest(unittest.TestCase):
    def test_no_labextension_list_piped_into_grep_q(self):
        text = DOCKERFILE.read_text()
        self.assertIsNone(
            re.search(r"labextension list[^\n]*\|\s*grep\s+-q", text),
            "labextension list | grep -q races Jupyter's write and fails with exit 120 (platform#1296)",
        )

    def test_the_stardelt_extension_gate_reads_a_file(self):
        text = DOCKERFILE.read_text()
        self.assertIn("labextension list > /tmp/labext-stardelt.txt 2>&1", text)
        self.assertIn("grep -q '@stardelt/jupyterlab' /tmp/labext-stardelt.txt", text)
