"""The spawned notebook container declares the restricted PodSecurity fields (platform#1237).

z2jh 4.4.5 has no value for the single-user container's securityContext, so the hub sets
KubeSpawner.extra_container_config from `hub.extraConfig["22-restricted"]`. Both values files
carry the same snippet; this runs it against a stub `c` and asserts the dict, so a typo fails
in CI and not on the first spawn.
"""

import pathlib
import types
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = [
    ("helm-values/jupyterhub.yaml", ("hub",)),
    ("chart/values.yaml", ("jupyterhub", "hub")),
]
EXPECTED = {
    "runAsUser": 1000,
    "runAsNonRoot": True,
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}


def snippets():
    for name, path in SOURCES:
        with open(REPO_ROOT / name, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
        for key in path:
            document = document[key]
        yield name, document["extraConfig"]["22-restricted"]


class NotebookPodSecurity(unittest.TestCase):
    def test_the_container_declares_the_restricted_fields(self):
        for name, snippet in snippets():
            kubernetes = types.SimpleNamespace(uid=1000)
            c = types.SimpleNamespace(KubeSpawner=kubernetes)
            exec(snippet, {"c": c})  # noqa: S102 — the snippet is the thing under test
            self.assertEqual(
                c.KubeSpawner.extra_container_config,
                {"securityContext": EXPECTED},
                name,
            )


if __name__ == "__main__":
    unittest.main()
