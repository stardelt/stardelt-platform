"""The umbrella chart's Postgres backups are the barman-cloud plugin (platform#1276, #1284).

The bug this pins: CI stayed green while the chart rendered the native
`spec.backup.barmanObjectStore`, because the old shape is valid YAML. The
divergence is semantic, so it needs a test, not a lint.
"""
import pathlib
import re
import unittest

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
CHART = REPO / "chart"


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

    def test_lakekeeper_and_keycloak_use_the_plugin(self):
        template = (CHART / "templates" / "cnpg-postgres.yaml").read_text()
        keycloak = (CHART / "templates" / "keycloak.yaml").read_text()
        for name, text in (("cnpg-postgres.yaml", template), ("keycloak.yaml", keycloak)):
            self.assertNotIn("barmanObjectStore", text, name)
            self.assertIn("method: plugin", text, name)
            self.assertIn("pluginConfiguration:", text, name)
        self.assertIn("barmanObjectName: lakekeeper-pg-backups", template)
        self.assertIn("barmanObjectName: keycloak-pg-backups", keycloak)

    def test_every_chart_cluster_pins_the_image_the_manifest_pins(self):
        # The chart is values-only: the templates carry an expression, the image lives in
        # chart/values.yaml, and it must equal the manifest of the same Cluster.
        values = yaml.safe_load((CHART / "values.yaml").read_text())
        cases = [
            # (template, expression it must contain, resolved value, manifest)
            (
                "cnpg-postgres.yaml",
                "{{ .Values.postgres.image }}",
                values["postgres"]["image"],
                "cnpg-postgres.yaml",
            ),
            (
                "keycloak.yaml",
                "{{ $kc.postgres.image }}",
                values["identity"]["keycloak"]["postgres"]["image"],
                "keycloak.yaml",
            ),
            (
                "nova-pg.yaml",
                "{{ .Values.nova.database.image }}",
                values["nova"]["database"]["image"],
                "nova-pg.yaml",
            ),
        ]
        for template_name, expression, value, manifest_name in cases:
            template = (CHART / "templates" / template_name).read_text()
            self.assertIn("imageName:", template, template_name)
            self.assertIn(expression, template, template_name)
            manifest = (REPO / "manifests" / manifest_name).read_text()
            pinned = re.findall(r"^\s+imageName:\s*(\S+)\s*$", manifest, re.M)
            self.assertEqual(len(pinned), 1, manifest_name)
            self.assertEqual(value, pinned[0], template_name)
        # 17.7 stays on the catalog Cluster on purpose: 17 -> 18 is a dump/restore.
        self.assertIn("17.7-system-trixie", values["postgres"]["image"])


if __name__ == "__main__":
    unittest.main()
