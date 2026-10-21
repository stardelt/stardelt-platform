"""Tests for the stardelt notebook helper (images/jupyter/stardelt/).

No warehouse needed: a stub Trino DBAPI connection stands in for the real
one (monkeypatched over ``stardelt._trino_connect``), so these run in CI.
What the stub cannot prove — real ``?`` parameters against Trino, the
round-trip dtypes — the dev-cluster check in the ticket covers.
"""

import base64
import json
import os
import sys
import time
import types

import pandas as pd
import pytest

import stardelt


def _jwt(username="analyst"):
    payload = base64.urlsafe_b64encode(json.dumps({"preferred_username": username}).encode()).decode()
    return f"header.{payload}.sig"


class StubCursor:
    """Records statements; replays one canned result set for reads."""

    def __init__(self, conn):
        self.conn = conn
        self.statements = conn.statements
        self.description = [("id", None), ("note", None)]
        self.rows = [(1, "a"), (2, "b")]
        self.fail_on = None

    def execute(self, statement, params=None):
        if self.fail_on and self.fail_on in statement:
            raise RuntimeError("line one\nline two\nline three")
        self.statements.append((statement, params))

    def fetchall(self):
        return self.rows

    def close(self):
        pass


class StubConnection:
    instances = []

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.statements = []
        StubConnection.instances.append(self)

    def cursor(self):
        return StubCursor(self)

    def close(self):
        pass


@pytest.fixture
def trino(monkeypatch):
    """stardelt talking to the stub, with a signed-in user in the environment."""
    StubConnection.instances.clear()
    monkeypatch.setenv("TRINO_URL", "https://trino.example:8443")
    monkeypatch.setenv("TRINO_TOKEN", _jwt("analyst"))
    monkeypatch.delenv("JUPYTERHUB_USER", raising=False)
    monkeypatch.setattr(stardelt, "_trino_connect", StubConnection)
    return StubConnection


@pytest.fixture
def frame():
    return pd.DataFrame(
        {"id": pd.Series([1, 2, 3], dtype="int64"), "note": ["a", "b", "c"]}
    )


# sql ----------------------------------------------------------------------


def test_sql_returns_dataframe(trino):
    out = stardelt.sql("SELECT id, note FROM warehouse.demo.trips ORDER BY id")
    assert out.equals(pd.DataFrame({"id": [1, 2], "note": ["a", "b"]}))
    conn = trino.instances[-1]
    assert conn.kwargs["host"] == "trino.example"
    assert conn.kwargs["port"] == 8443
    assert "user" not in conn.kwargs  # the token decides who runs the statement


def test_sql_declares_no_user_even_in_a_hub_pod(trino, monkeypatch):
    # A declared user that differs from the token's principal is refused by Trino
    # ("cannot impersonate"); with `principal-field=sub` the hub name would always differ.
    monkeypatch.setenv("JUPYTERHUB_USER", "hub-person")
    stardelt.sql("SELECT 1")
    assert "user" not in trino.instances[-1].kwargs


def test_sql_passes_params_through(trino):
    stardelt.sql("SELECT * FROM t WHERE borough = ?", params=("Queens",))
    stmt, params = trino.instances[-1].statements[-1]
    assert "?" in stmt and "Queens" not in stmt
    assert params == ("Queens",)


def test_sql_missing_token_is_one_line(trino, monkeypatch):
    monkeypatch.delenv("TRINO_TOKEN")
    with pytest.raises(RuntimeError) as exc:
        stardelt.sql("SELECT 1")
    assert "\n" not in str(exc.value)
    assert trino.instances == []


def test_sql_wraps_engine_errors_in_one_line(trino, monkeypatch):
    cursor = StubCursor(StubConnection())
    cursor.fail_on = "BOOM"
    monkeypatch.setattr(StubConnection, "cursor", lambda self: cursor)
    with pytest.raises(RuntimeError) as exc:
        stardelt.sql("SELECT BOOM")
    assert str(exc.value) == "stardelt.sql failed: line one"
    assert exc.value.__cause__ is not None


# write_df: DDL, types -------------------------------------------------------


