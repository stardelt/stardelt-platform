"""Tests for the stardelt notebook helper (images/jupyter/stardelt/).

No warehouse needed: a stub Trino DBAPI connection stands in for the real
one (monkeypatched over ``stardelt._trino_connect``), so these run in CI.
What the stub cannot prove — real ``?`` parameters against Trino, the
round-trip dtypes — the dev-cluster check in the ticket covers.
"""

import base64
import json
import sys
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
    assert conn.kwargs["user"] == "analyst"


def test_sql_prefers_hub_user(trino, monkeypatch):
    monkeypatch.setenv("JUPYTERHUB_USER", "hub-person")
    stardelt.sql("SELECT 1")
    assert trino.instances[-1].kwargs["user"] == "hub-person"


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


def test_spark_reads_remote_from_env(trino, monkeypatch):
    seen = {}

    class FakeBuilder:
        def remote(self, url):
            seen["remote"] = url
            return self

        def appName(self, name):
            seen["app"] = name
            return self

        def getOrCreate(self):
            return "session"

    fake_sql = types.ModuleType("pyspark.sql")
    fake_sql.SparkSession = types.SimpleNamespace(builder=FakeBuilder())
    fake_pyspark = types.ModuleType("pyspark")
    monkeypatch.setitem(sys.modules, "pyspark", fake_pyspark)
    monkeypatch.setitem(sys.modules, "pyspark.sql", fake_sql)

    monkeypatch.setenv("SPARK_REMOTE", "sc://other:15002")
    assert stardelt.spark() == "session"
    assert seen == {"remote": "sc://other:15002", "app": "stardelt-notebook"}

    monkeypatch.delenv("SPARK_REMOTE")
    stardelt.spark()
    assert seen["remote"] == stardelt.SPARK_REMOTE_DEFAULT


def test_spark_docstring_states_credential_limitation():
    assert "shared storage credential" in stardelt.spark.__doc__
