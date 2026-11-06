"""Unit tests for scripts/check_pin_freshness.py (stardelt-platform#556).

Standard library only; discovered by `python3 -m unittest discover -s scripts/tests`.
"""

import unittest
from pathlib import Path

from scripts.check_pin_freshness import compare, exit_code, parse_pins

REPO = Path(__file__).resolve().parents[2]


class ParsePinsTest(unittest.TestCase):
    def test_parse_operator_tag(self):
        text = (REPO / "helm-values/operator.yaml").read_text()
        pins = parse_pins(text, "tag")
        self.assertEqual(len(pins), 1)
        self.assertTrue(pins[0].startswith("sha256:"))
        self.assertEqual(len(pins[0]), len("sha256:") + 64)

        self.assertEqual(parse_pins("image:\n  repository: x\n  tag: dev\n", "tag"), [])

    def test_parse_two_spark_pins(self):
        digest = "sha256:" + "a" * 64
        text = (
            "    spark.kubernetes.container.image ghcr.io/stardelt/spark:dev@{d}\n"
            "    spark.kubernetes.executor.secretKeyRef.AWS_ACCESS_KEY_ID x:y\n"
            "          image: ghcr.io/stardelt/spark:dev@{d}\n"
            "          image: ghcr.io/stardelt/other:dev@{d}\n"
        ).format(d=digest)
        pins = parse_pins(text, "image")
        self.assertEqual(pins, [digest, digest])


class CompareTest(unittest.TestCase):
    def test_compare_reports_a_stale_pin(self):
        lines = compare(
            "stardelt-operator",
            ["sha256:aa…"],
            "sha256:bb…",
            "helm-values/operator.yaml",
        )
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("✗"))
        self.assertIn("pin-image.sh stardelt-operator", lines[0])
        self.assertEqual(exit_code(lines), 1)

    def test_compare_is_silent_when_fresh(self):
        digest = "sha256:" + "c" * 64
        lines = compare("nova", [digest], digest, "manifests/nova-deployment.yaml")
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("✓"))
        self.assertEqual(exit_code(lines), 0)


if __name__ == "__main__":
    unittest.main()