def test_type_mapping(trino):
    df = pd.DataFrame({
        "b": pd.Series([True], dtype="bool"),
        "i32": pd.Series([1], dtype="int32"),
        "i64": pd.Series([1], dtype="int64"),
        "f32": pd.Series([1.5], dtype="float32"),
        "f64": pd.Series([1.5], dtype="float64"),
        "ts": pd.to_datetime(["2026-01-01"]),
        "s": ["x"],
    })
    stardelt.write_df(df, "demo.types", mode="create")
    ddl = trino.instances[-1].statements[0][0]
    for fragment in (
        '"b" BOOLEAN', '"i32" INTEGER', '"i64" BIGINT', '"f32" REAL',
        '"f64" DOUBLE', '"ts" TIMESTAMP', '"s" VARCHAR',
    ):
        assert fragment in ddl, ddl


def test_tz_aware_datetime(trino):
    df = pd.DataFrame({"ts": pd.to_datetime(["2026-01-01"]).tz_localize("UTC")})
    stardelt.write_df(df, "demo.types", mode="create")
    assert "TIMESTAMP WITH TIME ZONE" in trino.instances[-1].statements[0][0]


def test_modes(trino, frame):
    stardelt.write_df(frame, "demo.t", mode="create")
    assert trino.instances[-1].statements[0][0].startswith('CREATE TABLE "demo"."t" (')

    StubConnection.instances.clear()
    stardelt.write_df(frame, "demo.t", mode="append")
    assert trino.instances[-1].statements[0][0].startswith("CREATE TABLE IF NOT EXISTS")

    StubConnection.instances.clear()
    stardelt.write_df(frame, "demo.t", mode="overwrite")
    stmts = [s for s, _ in trino.instances[-1].statements]
    assert stmts[0] == 'DROP TABLE IF EXISTS "demo"."t"'
    assert stmts[1].startswith('CREATE TABLE "demo"."t" (')


# write_df: batching, quoting, parameters -------------------------------------


