"""Tests for the notebook task wrapper (``images/jupyter/stardelt/notebook_run.py``).

No cluster and no object store needed: two ``http.server`` fakes stand in for the pre-signed
GET/PUT and for Trino's cancel endpoint, and a small script stands in for papermill
(``STARDELT_PAPERMILL``). What these cannot prove — a real pre-signed URL, a real papermill run,
a real cancelled statement — the scratch-pod check in platform#315 covers.

SPDX-License-Identifier: MIT
"""

import base64
import json
import logging
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

import stardelt
from stardelt import notebook_run


def _jwt(seconds=3600):
    """A token shaped like the pod's: not expired, so ``stardelt._token()`` returns it as-is."""
    payload = base64.urlsafe_b64encode(
        json.dumps({"preferred_username": "pipeline-runner", "exp": time.time() + seconds}).encode()
    ).decode().rstrip("=")
    return f"header.{payload}.sig"


FAKE_PAPERMILL = '''#!/usr/bin/env python3
"""Stands in for papermill: records ids, writes the executed notebook, exits."""
import json
import os
import sys
import time

args = sys.argv[1:]
out_path = args[1]
ids = os.environ.get("STARDELT_QUERY_IDS")
if ids:
    with open(ids, "w", encoding="utf-8") as handle:
        handle.write("query-1\\nquery-2\\n")
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump({"cells": [], "metadata": {}, "nbformat": 4, "nbformat_minor": 5, "argv": args}, handle)
delay = float(os.environ.get("FAKE_PAPERMILL_SLEEP", "0"))
if delay:
    time.sleep(delay)
sys.exit(int(os.environ.get("FAKE_PAPERMILL_RC", "0")))
'''


class FakeStore:
    """The object store behind two pre-signed URLs: GET serves ``body``, PUT records the bytes."""

    def __init__(self, body=b"{}", status=200, send_content_length=True):
        self.body = body
        self.status = status
        self.send_content_length = send_content_length
        self.puts = []
        self.paths = []
        store = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # a test server must not write to stderr
                pass

            def do_GET(self):
                store.paths.append(("GET", self.path))
                self.send_response(store.status)
                if store.send_content_length:
                    self.send_header("Content-Length", str(len(store.body)))
                else:
                    self.close_connection = True  # body is delimited by the close
                self.end_headers()
                self.wfile.write(store.body)

            def do_PUT(self):
                length = int(self.headers.get("Content-Length", 0))
                data = self.rfile.read(length)
                store.paths.append(("PUT", self.path))
                store.puts.append((self.path, self.headers.get("Content-Type"), data))
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FakeTrino:
    """Just the cancel endpoint: records each ``DELETE /v1/query/<id>`` and answers 204."""

    def __init__(self):
        self.deletes = []
        self.authorizations = []
        trino = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_DELETE(self):
                trino.deletes.append(self.path)
                trino.authorizations.append(self.headers.get("Authorization"))
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def store():
    fake = FakeStore()
    try:
        yield fake
    finally:
        fake.close()


@pytest.fixture
def trino():
    fake = FakeTrino()
    try:
        yield fake
    finally:
        fake.close()


@pytest.fixture
def papermill(tmp_path, monkeypatch):
    path = tmp_path / "papermill"
    path.write_text(FAKE_PAPERMILL, encoding="utf-8")
    path.chmod(0o755)
    monkeypatch.setenv("STARDELT_PAPERMILL", str(path))
    return path


