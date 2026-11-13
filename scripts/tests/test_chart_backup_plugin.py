"""The umbrella chart's nova-pg backup is the barman-cloud plugin (platform#1276).

The bug this pins: CI stayed green while the chart rendered the native
`spec.backup.barmanObjectStore`, because the old shape is valid YAML. The
divergence is semantic, so it needs a test, not a lint.
"""
import pathlib
import unittest

CHART = pathlib.Path(__file__).resolve().parents[2] / "chart"


class ChartBackupPlugin(unittest.TestCase):
    def test_the_plugin_is_a_pinned_dependency(self):
        chart = (CHART / "Chart.yaml").read_text()
        self.assertIn("name: plugin-barman-cloud", chart)
        self.assertIn("version: 0.9.0", chart)
        self.assertIn("condition: postgres.backup.enabled", chart)

    def test_nova_pg_names_the_plugin_and_not_the_native_store(self):
        template = (CHART / "templates" / "nova-pg.yaml").read_text()
        self.assertNotIn("barmanObjectStore", template)
        self.assertIn("barmanObjectName: nova-pg-backups", template)
        self.assertIn("method: plugin", template)
        self.assertIn("pluginConfiguration:", template)

    def test_the_four_object_stores_render_before_the_clusters_can_name_them(self):
        template = (CHART / "templates" / "cnpg-objectstore.yaml").read_text()
        for cluster in ("nova-pg", "lakekeeper-pg", "openfga-pg", "keycloak-pg"):
            self.assertIn(f'"{cluster}"', template)
        self.assertIn("helm.sh/hook: post-install,post-upgrade", template)

    def test_the_chart_installs_the_crd_it_uses(self):
        # A sub-chart's crds/ directory is not installed by Helm; this chart renders its
        # CRD from templates/, which is why the dependency works at all.
        chart = (CHART / "Chart.yaml").read_text()
        self.assertIn("repository: https://cloudnative-pg.github.io/charts", chart)


if __name__ == "__main__":
    unittest.main()
