"""OpenBao serves Prometheus text on 8200 only with both telemetry blocks (#607)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


class OpenBaoMetricsTest(unittest.TestCase):
    def setUp(self):
        with open(ROOT / "helm-values" / "openbao.yaml", encoding="utf-8") as handle:
            self.config = yaml.safe_load(handle)["server"]["standalone"]["config"]

    def test_the_listener_allows_unauthenticated_metrics(self):
        listener = self.config.split('listener "tcp" {', 1)[1].split("}", 1)[0]
        self.assertIn("unauthenticated_metrics_access = true", listener)

    def test_a_top_level_telemetry_block_keeps_samples(self):
        self.assertIn('prometheus_retention_time = "30s"', self.config)
        # YAML strips the block scalar's indentation, so the top-level block starts at
        # column 0 of a line; the listener's nested one is indented by two.
        self.assertIn("\ntelemetry {", self.config)
        self.assertNotIn("\n  telemetry {\n    prometheus_retention_time", self.config)
        self.assertEqual(self.config.count("telemetry {"), 2)


if __name__ == "__main__":
    unittest.main()
