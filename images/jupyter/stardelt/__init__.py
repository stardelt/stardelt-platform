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
and the audit trail names them. ``stardelt.spark()`` follows the same rule: it
configures the catalogs Trino lists for the person and sends that same token to
the catalog, which decides what the session may read. Nothing is baked into the
image.

SPDX-License-Identifier: MIT
"""

import base64
import datetime
import json
import math
import os
import re
import sys
import time
import uuid
from urllib.parse import urlsplit

import pandas as pd
import requests
from trino.auth import JWTAuthentication
from trino.dbapi import connect as _trino_connect

from stardelt.connections import ConnectionUnavailable, connection

__version__ = "0.1.0"

__all__ = ["sql", "write_df", "spark", "connection", "ConnectionUnavailable"]

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

# The catalog and the lakehouse data, as the in-cluster services name them.
# STARDELT_CATALOG_URI / STARDELT_S3_ENDPOINT override them for a split install.
CATALOG_URI_DEFAULT = "http://lakekeeper.stardelt.svc.cluster.local:8181/catalog"
S3_ENDPOINT_DEFAULT = "http://seaweedfs-s3.stardelt.svc.cluster.local:8333"

# Catalogs that belong to an engine, not to a person: Trino's system catalog,
# its metadata views, Spark's in-memory catalogs and the sample connectors.
HIDDEN_CATALOGS = frozenset({"system", "information_schema", "memory", "tpch", "tpcds", "jmx"})

# The same rule the operator's CatalogDomainSpec::validate and the access sync
# apply (`^[a-z][a-z0-9]{0,39}$`); a name Trino would accept but the platform
# would not is skipped rather than turned into a Spark property.
CATALOG_NAME_RE = re.compile(r"^[a-z][a-z0-9]{0,39}$")

# The session spark() built last, and the token it was built with. A renewed
# token means a new session: Spark reads `spark.sql.catalog.*` when it creates
# the session state, so an already-initialized catalog cannot be re-keyed. A
# session the server no longer knows is cleared here too (see
# `_cached_spark_session`): the driver may have restarted under it.
_SPARK_SESSION = None
_SPARK_TOKEN = None

# A pipeline pod has no hub behind it: when its token ages out, the grant that issued it is
# the only way to get another one. Renew this long before `exp` so no statement races the
# expiry (a statement is authenticated once, when it is submitted).
TOKEN_REFRESH_SKEW_SECONDS = 60


def _expiry(token):
    """The `exp` claim of a JWT, or ``None`` when the token does not carry one."""
    if not token or token.count(".") != 2:
        return None
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    try:
        expiry = json.loads(base64.urlsafe_b64decode(payload)).get("exp")
    except (ValueError, UnicodeDecodeError):
        return None
    return float(expiry) if isinstance(expiry, (int, float)) else None


def _can_refresh():
    """Whether this pod holds pipeline credentials: a client-credentials grant, not a person."""
    return bool(
        os.environ.get("PIPELINE_TOKEN_URL", "").strip()
        and os.environ.get("PIPELINE_CLIENT_SECRET", "").strip()
    )


def _fetch_token():
    """A fresh token for the pod's own principal, from the client-credentials grant."""
    client_id = os.environ.get("PIPELINE_CLIENT_ID", "").strip() or "pipeline-runner"
    response = requests.post(
        os.environ["PIPELINE_TOKEN_URL"].strip(),
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": os.environ["PIPELINE_CLIENT_SECRET"].strip(),
        },
        timeout=15,
    )
    if response.status_code != 200:
        raise RuntimeError(f"the token endpoint refused {client_id!r} (HTTP {response.status_code})")
    return response.json()["access_token"]


def _token():
    """The token for the next statement, renewed when it is within the skew of expiry.

    Hub pod: the token is the signed-in person's and only the hub can renew it, so an
    expired one is a clear message, not a request a person cannot answer.
    Pipeline pod: the token came from the pod's own client-credentials grant, so the same
    grant gets another one. The new token replaces ``TRINO_TOKEN`` so ``stardelt.connection()``
    (which reads the environment) uses the same one.
    """
    token = os.environ.get("TRINO_TOKEN", "").strip()
    expiry = _expiry(token)
    if token and (expiry is None or expiry - time.time() > TOKEN_REFRESH_SKEW_SECONDS):
        return token
    if not _can_refresh():
        if not token:
            raise RuntimeError(
                "TRINO_TOKEN is not set — restart this server from the hub so it picks up your sign-in token."
            )
        raise RuntimeError(
            "TRINO_TOKEN has expired and this pod has no pipeline credentials to renew it — "
            "restart this server from the hub."
        )
    token = _fetch_token()
    os.environ["TRINO_TOKEN"] = token
    return token


