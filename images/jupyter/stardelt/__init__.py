"""stardelt — the small helper between a notebook and the warehouse.

Every notebook used to start with the same 30 lines: read the signed-in
user's token out of the environment, build a Trino connection around it,
point at the in-cluster TLS endpoint — and there was no governed way to get
a pandas DataFrame *into* an Iceberg table. This package is that loop, short:

    import stardelt

    trips = stardelt.sql("SELECT * FROM warehouse.demo.trips LIMIT 10")
    stardelt.write_df(trips, "warehouse.demo.trips_sample", mode="create")
    spark = stardelt.spark()  # Spark Connect, for what does not fit write_df

Identity comes from the pod, never from an argument: JupyterHub copies the
signed-in user's Keycloak access token into the single-user server as
``TRINO_TOKEN`` at spawn (helm-values/jupyterhub.yaml,
``20-notebook-identity``), ``TRINO_URL`` is the coordinator endpoint, and the
internal CA arrives through ``REQUESTS_CA_BUNDLE``. Trino therefore runs every
statement as the person behind the keyboard — row and column policy applies,
and the audit trail names them. Nothing is baked into the image.

SPDX-License-Identifier: MIT
"""

import base64
import datetime
import json
import math
import os
import uuid
from urllib.parse import urlsplit

import pandas as pd
from trino.auth import JWTAuthentication
from trino.dbapi import connect as _trino_connect

__version__ = "0.1.0"

__all__ = ["sql", "write_df", "spark", "connection"]

# write_df refuses more than this many rows: above it the per-batch INSERT
# path is the wrong tool (slow, one HTTP round trip per batch) and the right
# one is stardelt.spark(). The number is a guardrail, not a benchmark.
MAX_WRITE_ROWS = 200_000

DEFAULT_BATCH_ROWS = 1_000

# Where spark() connects when the spawn did not say otherwise. Matches the
# ClusterIP-only Spark Connect Service (manifests/spark.yaml): reachable from
# a user pod through the egress rule in helm-values/jupyterhub.yaml, and from
# nowhere else, because Spark Connect has no authentication of its own.
SPARK_REMOTE_DEFAULT = "sc://spark-connect.stardelt.svc.cluster.local:15002"


def _token_username(token):
    """The username inside the JWT, without verifying it (Trino verifies)."""
    if not token or token.count(".") != 2:
        return None
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(payload)).get("preferred_username")
    except (ValueError, UnicodeDecodeError):
        return None


def _connect():
    """A Trino connection as the signed-in hub user. Raises a one-line error."""
    url = os.environ.get("TRINO_URL", "").strip()
    if not url:
        raise RuntimeError("TRINO_URL is not set — this notebook is not running on the platform.")
    token = os.environ.get("TRINO_TOKEN", "").strip()
    if not token:
        raise RuntimeError("TRINO_TOKEN is not set — restart this server from the hub so it picks up your sign-in token.")
    user = (
        os.environ.get("JUPYTERHUB_USER", "").strip()
        or _token_username(token)
        or "notebook"
    )
    # Trino denies a request whose declared user differs from the token's
    # ("user X cannot impersonate user Y"), so the client user is the token's own.
    parts = urlsplit(url)
    return _trino_connect(
        host=parts.hostname,
        port=parts.port or (443 if parts.scheme == "https" else 8080),
        http_scheme=parts.scheme,
        auth=JWTAuthentication(token),
        user=user,
        source="stardelt-notebook-helper",
    )


def _one_line(exc):
    text = str(exc).strip().splitlines()
    return text[0] if text else type(exc).__name__


def sql(query, params=None):
    """Run ``query`` as the signed-in hub user, return the rows as a DataFrame.

    ``params`` are bound parameters for the query's ``?`` placeholders — never
    string-interpolated values, so a cell can pass user input without building
    SQL by hand. Failures raise a one-line ``RuntimeError`` (chained to the
    original, so the full trace is one ``__cause__`` away).
    """
    conn = _connect()
    try:
        cur = conn.cursor()
        try:
            if params is None:
                cur.execute(query)
            else:
                cur.execute(query, params)
            columns = [d[0] for d in (cur.description or [])]
            return pd.DataFrame(cur.fetchall(), columns=columns)
        except Exception as exc:  # noqa: BLE001 - wrapped into the one-line error below
            raise RuntimeError(f"stardelt.sql failed: {_one_line(exc)}") from exc
        finally:
            cur.close()
    finally:
        conn.close()


