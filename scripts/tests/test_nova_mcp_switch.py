"""The hosted MCP endpoint's switch lives in the identity ConfigMap (stardelt-nova#112).

`kubectl apply` of the Nova Deployment used to write `NOVA_MCP_ENABLED=0`, so the only way to run
the endpoint (a hand patch) was pruned by the next apply — the same failure that once turned
sign-in off (see the comment in scripts/identity-bootstrap.sh). Both variables now come from the
ConfigMap Nova already reads `authMode`/`publicUrl` from, so it is pinned here.
"""
import pathlib
import unittest

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
SWITCH = {"NOVA_MCP_ENABLED": "mcpEnabled", "NOVA_MCP_AUDIENCE": "mcpAudience"}


def nova_container():
    manifests = REPO / "manifests" / "nova-deployment.yaml"
    for document in yaml.safe_load_all(manifests.read_text()):
        if not document or document.get("kind") != "Deployment":
            continue
        return document["spec"]["template"]["spec"]["containers"][0]
    raise AssertionError("no Deployment in manifests/nova-deployment.yaml")


class Switch(unittest.TestCase):
    def test_each_variable_is_read_from_the_identity_configmap(self):
        env = {entry["name"]: entry for entry in nova_container()["env"]}
        for name, key in SWITCH.items():
            self.assertNotIn("value", env[name], name)
            ref = env[name]["valueFrom"]["configMapKeyRef"]
            self.assertEqual(ref["name"], "stardelt-identity", name)
            self.assertEqual(ref["key"], key, name)
            self.assertTrue(ref["optional"], name)

    def test_install_identity_writes_both_keys(self):
        script = (REPO / "scripts" / "identity-bootstrap.sh").read_text()
        self.assertIn("--from-literal=mcpEnabled=", script)
        self.assertIn("--from-literal=mcpAudience=", script)
