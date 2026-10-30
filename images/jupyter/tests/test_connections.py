"""Tests for ``stardelt.connection`` (images/jupyter/stardelt/connections.py).

A fake secret store (a few routes on a local HTTP server) stands in for OpenBao and answers the
way the real one does: 200 with ``data``, 403 for a path the person may not read, 404 for a
path that does not exist. What it cannot prove — the real policies — is proven by the store's own
policy test (scripts/test-openbao-policies.sh) and the dev-cluster check in the ticket.
"""

import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

import stardelt
from stardelt.connections import ConnectionUnavailable


def _jwt(sub="sub-alice", groups=("analytics",)):
    payload = base64.urlsafe_b64encode(json.dumps({"sub": sub, "groups": list(groups)}).encode()).decode()
    return f"header.{payload.rstrip('=')}.sig"


class FakeStore:
    """data: path -> fields; meta: path -> custom_metadata. Paths not listed under ``readable`` answer 403."""

    def __init__(self):
        self.data = {}
        self.meta = {}
        self.denied_prefixes = ["connections/group/finance"]
        self.logins = 0
        self.refuse_login = False

        store = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # silence
                pass

            def _send(self, status, body):
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length) or b"{}")
                if self.path == "/v1/auth/jwt/login":
                    store.logins += 1
                    if store.refuse_login:
                        return self._send(400, {"errors": ["invalid audience (aud) claim: audience does not match"]})
                    assert body["role"] == "platform-users"
                    return self._send(200, {"auth": {"client_token": "tok-alice"}})
                self._send(404, {"errors": []})

            def do_GET(self):
                if self.headers.get("X-Vault-Token") != "tok-alice":
                    return self._send(403, {"errors": ["permission denied"]})
                prefix = "/v1/secret/"
                kind, _, path = self.path[len(prefix):].partition("/")
                if any(path.startswith(p) for p in store.denied_prefixes):
                    return self._send(403, {"errors": ["permission denied"]})
                if kind == "metadata" and path in store.meta:
                    return self._send(200, {"data": {"custom_metadata": store.meta[path], "current_version": 1}})
                if kind == "data" and path in store.data:
                    return self._send(200, {"data": {"data": store.data[path], "metadata": {"version": 1}}})
                self._send(404, {"errors": []})

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def add(self, path, fields, type_, settings=None):
        self.data[path] = dict(fields)
        meta = {"type": type_, "keys": ",".join(sorted(fields))}
        meta.update({f"config.{k}": v for k, v in (settings or {}).items()})
        self.meta[path] = meta

    def close(self):
        self.server.shutdown()


@pytest.fixture
def store(monkeypatch):
    fake = FakeStore()
    monkeypatch.setenv("STARDELT_SECRET_STORE_URL", fake.url)
    monkeypatch.setenv("TRINO_TOKEN", _jwt())
    yield fake
    fake.close()


def test_a_group_connection_is_found_and_printing_it_shows_no_value(store):
    store.add("connections/group/analytics/crm-db", {"user": "etl", "password": "p1"}, "sqlserver", {"host": "crm.example.com"})
    crm = stardelt.connection("crm-db")
    assert (crm.scope, crm.group, crm.type) == ("group", "analytics", "sqlserver")
    assert crm.keys == ["password", "user"]
    assert crm.settings == {"host": "crm.example.com"}
    assert "p1" not in repr(crm) and "etl" not in str(crm)
    assert "password" in repr(crm), "field names are fine"


def test_a_personal_connection_wins_over_nothing_and_a_clash_asks_which(store):
    store.add("connections/user/sub-alice/pat", {"token": "t1"}, "rest-api", {"baseUrl": "https://api.example.com"})
    assert stardelt.connection("pat").scope == "personal"
    store.add("connections/group/analytics/pat", {"token": "t2"}, "rest-api", {"baseUrl": "https://api.example.com"})
    with pytest.raises(ConnectionUnavailable, match="more than one place"):
        stardelt.connection("pat")
    assert stardelt.connection("pat", scope="personal").scope == "personal"
    assert stardelt.connection("pat", group="analytics").group == "analytics"


def test_a_value_is_read_when_asked_and_a_rotation_is_seen_at_once(store):
    path = "connections/group/analytics/crm-db"
    store.add(path, {"user": "etl", "password": "p1"}, "sqlserver", {"host": "h"})
    crm = stardelt.connection("crm-db")
    assert crm.value("password") == "p1"
    store.data[path]["password"] = "p2"
    assert crm.value("password") == "p2", "nothing is cached"
    with pytest.raises(KeyError, match="no field"):
        crm.value("token")


