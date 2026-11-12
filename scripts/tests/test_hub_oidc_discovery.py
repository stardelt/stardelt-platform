"""The hub reads its OIDC endpoints from the provider's discovery document (#611).

Both values files carry the same literal Python snippet as
`hub.extraConfig["10-oidc"]`. It used to build the three endpoints by
concatenating the issuer with Keycloak's realm paths, which only works for a
realm-style provider. Now the first place it looks is
`<issuer>/.well-known/openid-configuration`, and the realm paths are only the
fallback for a provider outage (the hub must still start).

The snippet is Python in YAML, so the check loads it from both files, runs it
against a stub discovery document on localhost, and asserts the attributes it
leaves on `c`. No cluster, no Helm.
"""

import http.server
import pathlib
import socket
import textwrap
import threading
import types
import unittest
from unittest import mock

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# (file, path to the snippet inside the document)
SOURCES = [
    ("helm-values/jupyterhub.yaml", ("hub",)),
    ("chart/values.yaml", ("jupyterhub", "hub")),
]


def snippet_blocks():
    """The `10-oidc` snippet of every values file that carries it."""
    blocks = []
    for name, path in SOURCES:
        with open(REPO_ROOT / name, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
        for key in path:
            document = document[key]
        blocks.append((name, document["extraConfig"]["10-oidc"]))
    return blocks


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class DiscoveryHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 — http.server's name
        if self.path != "/.well-known/openid-configuration":
            self.send_error(404)
            return
        body = (
            '{"issuer": "http://127.0.0.1:%d",'
            ' "authorization_endpoint": "http://127.0.0.1:%d/auth",'
            ' "token_endpoint": "http://127.0.0.1:%d/token",'
            ' "userinfo_endpoint": "http://127.0.0.1:%d/userinfo"}'
            % ((self.server.server_port,) * 4)
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep the unittest output clean
        pass


def run_snippet(snippet, issuer):
    """`exec` one snippet with the stub config and return its `c`."""
    config = types.SimpleNamespace(GenericOAuthenticator=types.SimpleNamespace())
    namespace = {"c": config}
    with mock.patch.dict("os.environ", {"STARDELT_OIDC_ISSUER_URL": issuer}):
        exec(textwrap.dedent(snippet), namespace)  # noqa: S102 — that is the point
    return config


class HubOidcDiscoveryTest(unittest.TestCase):
    def test_discovery_endpoints_replace_the_realm_paths(self):
        port = free_port()
        server = http.server.HTTPServer(("127.0.0.1", port), DiscoveryHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            issuer = "http://127.0.0.1:%d" % port
            for name, snippet in snippet_blocks():
                config = run_snippet(snippet, issuer)
                with self.subTest(file=name):
                    self.assertEqual(
                        config.GenericOAuthenticator.authorize_url,
                        issuer + "/auth",
                        f"{name}: authorize_url must come from discovery",
                    )
                    self.assertEqual(
                        config.GenericOAuthenticator.token_url,
                        issuer + "/token",
                        f"{name}: token_url must come from discovery",
                    )
                    self.assertEqual(
                        config.GenericOAuthenticator.userdata_url,
                        issuer + "/userinfo",
                        f"{name}: userdata_url must come from discovery",
                    )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_a_provider_outage_keeps_the_realm_paths(self):
        # Nothing listens on this port: discovery fails fast with ECONNREFUSED.
        issuer = "http://127.0.0.1:%d" % free_port()
        for name, snippet in snippet_blocks():
            with self.subTest(file=name):
                config = run_snippet(snippet, issuer)  # must not raise
                self.assertEqual(
                    config.GenericOAuthenticator.authorize_url,
                    issuer + "/protocol/openid-connect/auth",
                )
                self.assertEqual(
                    config.GenericOAuthenticator.token_url,
                    issuer + "/protocol/openid-connect/token",
                )
                self.assertEqual(
                    config.GenericOAuthenticator.userdata_url,
                    issuer + "/protocol/openid-connect/userinfo",
                )


if __name__ == "__main__":
    unittest.main()