def _quote_ident(name):
    """Quote one identifier part: double quotes, embedded ones doubled."""
    return '"' + name.replace('"', '""') + '"'


def _split_table(table):
    """``"schema.table"`` (or ``"catalog.schema.table"``) into quoted parts."""
    parts = table.split(".")
    if len(parts) not in (2, 3) or not all(p.strip() for p in parts):
        raise ValueError(
            f"stardelt.write_df: table must look like 'schema.table', got {table!r}."
        )
    return ".".join(_quote_ident(p.strip()) for p in parts)


def _trino_type(series):
    """Map a DataFrame column's dtype to a Trino type, or a one-line error."""
    name = series.name
    dtype = series.dtype
    if pd.api.types.is_bool_dtype(dtype):
        return "BOOLEAN"
    if pd.api.types.is_integer_dtype(dtype):
        # Trino has no unsigned types; a UInt64 that overflows BIGINT fails at
        # INSERT with the value in the message, which beats guessing here.
        return "INTEGER" if dtype.itemsize <= 4 else "BIGINT"
    if pd.api.types.is_float_dtype(dtype):
        return "REAL" if dtype.itemsize <= 4 else "DOUBLE"
    if pd.api.types.is_datetime64_any_dtype(dtype):
        tz = getattr(dtype, "tz", None)
        return "TIMESTAMP WITH TIME ZONE" if tz is not None else "TIMESTAMP"
    if isinstance(dtype, pd.CategoricalDtype):
        raise TypeError(
            f"stardelt.write_df: column {name!r} is categorical — convert it with .astype(str) first."
        )
    if pd.api.types.is_string_dtype(dtype) or pd.api.types.is_object_dtype(dtype):
        non_null = series.dropna()
        bad = [v for v in non_null.tolist() if not isinstance(v, str)]
        if bad:
            raise TypeError(
                f"stardelt.write_df: column {name!r} holds non-string values "
                f"(e.g. {type(bad[0]).__name__}) — convert or drop them first."
            )
        return "VARCHAR"
    raise TypeError(
        f"stardelt.write_df: column {name!r} has unsupported dtype {dtype}."
    )


def _clean(value):
    """Make one cell JSON-safe for the Trino client: nulls to None, numpy to plain Python."""
    if value is None:
        return None
    if isinstance(value, float) and math.isnan(value):
        return None
    if value is pd.NA or value is pd.NaT:
        return None
    if isinstance(value, pd.Timestamp):
        return value.to_pydatetime()
    if hasattr(value, "item") and not isinstance(value, str):
        try:
            return value.item()
        except (ValueError, AttributeError):
            return value
    return value