def test_a_connection_you_may_not_read_or_that_does_not_exist_says_so(store):
    store.add("connections/group/finance/ledger", {"token": "x"}, "rest-api", {"baseUrl": "https://x"})
    store.add("connections/managed/sftp", {"user": "u", "password": "p"}, "sftp", {"host": "h"})
    for name in ("ledger", "sftp", "nope"):
        with pytest.raises(ConnectionUnavailable, match="no connection .* that you may read") as err:
            stardelt.connection(name)
        assert "x" != str(err.value)
    with pytest.raises(ConnectionUnavailable, match="not a member"):
        stardelt.connection("ledger", group="finance")


def test_a_removed_connection_is_reported_when_its_value_is_read(store):
    path = "connections/group/analytics/crm-db"
    store.add(path, {"user": "etl", "password": "p1"}, "sqlserver", {"host": "h"})
    crm = stardelt.connection("crm-db")
    del store.data[path]
    with pytest.raises(ConnectionUnavailable, match="could not be read any more"):
        crm.value("password")


def test_a_database_url_is_quoted_and_complete(store):
    store.add(
        "connections/group/analytics/crm-db",
        {"user": "etl@corp", "password": "p/w:1?"},
        "sqlserver",
        {"host": "crm.example.com", "port": "1433", "database": "sales db"},
    )
    url = stardelt.connection("crm-db").sqlalchemy_url(driver="pyodbc")
    assert url == "mssql+pyodbc://etl%40corp:p%2Fw%3A1%3F@crm.example.com:1433/sales%20db"
    store.add("connections/group/analytics/pg", {"user": "u", "password": "p"}, "postgresql", {"host": "h"})
    assert stardelt.connection("pg").sqlalchemy_url() == "postgresql://u:p@h"


def test_the_typed_helpers_refuse_the_wrong_type(store):
    store.add("connections/group/analytics/pg", {"user": "u", "password": "p"}, "postgresql", {"host": "h"})
    pg = stardelt.connection("pg")
    for helper in (pg.requests_session, pg.s3_options):
        with pytest.raises(ConnectionUnavailable):
            helper()
    store.add("connections/group/analytics/bucket", {"accessKeyId": "a", "secretAccessKey": "s"}, "s3", {"bucket": "b"})
    with pytest.raises(ConnectionUnavailable, match="database"):
        stardelt.connection("bucket").sqlalchemy_url()


def test_s3_options_and_a_bearer_session(store):
    store.add(
        "connections/group/analytics/bucket",
        {"accessKeyId": "AK", "secretAccessKey": "SK"},
        "s3",
        {"bucket": "b", "endpoint": "https://s3.example.com", "region": "eu-central-1"},
    )
    assert stardelt.connection("bucket").s3_options() == {
        "key": "AK",
        "secret": "SK",
        "client_kwargs": {"endpoint_url": "https://s3.example.com", "region_name": "eu-central-1"},
    }
    store.add("connections/group/analytics/api", {"token": "T"}, "rest-api", {"baseUrl": "https://api.example.com"})
    session = stardelt.connection("api").requests_session()
    assert session.headers["Authorization"] == "Bearer T"
    assert session.base_url == "https://api.example.com"


def test_missing_configuration_and_a_refused_sign_in_are_one_line_errors(store, monkeypatch):
    store.refuse_login = True
    with pytest.raises(ConnectionUnavailable, match="refused your sign-in") as err:
        stardelt.connection("crm-db")
    assert "\n" not in str(err.value) and "header." not in str(err.value)
    monkeypatch.delenv("STARDELT_SECRET_STORE_URL")
    with pytest.raises(ConnectionUnavailable, match="STARDELT_SECRET_STORE_URL is not set"):
        stardelt.connection("crm-db")
    monkeypatch.setenv("STARDELT_SECRET_STORE_URL", "http://127.0.0.1:9")
    with pytest.raises(ConnectionUnavailable, match="not reachable") as err:
        stardelt.connection("crm-db")
    assert "127.0.0.1" not in str(err.value)
    monkeypatch.delenv("TRINO_TOKEN")
    with pytest.raises(ConnectionUnavailable, match="TRINO_TOKEN is not set"):
        stardelt.connection("crm-db")


def test_hostile_names_and_groups_never_reach_the_store(store):
    for name in ("", "../x", "A", "a/b", "x" * 41, "crm-"):
        with pytest.raises(ConnectionUnavailable, match="connection name"):
            stardelt.connection(name)
    with pytest.raises(ConnectionUnavailable, match="scope must be"):
        stardelt.connection("crm-db", scope="managed")
    assert store.logins == 0, "a bad name is refused before any sign-in"
