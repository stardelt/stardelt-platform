"""Unit tests for scripts/check_cnpg_pin.py (stardelt-platform#192)."""

import unittest
from pathlib import Path

from scripts.check_cnpg_pin import ALLOWED_PREFIX, cnpg_version

REPO = Path(__file__).resolve().parents[2]


class CnpgVersionTest(unittest.TestCase):
    def test_reads_the_pin(self):
        self.assertEqual(cnpg_version("CNPG_VERSION       := 0.28.2\n"), "0.28.2")

    def test_a_missing_pin_is_an_error(self):
        with self.assertRaises(SystemExit):
            cnpg_version("CNPG_VERSION ?= 0.28.2\n")

    def test_the_repository_pin_is_below_the_removal(self):
        version = cnpg_version((REPO / "Makefile").read_text())
        self.assertTrue(version.startswith(ALLOWED_PREFIX), version)


if __name__ == "__main__":
    unittest.main()
