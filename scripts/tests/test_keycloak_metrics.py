"""Keycloak serves Prometheus text on the management port (platform#1133).

Keycloak 26 keeps metrics on the management port (9000) once
`KC_METRICS_ENABLED=true`; the container already declares `management` and
every probe uses it, so reaching `/metrics` only needs the env var and a
Service port. The ingress never exposes 9000 — metrics stay cluster-internal.

The chart template is a Go template and is verified by `helm template` in CI;
this module checks the manifest the lab and `make install-identity` apply.
"""

import pathlib
import unittest

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO / "manifests/keycloak.yaml"


def _objects():
    with open(MANIFEST, encoding="utf-8") as handle:
        return [doc for doc in yaml.safe_load_all(handle) if doc]


def _named(kind, name):
    for doc in _objects():
        if doc.get("kind") == kind and doc["metadata"]["name"] == name:
            return doc
    raise AssertionError(f"no {kind} named {name} in {MANIFEST}")


class KeycloakMetrics(unittest.TestCase):
    def test_the_service_exposes_the_management_port(self):
        service = _named("Service", "keycloak")
        self.assertEqual(
            service["spec"]["ports"],
            [
                {"name": "http", "port": 8080, "targetPort": "http"},
                {"name": "metrics", "port": 9000, "targetPort": "management"},
            ],
        )

    def test_the_deployment_turns_metrics_on(self):
        deployment = _named("Deployment", "keycloak")
        containers = deployment["spec"]["template"]["spec"]["containers"]
        keycloak = [c for c in containers if c["name"] == "keycloak"][0]
        env = keycloak["env"]
        self.assertIn({"name": "KC_METRICS_ENABLED", "value": "true"}, env)
        # The Service's targetPort names a container port: keep the two in step.
        self.assertIn({"name": "management", "containerPort": 9000}, keycloak["ports"])


if __name__ == "__main__":
    unittest.main()