def _connect():
    """A Trino connection as the signed-in hub user. Raises a one-line error."""
    url = os.environ.get("TRINO_URL", "").strip()
    if not url:
        raise RuntimeError("TRINO_URL is not set — this notebook is not running on the platform.")
    token = _token()
    # No declared user on purpose: Trino takes the session user from the token's principal
    # (`preferred_username` or `sub`, whatever the platform configured), and denies a request
    # whose declared user differs from it ("user X cannot impersonate user Y").
    parts = urlsplit(url)
    return _trino_connect(
        host=parts.hostname,
        port=parts.port or (443 if parts.scheme == "https" else 8080),
        http_scheme=parts.scheme,
        auth=JWTAuthentication(token),
        source="stardelt-notebook-helper",
    )


def _one_line(exc):
    text = str(exc).strip().splitlines()
    return text[0] if text else type(exc).__name__


def _redact(text, secret):
    """Remove a credential from a message before it can reach a notebook or a log."""
    return text.replace(secret, "<token>") if secret else text


def _record_query_id(cur):
    """Note a statement id so a stopped notebook task can cancel it.

    A stop deletes the pod: the kernel dies, but a statement Trino already accepted keeps
    running for about five minutes (spike #267). The wrapper (``stardelt.notebook_run``) reads
    this file on SIGTERM and deletes each id as the same principal. The file is named by
    ``STARDELT_QUERY_IDS``; without it (an interactive hub pod) nothing is written, and no
    failure of this bookkeeping may ever fail the statement it belongs to.
    """
    path = os.environ.get("STARDELT_QUERY_IDS", "").strip()
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{getattr(cur, 'query_id', None)}\n")
            handle.flush()
    except Exception:  # noqa: BLE001 - recording is best effort, never the statement's failure
        pass


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
            _record_query_id(cur)
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
                _record_query_id(cur)
            for statement, params in batches:
                cur.execute(statement, params)
                _record_query_id(cur)
        except Exception as exc:  # noqa: BLE001 - wrapped into the one-line error below
            raise RuntimeError(f"stardelt.write_df failed: {_one_line(exc)}") from exc
        finally:
            cur.close()
    finally:
        conn.close()
    return n


def _catalog_names():
    """The catalogs Trino lists for the signed-in person, minus engine-only ones.

    Trino decides *visibility* (the ``Catalog`` objects render into its catalogs,
    and its access control filters them); Lakekeeper decides *access* and answers
    the first catalog call with the person's token. A name the platform would
    reject is dropped here too, so a stray catalog cannot become a Spark property.

    If Trino cannot be reached, only ``warehouse`` is configured: it is the one
    catalog every install has. The message never carries the token.
    """
    try:
        frame = sql("SHOW CATALOGS")
    except Exception:  # noqa: BLE001 - Spark-only work must survive a Trino outage
        print(
            "stardelt.spark: Trino is not reachable — configuring only the warehouse catalog.",
            file=sys.stderr,
        )
        return ["warehouse"]
    if frame is None or len(frame) == 0 or len(frame.columns) == 0:
        return []
    return [
        name
        for name in (str(n) for n in frame.iloc[:, 0].tolist())
        if name not in HIDDEN_CATALOGS and CATALOG_NAME_RE.match(name)
    ]


def _cached_spark_session(token):
    """The session `spark()` may reuse for ``token``, or ``None`` to build a new one.

    A cached session is only good while the server still knows it. ``is_stopped``
    is a local client flag: after the driver restarts the client closes itself and
    every call raises ``NO_ACTIVE_SESSION``, so liveness is proved by reading
    ``version``, which is a round trip. A dead session is dropped here (best-effort
    ``stop()``, one line on stderr) and the caller builds a fresh one.
    """
    global _SPARK_SESSION

    session = _SPARK_SESSION
    if session is None or _SPARK_TOKEN != token:
        return None
    try:
        if session.is_stopped:
            raise RuntimeError("the session is stopped")
        session.version
    except Exception:  # noqa: BLE001 - any failure here means "not usable"
        _SPARK_SESSION = None
        try:
            session.stop()
        except Exception:  # noqa: BLE001 - an already-gone client is not an error
            pass
        print(
            "stardelt.spark: the Spark server restarted or closed the session — "
            "opened a new one. DataFrames, temp views and settings of the old "
            "session are gone.",
            file=sys.stderr,
        )
        return None
    return session


