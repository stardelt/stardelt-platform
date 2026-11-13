"""The Spark ConfigMap janitor's script survives an install (platform#1258 follow-up).

`manifests/spark-confmap-janitor.yaml` declared the script ConfigMap with `data: {}`, and
`make install-spark` filled that ConfigMap *before* applying the manifest — so every
install emptied it again and the CronJob's pods failed with
`bash: /opt/scripts/spark-confmap-janitor.sh: No such file or directory` (measured on the
lab 2026-11-13T21:1xZ). These two pins are cheap and catch both halves.
"""

import pathlib
import re
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "manifests" / "spark-confmap-janitor.yaml"
MAKEFILE = REPO_ROOT / "Makefile"


def documents():
    with open(MANIFEST, encoding="utf-8") as handle:
        return [d for d in yaml.safe_load_all(handle) if d]


class JanitorInstall(unittest.TestCase):
    def test_the_manifest_does_not_clear_the_script_configmap(self):
        config_map = next(d for d in documents() if d["kind"] == "ConfigMap")
        self.assertEqual(config_map["metadata"]["name"], "spark-confmap-janitor-script")
        # `data: {}` is a present field: applying it sets the live data to empty.
        self.assertNotIn(
            "data",
            config_map,
            "an empty data: {} empties spark-confmap-janitor-script on every install",
        )

    def test_install_fills_the_script_after_applying_the_manifest(self):
        text = MAKEFILE.read_text(encoding="utf-8")
        block = re.search(r"^install-spark:.*?(?=^\S|\Z)", text, re.S | re.M)
        self.assertIsNotNone(block, "the install-spark target is missing")
        body = block.group(0)
        apply_at = body.find("apply -f manifests/spark-confmap-janitor.yaml")
        fill_at = body.find("spark-confmap-janitor-config")
        self.assertGreaterEqual(apply_at, 0, "install-spark does not apply the janitor manifest")
        self.assertGreaterEqual(fill_at, 0, "install-spark does not fill the janitor script")
        self.assertLess(
            apply_at,
            fill_at,
            "the manifest apply must come before the script is filled, or it empties it",
        )


if __name__ == "__main__":
    unittest.main()