def test_batching(trino):
    df = pd.DataFrame({"id": range(5), "note": list("abcde")})
    n = stardelt.write_df(df, "demo.t", mode="append", batch_rows=2)
    assert n == 5
    inserts = [(s, p) for s, p in trino.instances[-1].statements if s.startswith("INSERT")]
    assert len(inserts) == 3
    assert [len(p) // 2 for _, p in inserts] == [2, 2, 1]
    assert sum(len(p) for _, p in inserts) == 5 * 2


def test_values_go_through_parameters(trino):
    df = pd.DataFrame({"id": [1], "note": ["o'brien; DROP TABLE demo.t;--"]})
    stardelt.write_df(df, "demo.t", mode="append")
    stmt, params = trino.instances[-1].statements[-1]
    assert "o'brien" not in stmt
    assert "DROP TABLE demo.t" not in stmt
    assert stmt.count("?") == 2
    assert params[1] == "o'brien; DROP TABLE demo.t;--"


def test_identifier_quoting(trino):
    df = pd.DataFrame({'we"ird': [1]})
    stardelt.write_df(df, 'my"schema.we"ird', mode="create")
    ddl = trino.instances[-1].statements[0][0]
    assert ddl.startswith('CREATE TABLE "my""schema"."we""ird"')
    assert '"we""ird" BIGINT' in ddl


def test_nulls_become_none(trino):
    df = pd.DataFrame({"f": [1.5, float("nan")], "s": ["x", None]})
    stardelt.write_df(df, "demo.t", mode="append")
    _, params = trino.instances[-1].statements[-1]
    assert params == [1.5, "x", None, None]


def test_row_limit_points_at_spark(trino):
    df = pd.DataFrame({"id": range(200_001)})
    with pytest.raises(ValueError, match=r"stardelt\.spark\(\)"):
        stardelt.write_df(df, "demo.t")
    assert trino.instances == []


def test_row_limit_boundary(trino):
    df = pd.DataFrame({"id": range(200_000)})
    assert stardelt.write_df(df, "demo.t", batch_rows=100_000) == 200_000


# write_df: bronze ------------------------------------------------------------


def test_bronze_adds_exactly_three_columns(trino, frame):
    stardelt.write_df(frame, "demo.t", mode="append", bronze=True, source="quickstart")
    stmts = trino.instances[-1].statements
    assert '"_ingested_at" TIMESTAMP WITH TIME ZONE' in stmts[0][0]
    assert '"_source" VARCHAR' in stmts[0][0]
    assert '"_batch_id" VARCHAR' in stmts[0][0]
    _, params = stmts[-1]
    assert len(params) == 3 * 5  # 2 original + 3 bronze, times 3 rows
    assert params[3] == "quickstart"
    assert len(params[4]) == 32  # uuid4 hex


def test_bronze_batch_ids_differ(trino, frame):
    stardelt.write_df(frame, "demo.t", mode="append", bronze=True)
    first = trino.instances[-1].statements[-1][1][4]
    StubConnection.instances.clear()
    stardelt.write_df(frame, "demo.t", mode="append", bronze=True)
    second = trino.instances[-1].statements[-1][1][4]
    assert first != second


def test_no_implicit_columns_without_bronze(trino, frame):
    stardelt.write_df(frame, "demo.t", mode="append")
    ddl = trino.instances[-1].statements[0][0]
    assert "_ingested_at" not in ddl and "_source" not in ddl and "_batch_id" not in ddl


def test_bronze_refuses_clash(trino):
    df = pd.DataFrame({"id": [1], "_source": ["x"]})
    with pytest.raises(ValueError, match="_source"):
        stardelt.write_df(df, "demo.t", bronze=True)


# write_df: bad input ----------------------------------------------------------


@pytest.mark.parametrize("table", ["bare", "a.b.c.d", "", ".t", "s.", "a..t"])
def test_bad_table_names(trino, frame, table):
    with pytest.raises(ValueError, match="schema.table"):
        stardelt.write_df(frame, table)
    assert trino.instances == []


def test_three_part_table_name(trino, frame):
    stardelt.write_df(frame, "warehouse.demo.t", mode="create")
    ddl = trino.instances[-1].statements[0][0]
    assert ddl.startswith('CREATE TABLE "warehouse"."demo"."t" (')


def test_bad_mode(trino, frame):
    with pytest.raises(ValueError, match="mode"):
        stardelt.write_df(frame, "demo.t", mode="upsert")


def test_bad_batch_rows(trino, frame):
    for bad in (0, -1, "1000", True):
        with pytest.raises(ValueError, match="batch_rows"):
            stardelt.write_df(frame, "demo.t", batch_rows=bad)


def test_unsupported_dtypes(trino):
    with pytest.raises(TypeError, match="categorical"):
        stardelt.write_df(pd.DataFrame({"c": pd.Categorical(["a"])}), "demo.t")
    with pytest.raises(TypeError, match="unsupported dtype"):
        stardelt.write_df(pd.DataFrame({"c": pd.Series([1j])}), "demo.t")
    with pytest.raises(TypeError, match="non-string"):
        stardelt.write_df(pd.DataFrame({"c": pd.Series([{"a": 1}], dtype=object)}), "demo.t")
    with pytest.raises(ValueError, match="unique"):
        stardelt.write_df(pd.DataFrame([[1, 2]], columns=["a", "a"]), "demo.t")


# spark, connection -------------------------------------------------------------


def test_spark_reads_remote_from_env(fake_spark, monkeypatch):
    monkeypatch.setattr(stardelt, "sql", lambda _query: _catalogs("warehouse"))
    monkeypatch.setattr(stardelt, "_token", lambda: "canary-token-317")

    monkeypatch.setenv("SPARK_REMOTE", "sc://other:15002")
    stardelt.spark()
    assert fake_spark.sessions[-1].configs["spark.remote"] == "sc://other:15002"
    assert fake_spark.sessions[-1].configs["spark.app.name"] == "stardelt-notebook"

    stardelt._SPARK_SESSION = None
    monkeypatch.delenv("SPARK_REMOTE")
    stardelt.spark()
    assert fake_spark.sessions[-1].configs["spark.remote"] == stardelt.SPARK_REMOTE_DEFAULT


def test_spark_docstring_states_credential_limitation():
    assert "shared storage credential" in stardelt.spark.__doc__


def test_spark_tips_prints_every_row(capsys):
    stardelt.spark_tips()
    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 7
    # One line per README row ("Keeping the shared driver healthy"), in order.
    for marker in (
        "toPandas()",
        "createDataFrame(big_pandas_or_list)",
        "mapInPandas",
        "broadcast(small_df)",
        "unpersist()",
        "20_000 rows",
        "df.count()",
    ):
        assert any(marker in line for line in lines), marker
    assert all(line.startswith("instead of ") for line in lines)


def test_spark_docstring_mentions_tips():
    assert "stardelt.spark_tips()" in stardelt.spark.__doc__


# Token source and renewal --------------------------------------------------------


def _jwt_exp(exp, username="svc"):
    payload = base64.urlsafe_b64encode(json.dumps({"preferred_username": username, "exp": exp}).encode()).decode()
    return f"header.{payload}.sig"


class _Reply:
    def __init__(self, status=200, token="fresh.token.value"):
        self.status_code = status
        self._token = token

    def json(self):
        return {"access_token": self._token}


@pytest.fixture
def pipeline_env(trino, monkeypatch):
    """A pod without the hub's token but with the loader's client credentials."""
    monkeypatch.delenv("TRINO_TOKEN", raising=False)
    monkeypatch.setenv("PIPELINE_TOKEN_URL", "https://idp.example/token")
    monkeypatch.setenv("PIPELINE_CLIENT_ID", "sp-analytics")
    monkeypatch.setenv("PIPELINE_CLIENT_SECRET", "canary-secret-1f3a")
    calls = []

    def post(url, data=None, timeout=None):
        calls.append((url, dict(data), timeout))
        return _Reply()

    monkeypatch.setattr(stardelt.requests, "post", post)
    return calls


def test_hub_token_is_used_unchanged(trino, monkeypatch):
    token = _jwt_exp(time.time() + 3600)
    monkeypatch.setenv("TRINO_TOKEN", token)
    monkeypatch.setenv("PIPELINE_TOKEN_URL", "https://idp.example/token")
    monkeypatch.setenv("PIPELINE_CLIENT_SECRET", "unused")
    monkeypatch.setattr(stardelt.requests, "post", lambda *a, **k: pytest.fail("no refresh expected"))
    stardelt.sql("SELECT 1")
    assert os.environ["TRINO_TOKEN"] == token


def test_client_credentials_used_when_the_hub_token_is_absent(trino, pipeline_env):
    stardelt.sql("SELECT 1")
    url, data, timeout = pipeline_env[0]
    assert url == "https://idp.example/token"
    assert data["grant_type"] == "client_credentials"
    assert data["client_id"] == "sp-analytics"
    assert timeout == 15
    assert os.environ["TRINO_TOKEN"] == "fresh.token.value"


def test_token_is_fetched_again_within_60_seconds_of_expiry(trino, pipeline_env, monkeypatch):
    monkeypatch.setattr(stardelt.time, "time", lambda: 1000.0)
    monkeypatch.setenv("TRINO_TOKEN", _jwt_exp(1100))  # 100 s left: keep
    stardelt.sql("SELECT 1")
    assert pipeline_env == []
    monkeypatch.setenv("TRINO_TOKEN", _jwt_exp(1050))  # 50 s left: renew
    stardelt.sql("SELECT 1")
    assert len(pipeline_env) == 1


def test_expired_hub_token_without_pipeline_credentials_is_one_line(trino, monkeypatch):
    token = _jwt_exp(time.time() - 10)
    monkeypatch.setenv("TRINO_TOKEN", token)
    monkeypatch.delenv("PIPELINE_TOKEN_URL", raising=False)
    monkeypatch.delenv("PIPELINE_CLIENT_SECRET", raising=False)
    with pytest.raises(RuntimeError) as exc:
        stardelt.sql("SELECT 1")
    assert "\n" not in str(exc.value)
    assert "expired" in str(exc.value)
    assert token not in str(exc.value)


def test_refused_token_request_names_the_client_not_the_secret(trino, pipeline_env, monkeypatch):
    monkeypatch.setattr(stardelt.requests, "post", lambda *a, **k: _Reply(status=401))
    with pytest.raises(RuntimeError) as exc:
        stardelt.sql("SELECT 1")
    message = str(exc.value)
    assert "sp-analytics" in message and "401" in message
    assert "canary-secret-1f3a" not in message


# spark: the person's catalogs and the person's token -------------------------
#
# Spark is not installed in CI; a fake ``pyspark.sql.SparkSession`` records the
# builder options. The real behaviour — a session that lists and reads the
# catalogs Trino lists, and is refused by Lakekeeper otherwise — is proved in
# the ticket's cluster gates, not here.


class FakeSparkConf:
    """Records ``conf.set`` on the fake session, as the helper uses it."""

    def __init__(self, values):
        self.values = values

    def set(self, key, value):
        self.values[key] = value

    def get(self, key, default=None):
        return self.values.get(key, default)


class FakeSparkCatalog:
    """Spark's catalog handle: loading a name is what makes SHOW CATALOGS list it."""

    def __init__(self, module):
        self.module = module
        self.current = "spark_catalog"
        self.loaded = []

    def currentCatalog(self):
        return self.current

    def setCurrentCatalog(self, name):
        if name in self.module.refused:
            raise RuntimeError(f"catalog {name} refused")
        self.current = name
        self.loaded.append(name)


class FakeSparkSession:
    def __init__(self, module, options):
        self.configs = dict(options)
        self.conf = FakeSparkConf(self.configs)
        self.catalog = FakeSparkCatalog(module)
        self.stopped = False
        # Like the real client: ``is_stopped`` is the local flag the helper set,
        # ``version`` is the round trip that notices a restarted server. ``broken``
        # stands for "the driver closed this client" (pyspark raises on the call).
        self.broken = False

    @property
    def is_stopped(self):
        return self.stopped

    @property
    def version(self):
        if self.broken:
            raise RuntimeError("closed")
        return "4.2.0"

    def stop(self):
        self.stopped = True


class FakeSparkBuilder:
    def __init__(self, module):
        self.module = module
        self.options = {}

    def remote(self, url):
        self.options["spark.remote"] = url
        return self

    def appName(self, name):
        self.options["spark.app.name"] = name
        return self

    def create(self):
        if self.module.fail_with is not None:
            raise RuntimeError(self.module.fail_with)
        session = FakeSparkSession(self.module, self.options)
        self.module.sessions.append(session)
        return session


class FakeSparkModule:
    """Stands in for ``pyspark.sql.SparkSession``: a new builder per access."""

    def __init__(self):
        self.sessions = []
        self.fail_with = None
        self.refused = set()

    @property
    def builder(self):
        return FakeSparkBuilder(self)


@pytest.fixture
def fake_spark(monkeypatch):
    module = FakeSparkModule()
    pyspark = types.ModuleType("pyspark")
    pyspark_sql = types.ModuleType("pyspark.sql")
    pyspark_sql.SparkSession = module
    pyspark.sql = pyspark_sql
    monkeypatch.setitem(sys.modules, "pyspark", pyspark)
    monkeypatch.setitem(sys.modules, "pyspark.sql", pyspark_sql)
    monkeypatch.setattr(stardelt, "_SPARK_SESSION", None)
    monkeypatch.setattr(stardelt, "_SPARK_TOKEN", None)
    monkeypatch.setenv("SPARK_REMOTE", "sc://spark.example:15002")
    monkeypatch.delenv("STARDELT_CATALOG_URI", raising=False)
    monkeypatch.delenv("STARDELT_S3_ENDPOINT", raising=False)
    return module


def _catalogs(*names):
    return pd.DataFrame({"Catalog": list(names)})


@pytest.fixture
def visible_catalogs(monkeypatch):
    monkeypatch.setattr(stardelt, "sql", lambda _query: _catalogs("warehouse", "bronze"))
    monkeypatch.setattr(stardelt, "_token", lambda: "canary-token-317")
    return ["warehouse", "bronze"]


def test_sets_catalog_conf_for_visible_names_only(fake_spark, visible_catalogs):
    session = stardelt.spark("app")
    assert session.configs["spark.remote"] == "sc://spark.example:15002"
    assert session.configs["spark.app.name"] == "app"
    for name in ("warehouse", "bronze"):
        assert (
            session.configs[f"spark.sql.catalog.{name}"]
            == "org.apache.iceberg.spark.SparkCatalog"
        )
        assert session.configs[f"spark.sql.catalog.{name}.type"] == "rest"
        assert session.configs[f"spark.sql.catalog.{name}.warehouse"] == name
        assert session.configs[f"spark.sql.catalog.{name}.token"] == "canary-token-317"
        assert (
            session.configs[f"spark.sql.catalog.{name}.io-impl"]
            == "org.apache.iceberg.aws.s3.S3FileIO"
        )
    assert session.configs["spark.sql.catalog.warehouse.uri"] == stardelt.CATALOG_URI_DEFAULT
    assert (
        session.configs["spark.sql.catalog.warehouse.s3.endpoint"]
        == stardelt.S3_ENDPOINT_DEFAULT
    )
    assert session.configs["spark.sql.catalog.warehouse.s3.region"] == "us-east-1"
    assert session.configs["spark.sql.catalog.warehouse.s3.path-style-access"] == "true"
    assert "spark.sql.catalog.system" not in session.configs
    assert set(session.catalog.loaded) == {"warehouse", "bronze"}
    assert session.catalog.current == "warehouse"


def test_hidden_and_invalid_names_skipped(fake_spark, monkeypatch):
    monkeypatch.setattr(
        stardelt,
        "sql",
        lambda _query: _catalogs(
            "warehouse", "system", "information_schema", "memory", "tpch", "tpcds", "jmx",
            "Upper", "a" * 41, "ok9",
        ),
    )
    monkeypatch.setattr(stardelt, "_token", lambda: "canary-token-317")
    session = stardelt.spark()
    configured = {
        key[len("spark.sql.catalog."):]
        for key in session.configs
        if key.startswith("spark.sql.catalog.") and key.count(".") == 3
    }
    assert configured == {"warehouse", "ok9"}
    assert set(session.catalog.loaded) == {"warehouse", "ok9"}
    assert session.catalog.current == "warehouse"


def test_refused_catalog_is_not_loaded_but_others_are(fake_spark, monkeypatch):
    fake_spark.refused = {"bronze"}
    monkeypatch.setattr(stardelt, "_token", lambda: "canary-token-317")
    monkeypatch.setattr(stardelt, "sql", lambda _query: _catalogs("warehouse", "bronze"))
    session = stardelt.spark()
    assert "warehouse" in session.catalog.loaded
    assert "bronze" not in session.catalog.loaded
    assert session.catalog.current == "warehouse"


def test_token_in_conf_never_printed_or_in_errors(
    fake_spark, visible_catalogs, capsys, monkeypatch
):
    token = "canary-token-in-error-8f2c"
    fake_spark.fail_with = f"the client refused {token}"
    monkeypatch.setattr(stardelt, "_token", lambda: token)
    with pytest.raises(RuntimeError) as exc:
        stardelt.spark()
    captured = capsys.readouterr()
    assert token not in str(exc.value)
    assert token not in captured.out and token not in captured.err
    assert "the client refused" in str(exc.value)


def test_second_call_refreshes_token(fake_spark, monkeypatch):
    tokens = iter(["token-one-317", "token-two-317"])
    monkeypatch.setattr(stardelt, "_token", lambda: next(tokens))
    monkeypatch.setattr(stardelt, "sql", lambda _query: _catalogs("warehouse"))
    first = stardelt.spark()
    assert first.configs["spark.sql.catalog.warehouse.token"] == "token-one-317"
    second = stardelt.spark()
    assert second.configs["spark.sql.catalog.warehouse.token"] == "token-two-317"
    assert first.stopped
    assert len(fake_spark.sessions) == 2


# A cached session is only reused while the server still knows it: the driver can
# restart under a notebook (platform#377), and then the local `is_stopped` flag is
# still false while every call raises NO_ACTIVE_SESSION. The notice is one line and
# never carries the token or a catalog name.

NOTICE = "the Spark server restarted or closed the session"


def test_alive_cached_session_is_reused_and_nothing_printed(fake_spark, visible_catalogs, capsys):
    first = stardelt.spark()
    second = stardelt.spark()
    assert second is first
    assert len(fake_spark.sessions) == 1
    captured = capsys.readouterr()
    assert captured.out == "" and captured.err == ""


def test_stopped_cached_session_is_replaced_with_the_notice_once(
    fake_spark, visible_catalogs, capsys
):
    first = stardelt.spark()
    first.stopped = True
    second = stardelt.spark()
    assert second is not first
    assert first.stopped
    assert len(fake_spark.sessions) == 2
    assert stardelt._SPARK_SESSION is second
    # The replacement is live, so the next call reuses it and stays quiet.
    assert stardelt.spark() is second
    assert len(fake_spark.sessions) == 2
    assert capsys.readouterr().err.count(NOTICE) == 1


def test_version_failure_replaces_the_session(fake_spark, visible_catalogs, capsys):
    first = stardelt.spark()
    first.broken = True  # the driver restarted: the client is closed, the flag is not
    assert first.is_stopped is False
    second = stardelt.spark()
    assert second is not first
    assert len(fake_spark.sessions) == 2
    assert stardelt._SPARK_SESSION is second
    assert NOTICE in capsys.readouterr().err


def test_dead_session_is_stopped_best_effort_even_if_stop_raises(
    fake_spark, visible_catalogs, capsys, monkeypatch
):
    first = stardelt.spark()
    first.broken = True
    calls = []

    def exploding_stop():
        calls.append(True)
        raise RuntimeError("the client is already gone")

    monkeypatch.setattr(first, "stop", exploding_stop)
    second = stardelt.spark()
    assert calls == [True]
    assert second is not first
    assert len(fake_spark.sessions) == 2
    assert NOTICE in capsys.readouterr().err


def test_token_change_builds_a_new_session_without_the_notice(fake_spark, monkeypatch, capsys):
    tokens = iter(["token-one-377", "token-two-377"])
    monkeypatch.setattr(stardelt, "_token", lambda: next(tokens))
    monkeypatch.setattr(stardelt, "sql", lambda _query: _catalogs("warehouse"))
    first = stardelt.spark()
    second = stardelt.spark()
    assert second is not first
    assert second.configs["spark.sql.catalog.warehouse.token"] == "token-two-377"
    assert NOTICE not in capsys.readouterr().err


def test_notice_contains_no_token_and_no_catalog_name(fake_spark, visible_catalogs, capsys):
    first = stardelt.spark()
    first.broken = True
    stardelt.spark()
    err = capsys.readouterr().err
    assert NOTICE in err
    assert "canary-token-317" not in err
    assert "warehouse" not in err and "bronze" not in err


def test_trino_down_falls_back_to_warehouse(fake_spark, monkeypatch, capsys):
    def boom(_query):
        raise RuntimeError("Trino is down")

    monkeypatch.setattr(stardelt, "sql", boom)
    monkeypatch.setattr(stardelt, "_token", lambda: "canary-token-317")
    session = stardelt.spark()
    configured = {
        key[len("spark.sql.catalog."):]
        for key in session.configs
        if key.startswith("spark.sql.catalog.") and key.count(".") == 3
    }
    assert configured == {"warehouse"}
    assert "only the warehouse catalog" in capsys.readouterr().err
    assert "canary-token-317" not in capsys.readouterr().err


def test_default_catalog_warehouse_when_present(fake_spark, monkeypatch):
    monkeypatch.setattr(stardelt, "_token", lambda: "canary-token-317")
    monkeypatch.setattr(stardelt, "sql", lambda _query: _catalogs("bronze"))
    assert "spark.sql.defaultCatalog" not in stardelt.spark().configs
    stardelt._SPARK_SESSION = None
    monkeypatch.setattr(stardelt, "sql", lambda _query: _catalogs("warehouse", "bronze"))
    assert stardelt.spark().configs["spark.sql.defaultCatalog"] == "warehouse"


def test_env_overrides_for_uri_and_s3(fake_spark, visible_catalogs, monkeypatch):
    monkeypatch.setenv("STARDELT_CATALOG_URI", "http://catalog.example:8181/catalog")
    monkeypatch.setenv("STARDELT_S3_ENDPOINT", "http://s3.example:8333")
    session = stardelt.spark()
    assert session.configs["spark.sql.catalog.warehouse.uri"] == "http://catalog.example:8181/catalog"
    assert session.configs["spark.sql.catalog.bronze.s3.endpoint"] == "http://s3.example:8333"