def spark(app_name="stardelt-notebook"):
    """Open a Spark Connect session for bulk work, as the signed-in person.

    Spark now sees the catalogs you may see and the catalog checks your token;
    storage keys stay with the platform, so only use it where Trino cannot.

    The session is built from what Trino's ``SHOW CATALOGS`` returns for the
    person (engine-only names removed) and receives one Iceberg REST catalog per
    name, each with ``token=_token()``. Lakekeeper — the authority — then refuses
    a catalog the person has no grant on. ``STARDELT_CATALOG_URI`` and
    ``STARDELT_S3_ENDPOINT`` override the in-cluster catalog and S3 endpoints.

    The catalogs and the token are set on the new session before its first catalog
    call (Spark reads ``spark.sql.catalog.*`` then). Setting the token again on a
    live session does not re-key an initialized catalog, so a later call with a
    renewed token builds a new session and stops the previous one.

    If the Spark server restarted, the next call opens a new session; DataFrames and temp views of the old one are gone, and a running job is not retried.

    ``SPARK_REMOTE`` selects the endpoint (default the in-cluster Connect service).
    Limitations, stated rather than implied: Spark Connect has no authentication of
    its own and is ClusterIP-only, row/column masks are Trino-only (design
    ``multitenant-catalogs.md`` §5.8), and tables written through Spark use the
    cluster's shared storage credential — use Spark where Trino cannot, not to
    bypass a policy. Public S3 buckets are readable anonymously (``s3a://`` and
    ``s3://``); private buckets and the platform's own storage are not. The token is
    never printed or returned.
    """
    from pyspark.sql import SparkSession

    global _SPARK_SESSION, _SPARK_TOKEN

    remote = os.environ.get("SPARK_REMOTE", SPARK_REMOTE_DEFAULT).strip()
    if not remote:
        raise RuntimeError("SPARK_REMOTE is not set — point it at the Spark Connect endpoint.")

    names = _catalog_names()
    token = _token()
    cached = _cached_spark_session(token)
    if cached is not None:
        return cached

    catalog_uri = os.environ.get("STARDELT_CATALOG_URI", CATALOG_URI_DEFAULT).strip()
    s3_endpoint = os.environ.get("STARDELT_S3_ENDPOINT", S3_ENDPOINT_DEFAULT).strip()

    session = None
    try:
        # create(), not getOrCreate(): the latter returns the process-wide
        # session, so a second person's call would reuse the first person's
        # catalogs and token. A fresh Connect session is isolated server-side.
        session = SparkSession.builder.remote(remote).appName(app_name).create()
        for name in names:
            session.conf.set(
                f"spark.sql.catalog.{name}", "org.apache.iceberg.spark.SparkCatalog"
            )
            for key, value in (
                ("type", "rest"),
                ("uri", catalog_uri),
                ("warehouse", name),
                ("token", token),
                ("io-impl", "org.apache.iceberg.aws.s3.S3FileIO"),
                ("s3.endpoint", s3_endpoint),
                ("s3.region", "us-east-1"),
                ("s3.path-style-access", "true"),
            ):
                session.conf.set(f"spark.sql.catalog.{name}.{key}", value)
        if "warehouse" in names:
            session.conf.set("spark.sql.defaultCatalog", "warehouse")

        # Spark lists a catalog only after the session has loaded it. Load each
        # once so `SHOW CATALOGS` shows what the person may see, and leave one
        # the catalog refuses out (unless every one is refused: then the token
        # or the catalog is broken and the person sees the error, not an empty
        # session).
        loaded = []
        refusal = None
        for name in names:
            try:
                session.catalog.setCurrentCatalog(name)
                loaded.append(name)
            except Exception as exc:  # noqa: BLE001 - one refusal must not hide the rest
                refusal = exc
        if names and not loaded:
            if refusal is not None:
                raise refusal
            raise RuntimeError("no catalog loaded")
        target = "warehouse" if "warehouse" in loaded else (loaded[0] if loaded else None)
        if target is not None:
            session.catalog.setCurrentCatalog(target)
        missing = [name for name in names if name not in loaded]
        if missing:
            print(
                "stardelt.spark: the catalog refused "
                + ", ".join(missing)
                + " for this token — not loading it.",
                file=sys.stderr,
            )
    except Exception as exc:  # noqa: BLE001 - one line, and never the credential
        if session is not None:
            try:
                session.stop()
            except Exception:  # noqa: BLE001 - the original failure is the one to report
                pass
        raise RuntimeError(f"stardelt.spark failed: {_redact(_one_line(exc), token)}") from exc

    previous = _SPARK_SESSION
    _SPARK_SESSION, _SPARK_TOKEN = session, token
    if previous is not None:
        try:
            previous.stop()
        except Exception:  # noqa: BLE001 - an already-gone client is not an error
            pass
    return session
