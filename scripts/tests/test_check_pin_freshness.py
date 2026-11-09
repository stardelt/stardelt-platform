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

    def test_parse_airflow_digest(self):
        text = (REPO / "helm-values/airflow.yaml").read_text()
        pins = parse_pins(text, "digest")
        self.assertEqual(len(pins), 1)
        self.assertTrue(pins[0].startswith("sha256:"))
        self.assertEqual(len(pins[0]), len("sha256:") + 64)

        digest = "sha256:" + "a" * 64
        self.assertEqual(parse_pins("  digest: {}\n".format(digest), "digest"), [digest])
        # Exactly one bare digest line: none or two are "no pin".
        self.assertEqual(parse_pins("  tag: demo\n", "digest"), [])
        self.assertEqual(
            parse_pins(
                "  digest: {}\n  digest: {}\n".format(digest, digest), "digest"
            ),
            [],
        )


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

    def test_compare_prints_the_pin_tag(self):
        digest = "sha256:" + "d" * 64
        lines = compare("airflow", [digest], digest, "helm-values/airflow.yaml", "demo")
        self.assertEqual(lines, ["✓ airflow demo@dddddddd… matches helm-values/airflow.yaml"])
        stale = compare(
            "airflow", ["sha256:" + "e" * 64], digest, "helm-values/airflow.yaml", "demo"
        )
        self.assertIn("demo resolves to dddddddd…", stale[0])
        self.assertNotIn(" dev@", stale[0])


if __name__ == "__main__":
    unittest.main()
