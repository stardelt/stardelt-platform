"""`tokenEndpoint` in the identity contract (platform#1084, for #611).

Every component that talks to the IdP with client credentials needs the OAuth2 token
endpoint. If each one concatenated `<issuer>/protocol/openid-connect/token` itself, an
external provider (whose endpoint is not under the issuer) would break every consumer at
once. So the chart resolves it once and publishes it as `tokenEndpoint` in ConfigMap
`stardelt-identity`: derived from the Keycloak for `identity.mode: platform`, given as
`identity.tokenEndpoint` for `external` — where a render without it must fail rather than
publish an empty key.

Needs Helm and the sub-charts fetched into `chart/charts/*.tgz` (gitignored;
`helm dependency update chart`). The `lint` job runs `unittest discover` as
well and does not fetch them, so the module skips itself there; the
`helm-lint` job runs it after its dependency step and has both.
"""

import pathlib
import shutil
import subprocess
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# The `lint` job runs `unittest discover` without Helm; the `helm-lint` job has it.
HELM = shutil.which("helm")


def missing_subcharts():
    """Sub-chart names `chart/Chart.yaml` declares but `chart/charts/` lacks."""
    with open(REPO_ROOT / "chart" / "Chart.yaml", encoding="utf-8") as handle:
        deps = yaml.safe_load(handle).get("dependencies") or []
    present = [p.name for p in (REPO_ROOT / "chart" / "charts").glob("*.tgz")]
    return [d["name"] for d in deps
            if not any(p.startswith(d["name"] + "-") for p in present)]


def render(*settings):
    """Render `templates/identity.yaml` and return the completed process."""
    cmd = [HELM, "template", "stardelt", "chart", "-n", "stardelt",
           "--show-only", "templates/identity.yaml", *settings]
    return subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)


def contract(out):
    """The `stardelt-identity` ConfigMap's data from a successful render."""
    for doc in yaml.safe_load_all(out.stdout):
        if doc and doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "stardelt-identity":
            return doc["data"]
    raise AssertionError(f"no stardelt-identity ConfigMap in the render: {out.stdout[-2000:]}")


class IdentityContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if HELM is None:
            raise unittest.SkipTest("helm is not on PATH")
        missing = missing_subcharts()
        if missing:
            print(f"skip: chart/charts/ lacks {', '.join(missing)} "
                  "(run `helm dependency update chart`)")
            raise unittest.SkipTest(f"chart dependencies not fetched: {', '.join(missing)}")

    def test_platform_mode_derives_the_keycloak_token_endpoint(self):
        out = render("--set", "identity.mode=platform", "--set", "platform.baseDomain=example.com")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        self.assertEqual(
            contract(out)["tokenEndpoint"],
            "https://id.example.com/realms/stardelt/protocol/openid-connect/token")

    def test_external_mode_passes_the_token_endpoint_through(self):
        out = render("--set", "identity.mode=external",
                     "--set", "identity.issuerUrl=https://idp.example.com",
                     "--set", "identity.tokenEndpoint=https://idp.example.com/oauth2/token")
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        self.assertEqual(contract(out)["tokenEndpoint"], "https://idp.example.com/oauth2/token")

    def test_external_mode_without_a_token_endpoint_fails_the_render(self):
        out = render("--set", "identity.mode=external",
                     "--set", "identity.issuerUrl=https://idp.example.com")
        self.assertNotEqual(out.returncode, 0, "external mode without tokenEndpoint must fail")
        self.assertIn("identity.mode=external needs identity.tokenEndpoint",
                      out.stdout + out.stderr)


if __name__ == "__main__":
    unittest.main()