def write_df(df, table, mode="append", batch_rows=DEFAULT_BATCH_ROWS, bronze=False, source="notebook"):
    """Write ``df`` to ``"schema.table"`` in the warehouse, return rows written.

    ``table`` may also name the catalog (``"catalog.schema.table"``, as in
    ``"warehouse.demo.trips"``); without one Trino uses the session default.

    The governed write path: ``CREATE TABLE`` is derived from the DataFrame's
    dtypes (booleans to BOOLEAN, ints to INTEGER/BIGINT, floats to
    REAL/DOUBLE, datetimes to TIMESTAMP, strings to VARCHAR), then rows go in
    as batched ``INSERT INTO ... VALUES`` with bound parameters — values are
    never interpolated into SQL text. Identifier parts (schema, table,
    columns) are double-quoted.

    Modes: ``"append"`` creates the table if needed and adds rows;
    ``"overwrite"`` drops it first and writes fresh; ``"create"`` fails if the
    table already exists. ``batch_rows`` caps the rows per INSERT statement.

    More than 200,000 rows are refused with an error that points at
    ``stardelt.spark()`` — bulk loads belong on the engine, not on batched
    INSERTs. With ``bronze=True`` exactly three ingestion columns are
    appended — ``_ingested_at`` (now, UTC), ``_source`` (``source``),
    ``_batch_id`` (a fresh UUID per call) — and nothing else is added
    implicitly: without ``bronze`` the frame lands exactly as given.
    """
    if mode not in ("append", "overwrite", "create"):
        raise ValueError(
            f"stardelt.write_df: mode must be 'append', 'overwrite' or 'create', got {mode!r}."
        )
    if not isinstance(batch_rows, int) or isinstance(batch_rows, bool) or batch_rows < 1:
        raise ValueError(
            f"stardelt.write_df: batch_rows must be a positive integer, got {batch_rows!r}."
        )
    qualified = _split_table(table)
    n = len(df)
    if n > MAX_WRITE_ROWS:
        raise ValueError(
            f"stardelt.write_df refuses {n} rows (limit {MAX_WRITE_ROWS}) — "
            "use stardelt.spark() for bulk loads."
        )
    cols = list(df.columns)
    if any(not isinstance(c, str) for c in cols):
        raise ValueError("stardelt.write_df: every column must have a string name.")
    if len(set(cols)) != len(cols):
        raise ValueError("stardelt.write_df: column names must be unique.")

    if bronze:
        extra = ("_ingested_at", "_source", "_batch_id")
        clash = [c for c in extra if c in df.columns]
        if clash:
            raise ValueError(
                f"stardelt.write_df: bronze=True would overwrite existing column(s) {clash}."
            )
        df = df.copy()
        df["_ingested_at"] = datetime.datetime.now(datetime.timezone.utc)
        df["_source"] = str(source)
        df["_batch_id"] = uuid.uuid4().hex
        cols = list(df.columns)

    col_defs = ", ".join(f"{_quote_ident(c)} {_trino_type(df[c])}" for c in cols)
    col_list = ", ".join(_quote_ident(c) for c in cols)

    statements = []
    if mode == "overwrite":
        statements.append(f"DROP TABLE IF EXISTS {qualified}")
        statements.append(f"CREATE TABLE {qualified} ({col_defs})")
    elif mode == "append":
        statements.append(f"CREATE TABLE IF NOT EXISTS {qualified} ({col_defs})")
    else:
        statements.append(f"CREATE TABLE {qualified} ({col_defs})")

    batches = []
    for start in range(0, n, batch_rows):
        chunk = df.iloc[start:start + batch_rows]
        rows = [[_clean(v) for v in row] for row in chunk.itertuples(index=False, name=None)]
        placeholders = ", ".join(
            "(" + ", ".join(["?"] * len(cols)) + ")" for _ in rows
        )
        batches.append((
            f"INSERT INTO {qualified} ({col_list}) VALUES {placeholders}",
            [p for row in rows for p in row],
        ))

    conn = _connect()
    try:
        cur = conn.cursor()
        try:
            for statement in statements:
                cur.execute(statement)
            for statement, params in batches:
                cur.execute(statement, params)
        except Exception as exc:  # noqa: BLE001 - wrapped into the one-line error below
            raise RuntimeError(f"stardelt.write_df failed: {_one_line(exc)}") from exc
        finally:
            cur.close()
    finally:
        conn.close()
    return n


def spark(app_name="stardelt-notebook"):
    """Open a Spark Connect session against the platform's Spark, return it.

    Reads ``SPARK_REMOTE`` (default the in-cluster Connect endpoint). For
    bulk writes and heavy compute — the path ``write_df`` points at past
    200,000 rows.

    Limitation, stated rather than implied: Spark reaches storage through the
    cluster's shared storage credential, so tables written through this
    session are NOT subject to the per-user table permissions that govern
    Trino. ``stardelt.sql`` and ``stardelt.write_df`` run as the signed-in
    user; ``stardelt.spark()`` does not.
    """
    from pyspark.sql import SparkSession

    remote = os.environ.get("SPARK_REMOTE", SPARK_REMOTE_DEFAULT).strip()
    if not remote:
        raise RuntimeError("SPARK_REMOTE is not set — point it at the Spark Connect endpoint.")
    return SparkSession.builder.remote(remote).appName(app_name).getOrCreate()


def connection(name, as_url=False):
    """Reserved for named connections. Not implemented yet."""
    raise NotImplementedError(
        "stardelt.connection() is not implemented yet — named connections arrive "
        "with the connections work; use stardelt.sql() and stardelt.write_df() until then."
    )
