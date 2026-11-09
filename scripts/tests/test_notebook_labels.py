"""The single-user pod says whose it is (platform#818, internal#161 slice 4c).

`26-spark-labels` in JupyterHub's `extraConfig` installs a `modify_pod_hook`
that labels the spawned pod with `stardelt.io/user` and one
`stardelt.io/group.<group>` per JupyterHub group, so a per-SparkCluster
NetworkPolicy can admit the owner's pods and nobody else's.

Values files are not templated and are not generated from each other, so the
same Python lives in two files and both are checked here. No cluster, no
network: the hook string is exec'd against a fake spawner.
"""

import pathlib
import types
import unittest

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]

LABEL_SOURCES = {
    "chart/values.yaml": ("chart/values.yaml", ["jupyterhub", "hub", "extraConfig"]),
    "helm-values/jupyterhub.yaml": ("helm-values/jupyterhub.yaml", ["hub", "extraConfig"]),
}


def _load(path, keys):
    with open(REPO / path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    for key in keys:
        data = data[key]
    return data["26-spark-labels"]


def _install(path, keys):
    """exec the hook and return (hook, config)."""
    config = types.SimpleNamespace(KubeSpawner=types.SimpleNamespace())
    namespace = {"c": config}
    exec(_load(path, keys), namespace)  # noqa: S102 - the value is the file under test
    return namespace["_stardelt_labels"], config


def _fake_spawner(groups):
    return types.SimpleNamespace(
        user=types.SimpleNamespace(
            name="admin",
            groups=[types.SimpleNamespace(name=name) for name in groups],
        ),
        log=types.SimpleNamespace(warning=lambda *a, **k: None),
    )


def _pod():
    """KubeSpawner passes a V1Pod, not a dict (platform#841)."""
    return types.SimpleNamespace(metadata=types.SimpleNamespace(labels={}))


class NotebookLabelsTest(unittest.TestCase):
    def test_admin_gets_the_user_and_group_labels(self):
        for label, (path, keys) in LABEL_SOURCES.items():
            with self.subTest(values=label):
                hook, _ = _install(path, keys)
                pod = hook(
                    _fake_spawner(["stardelt-admins", "stardelt-users"]),
                    _pod(),
                )
                self.assertEqual(
                    pod.metadata.labels,
                    {
                        "stardelt.io/user": "admin",
                        "stardelt.io/group.stardelt-admins": "true",
                        "stardelt.io/group.stardelt-users": "true",
                    },
                )

    def test_an_unusable_group_name_is_skipped_not_sanitized(self):
        for label, (path, keys) in LABEL_SOURCES.items():
            with self.subTest(values=label):
                hook, _ = _install(path, keys)
                pod = hook(
                    _fake_spawner(["Analytics Team", "stardelt-admins"]),
                    _pod(),
                )
                labels = pod.metadata.labels
                self.assertIn("stardelt.io/group.stardelt-admins", labels)
                self.assertFalse(
                    [key for key in labels if "Analytics" in key],
                    f"an unusable group name must not be added: {labels}",
                )

                # `group.` plus 60 characters is 66 > 63: too long for a label value.
                long_name = "a" * 60
                pod = hook(_fake_spawner([long_name]), _pod())
                self.assertEqual(pod.metadata.labels, {"stardelt.io/user": "admin"})

    def test_the_hook_is_installed(self):
        for label, (path, keys) in LABEL_SOURCES.items():
            with self.subTest(values=label):
                hook, config = _install(path, keys)
                self.assertIs(config.KubeSpawner.modify_pod_hook, hook)


if __name__ == "__main__":
    unittest.main()
