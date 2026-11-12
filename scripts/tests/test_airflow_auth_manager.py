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
import os
import re
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

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


class _FakeSecurityManager:
    """The bits of FAB's security manager the token path touches."""

    def __init__(self, auth_type):
        self.auth_type = auth_type
        self.calls = []

    def auth_user_db(self, username, password, rotate_session_id=True):
        self.calls.append((username, rotate_session_id))
        return "user"


class CreateTokenBehaviourTest(unittest.TestCase):
    """Who may trade a username and password for an API token (platform#1102).

    The module under test imports Airflow and Flask-AppBuilder, which are not
    installed for an offline check, so the two modules it imports from are faked
    in `sys.modules` before the manifest text is executed.
    """

    FAKES = (
        "airflow",
        "airflow.providers",
        "airflow.providers.fab",
        "airflow.providers.fab.auth_manager",
        "airflow.providers.fab.auth_manager.fab_auth_manager",
        "flask_appbuilder",
        "flask_appbuilder.const",
    )

    @classmethod
    def setUpClass(cls):
        stock = types.ModuleType("airflow.providers.fab.auth_manager.fab_auth_manager")

        class FabAuthManager:
            def create_token(self, headers, body):
                return "stock"

        stock.FabAuthManager = FabAuthManager
        const = types.ModuleType("flask_appbuilder.const")
        const.AUTH_DB = 1
        const.AUTH_LDAP = 2
        const.AUTH_OAUTH = 4

        for name in cls.FAKES:
            if name not in sys.modules:
                sys.modules[name] = types.ModuleType(name)
        sys.modules[stock.__name__] = stock
        sys.modules[const.__name__] = const

        source = yaml.safe_load(MANIFEST.read_text())["data"][MODULE]
        cls.namespace = {}
        exec(compile(source, MODULE, "exec"), cls.namespace)
        cls.manager_class = cls.namespace[CLASS]
        cls.const = const

    @classmethod
    def tearDownClass(cls):
        for name in cls.FAKES:
            sys.modules.pop(name, None)

    def _manager(self, auth_type):
        manager = object.__new__(self.manager_class)
        manager.security_manager = _FakeSecurityManager(auth_type)
        return manager

    def test_service_user_is_checked(self):
        manager = self._manager(self.const.AUTH_OAUTH)
        token = manager.create_token({}, {"username": "nova-api", "password": "x"})
        self.assertEqual(token, "user")
        self.assertEqual(manager.security_manager.calls, [("nova-api", False)])

    def test_admin_is_refused_without_a_password_check(self):
        manager = self._manager(self.const.AUTH_OAUTH)
        self.assertIsNone(manager.create_token({}, {"username": "admin", "password": "x"}))
        self.assertEqual(manager.security_manager.calls, [], "a person's password is never checked")

    def test_empty_password_is_a_bad_request(self):
        manager = self._manager(self.const.AUTH_OAUTH)
        with self.assertRaises(ValueError):
            manager.create_token({}, {"username": "nova-api", "password": ""})
        self.assertEqual(manager.security_manager.calls, [])

    def test_env_names_the_service_users(self):
        with mock.patch.dict(os.environ, {"STARDELT_TOKEN_USERS": "a,b"}):
            manager = self._manager(self.const.AUTH_OAUTH)
            self.assertEqual(manager.create_token({}, {"username": "a", "password": "x"}), "user")
            self.assertEqual(manager.security_manager.calls, [("a", False)])
            self.assertIsNone(manager.create_token({}, {"username": "nova-api", "password": "x"}))
            self.assertEqual(manager.security_manager.calls, [("a", False)])

    def test_break_glass_uses_the_stock_manager(self):
        manager = self._manager(self.const.AUTH_DB)
        self.assertEqual(manager.create_token({}, {"username": "admin", "password": "x"}), "stock")
        self.assertEqual(manager.security_manager.calls, [])


if __name__ == "__main__":
    unittest.main()