@pytest.fixture
def task(tmp_path, monkeypatch, store, papermill):
    """A pod with the contract of the ticket, its two paths under tmp_path."""
    monkeypatch.setattr(notebook_run, "PATH_IN", str(tmp_path / "in.ipynb"))
    monkeypatch.setattr(notebook_run, "PATH_OUT", str(tmp_path / "out.ipynb"))
    monkeypatch.setenv("NOTEBOOK_GET_URL", f"{store.url}/in.ipynb?X-Amz-Signature=url-canary")
    monkeypatch.setenv("NOTEBOOK_PUT_URL", f"{store.url}/out.ipynb?X-Amz-Signature=url-canary")
    monkeypatch.setenv("NOTEBOOK_RUN_DATE", "2026-10-21")
    monkeypatch.setenv("NOTEBOOK_RUN_ID", "run-1")
    monkeypatch.setenv("TRINO_TOKEN", _jwt())
    for name in (
        "NOTEBOOK_PARAMS",
        "STARDELT_QUERY_IDS",
        "TRINO_URL",
        "PIPELINE_CLIENT_SECRET",
        "PIPELINE_TOKEN_URL",
        "FAKE_PAPERMILL_RC",
        "FAKE_PAPERMILL_SLEEP",
    ):
        monkeypatch.delenv(name, raising=False)
    return tmp_path


# parameters ----------------------------------------------------------------


def test_parameters_merge_run_values_first(monkeypatch):
    monkeypatch.setenv("NOTEBOOK_RUN_DATE", "2026-10-21")
    monkeypatch.setenv("NOTEBOOK_RUN_ID", "run-7")
    monkeypatch.setenv(
        "NOTEBOOK_PARAMS",
        json.dumps({"code": "0123", "run_date": "1999-01-01", "borough": "Queens"}),
    )
    params = notebook_run.parameters()
    # run values first in the dict, and a saved parameter cannot date the run differently
    assert list(params) == ["run_date", "run_id", "code", "borough"]
    assert params["run_date"] == "2026-10-21"
    assert params["run_id"] == "run-7"
    assert params["code"] == "0123"  # text, not the integer 123


def test_bad_params_exit_2(task, monkeypatch, caplog):
    caplog.set_level(logging.INFO, logger="stardelt.notebook_run")
    monkeypatch.setenv("NOTEBOOK_PARAMS", '{"attempts": 3}')
    assert notebook_run.main() == 2
    problem = [r.getMessage() for r in caplog.records if "NOTEBOOK_PARAMS" in r.getMessage()]
    assert len(problem) == 1
    assert "\n" not in problem[0]

    monkeypatch.setenv("NOTEBOOK_PARAMS", "{not json")
    assert notebook_run.main() == 2


# download / upload ---------------------------------------------------------


def test_download_refuses_non_200_and_oversize(tmp_path):
    missing = FakeStore(body=b"", status=404)
    try:
        dest = tmp_path / "in.ipynb"
        with pytest.raises(notebook_run.ContractError) as exc:
            notebook_run.download(f"{missing.url}/in.ipynb?sig=url-canary", str(dest))
        assert str(exc.value) == "the notebook could not be fetched (HTTP 404)"
        assert "url-canary" not in str(exc.value)
        assert "127.0.0.1" not in str(exc.value)
        assert not dest.exists()  # no half-written notebook is left behind
    finally:
        missing.close()

    # No Content-Length: the limit has to hold while the body streams.
    big = FakeStore(body=b"x" * 4096, send_content_length=False)
    try:
        dest = tmp_path / "big.ipynb"
        with pytest.raises(notebook_run.ContractError) as exc:
            notebook_run.download(f"{big.url}/big.ipynb", str(dest), limit=1024)
        assert "bigger than the 1024-byte limit" in str(exc.value)
        assert not dest.exists()
    finally:
        big.close()


def test_upload_redacts_the_pod_token(task, store, monkeypatch, caplog):
    caplog.set_level(logging.INFO, logger="stardelt.notebook_run")
    token = _jwt()
    monkeypatch.setenv("TRINO_TOKEN", token)
    out = task / "redact.ipynb"
    out.write_text(json.dumps({"cells": [{"source": [f"bearer {token}"]}]}), encoding="utf-8")

    written = notebook_run.upload(str(out), os.environ["NOTEBOOK_PUT_URL"])

    assert written > 0
    assert token not in store.puts[-1][2].decode()
    assert "[redacted]" in store.puts[-1][2].decode()
    assert token not in caplog.text


# papermill's command line and exit code ------------------------------------


