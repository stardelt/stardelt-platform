"""The Airflow API sign-in wiring (stardelt-platform#1047).

Standard library plus PyYAML, like the other offline checks here:
`python3 -m unittest discover -s scripts/tests -v` runs them in CI and no cluster
is touched.

What went wrong and what these tests pin: the API server ran the Airflow 3 default
SimpleAuthManager while every user the platform provisions (`admin`, `nova-api`) is
a FAB user, so `POST /auth/token` answered 401 for everyone and Nova showed "the
scheduler did not answer". The values now put the FAB manager back, through a
small subclass that also lets a local password be exchanged for a token while the
interactive login stays Keycloak (`AUTH_TYPE=AUTH_OAUTH`). A stock
`FabAuthManager` refuses that exchange, which is why the subclass exists at all.

A fresh install is the case that matters: the module has to be mounted and on
`PYTHONPATH` before `helm upgrade` starts the api-server, or the pod cannot import
its auth manager.
"""
import re
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
VALUES = REPO / "helm-values" / "airflow.yaml"
MANIFEST = REPO / "manifests" / "airflow-auth-manager.yaml"
MAKEFILE = REPO / "Makefile"

MODULE = "stardelt_fab_auth.py"
CLASS = "StardeltFabAuthManager"
MOUNT = "/opt/airflow/stardelt-auth"


class AirflowAuthManagerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.values = yaml.safe_load(VALUES.read_text())
        cls.api = cls.values["apiServer"]
        cls.manifest = yaml.safe_load(MANIFEST.read_text())

    def test_api_server_uses_the_stardelt_manager(self):
        env = {item["name"]: item.get("value") for item in self.api.get("env", [])}
        self.assertEqual(
            env.get("AIRFLOW__CORE__AUTH_MANAGER"),
            f"stardelt_fab_auth.{CLASS}",
            "the api-server must run the FAB manager that issues service tokens",
        )
        self.assertEqual(env.get("PYTHONPATH"), MOUNT)

    def test_module_is_mounted_by_that_name(self):
        volumes = {v["name"]: v for v in self.api.get("extraVolumes", [])}
        config_maps = {v.get("configMap", {}).get("name") for v in volumes.values()}
        self.assertIn(
            self.manifest["metadata"]["name"],
            config_maps,
            "the manifest ConfigMap must be the one the api-server mounts",
        )
        mounts = {m["name"]: m["mountPath"] for m in self.api.get("extraVolumeMounts", [])}
        self.assertEqual(mounts.get("stardelt-auth-manager"), MOUNT)

    def test_manifest_carries_the_module(self):
        data = self.manifest["data"]
        self.assertIn(MODULE, data, "the ConfigMap must carry the module under its import name")
        source = data[MODULE]
        self.assertIn(f"class {CLASS}(FabAuthManager)", source)
        self.assertIn("auth_user_db", source, "the token path must ask the FAB user store")
        compile(source, MODULE, "exec")  # a syntax error here is a pod that cannot start

    def test_install_applies_the_manifest_before_helm(self):
        target = MAKEFILE.read_text()
        start = target.index("step-airflow:")
        end = target.index("\n\n", start)
        block = target[start:end]
        apply_at = block.find("kubectl apply -f manifests/airflow-auth-manager.yaml")
        helm_at = block.find("helm upgrade --install airflow")
        self.assertGreaterEqual(apply_at, 0, "step-airflow must apply the auth-manager ConfigMap")
        self.assertGreater(helm_at, apply_at, "the ConfigMap must exist before the api-server starts")

    def test_configmap_version_in_manifest_and_values_agree(self):
        name = self.manifest["metadata"]["name"]
        self.assertRegex(name, r"-v\d+$", "version the ConfigMap name so an edit rolls the pod")
        volumes = {v["name"]: v for v in self.api.get("extraVolumes", [])}
        mounted = volumes["stardelt-auth-manager"]["configMap"]["name"]
        self.assertEqual(name, mounted)


if __name__ == "__main__":
    unittest.main()