def test_papermill_args_use_r_and_are_sorted(monkeypatch):
    monkeypatch.setenv("STARDELT_PAPERMILL", "/opt/bin/papermill")
    command = notebook_run.build_command({"b": "2", "a": "0123"})
    assert command == [
        "/opt/bin/papermill",
        notebook_run.PATH_IN,
        notebook_run.PATH_OUT,
        "-r", "a", "0123",
        "-r", "b", "2",
        "--no-progress-bar", "--log-output", "--kernel", "python3",
    ]


def test_exit_code_is_propagated_and_output_uploaded_anyway(task, store, monkeypatch):
    monkeypatch.setenv("FAKE_PAPERMILL_RC", "7")
    assert notebook_run.main() == 7
    assert len(store.puts) == 1
    path, content_type, body = store.puts[0]
    assert content_type == "application/x-ipynb+json"
    assert json.loads(body)["cells"] == []  # the executed notebook as far as it ran


# stop ----------------------------------------------------------------------


def test_sigterm_deletes_every_recorded_query_and_exits_143(task, trino, monkeypatch, caplog):
    caplog.set_level(logging.INFO, logger="stardelt.notebook_run")
    monkeypatch.setenv("TRINO_URL", trino.url)
    ids = task / "statement-ids"
    monkeypatch.setenv("STARDELT_QUERY_IDS", str(ids))
    monkeypatch.setenv("FAKE_PAPERMILL_SLEEP", "60")

    def stop_once_running():
        deadline = time.monotonic() + 20
        while not ids.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        os.kill(os.getpid(), signal.SIGTERM)  # what `kubectl delete pod` delivers

    killer = threading.Thread(target=stop_once_running, daemon=True)
    killer.start()
    rc = notebook_run.main()
    killer.join(timeout=5)

    assert rc == 143
    assert sorted(trino.deletes) == ["/v1/query/query-1", "/v1/query/query-2"]
    assert all(auth.startswith("Bearer ") for auth in trino.authorizations)
    assert "cancelled 2 of 2" in caplog.text


# what must never be logged -------------------------------------------------


def test_no_url_token_or_param_value_in_logs(task, store, monkeypatch, caplog, capsys):
    caplog.set_level(logging.INFO, logger="stardelt.notebook_run")
    monkeypatch.setenv("TRINO_TOKEN", "token-canary-0123456789")
    monkeypatch.setenv("NOTEBOOK_PARAMS", json.dumps({"borough": "param-canary-Queens"}))
    monkeypatch.setenv("NOTEBOOK_GET_URL", f"{store.url}/in.ipynb?sig=url-canary-0123456789")
    monkeypatch.setenv("NOTEBOOK_PUT_URL", f"{store.url}/out.ipynb?sig=url-canary-0123456789")

    assert notebook_run.main() == 0

    captured = capsys.readouterr()
    seen = caplog.text + captured.out + captured.err
    for canary in ("url-canary", "token-canary", "param-canary"):
        assert canary not in seen, f"{canary} reached the logs"


# the helper records statement ids ------------------------------------------


def test_query_ids_are_recorded_by_sql(tmp_path, monkeypatch):
    class Cursor:
        query_id = "trino-42"
        description = []

        def execute(self, statement, params=None):
            pass

        def fetchall(self):
            return []

        def close(self):
            pass

    class Connection:
        def cursor(self):
            return Cursor()

        def close(self):
            pass

    monkeypatch.setattr(stardelt, "_trino_connect", lambda **kwargs: Connection())
    monkeypatch.setenv("TRINO_URL", "https://trino.example:8443")
    monkeypatch.setenv("TRINO_TOKEN", _jwt())

    ids = tmp_path / "statement-ids"
    monkeypatch.setenv("STARDELT_QUERY_IDS", str(ids))
    stardelt.sql("SELECT 1")
    assert ids.read_text(encoding="utf-8") == "trino-42\n"

    # an interactive hub pod has no file to write
    monkeypatch.delenv("STARDELT_QUERY_IDS")
    ids.unlink()
    stardelt.sql("SELECT 1")
    assert not ids.exists()
