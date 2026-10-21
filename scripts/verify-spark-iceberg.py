#!/usr/bin/env python3
"""Prove that Spark Connect and Trino read/write the same Iceberg table.

Run from a pod that can reach both services, with the Spark Connect client
installed (it does not need a Spark installation) and the person's token in
`TRINO_TOKEN` (or `SPARK_CATALOG_TOKEN` for the catalog only):

    pip install pyspark-client==4.1.3
    SPARK_REMOTE=sc://spark-connect.stardelt.svc.cluster.local:15002 \
    TRINO_URL=https://trino.stardelt.svc.cluster.local:8443 \
    REQUESTS_CA_BUNDLE=/etc/stardelt/trino-ca/ca.crt \
    TRINO_TOKEN="$(...)" \
      python3 scripts/verify-spark-iceberg.py

The static `warehouse` catalog is gone from the Spark driver (platform#317):
the session is built here with the same `spark.sql.catalog.warehouse*` block
`stardelt.spark()` uses, including `.token`. Lakekeeper decides what the token
may read; the token must carry `aud=lakekeeper` (hub and dev tokens get it from
`make sync-catalog-audience`). No token is printed.

What it checks:

  1. `VERIFY_TABLE` (default `warehouse.covid.covid_summary`, the demo tables
     were removed on 2026-10-21): `count(*)` and `GROUP BY` from Spark and from
     Trino agree row for row.
  2. A table written by Trino is readable from Spark.
  3. A table written by Spark is readable from Trino.
  4. The scratch namespace `spark_verify` is dropped again.

Trino is queried with the same `TRINO_TOKEN` as a bearer; `TRINO_USER` /
`TRINO_PASSWORD` (HTTP Basic) and anonymous access remain available for the
older in-cluster shapes. Exit status is non-zero if anything disagrees — this is
meant to be run, not read.
"""

from __future__ import annotations

import base64
import json
import os
import ssl
import sys
import urllib.request

SPARK_REMOTE = os.environ.get("SPARK_REMOTE", "sc://spark-connect.stardelt.svc.cluster.local:15002")
TRINO_URL = os.environ.get("TRINO_URL", "http://trino.stardelt.svc.cluster.local:8080").rstrip("/")
TRINO_USER = os.environ.get("TRINO_USER", "spark-verify")
TRINO_PASSWORD = os.environ.get("TRINO_PASSWORD", "")
TRINO_TOKEN = os.environ.get("TRINO_TOKEN", "").strip()
CATALOG_TOKEN = os.environ.get("SPARK_CATALOG_TOKEN", "").strip() or TRINO_TOKEN
TRINO_CA = os.environ.get("TRINO_CA", os.environ.get("REQUESTS_CA_BUNDLE", "")).strip()
CATALOG_URI = os.environ.get(
    "STARDELT_CATALOG_URI", "http://lakekeeper.stardelt.svc.cluster.local:8181/catalog"
)
S3_ENDPOINT = os.environ.get(
    "STARDELT_S3_ENDPOINT", "http://seaweedfs-s3.stardelt.svc.cluster.local:8333"
)
TABLE = os.environ.get("VERIFY_TABLE", "warehouse.covid.covid_summary")
GROUP_COLUMN = os.environ.get("VERIFY_GROUP_COLUMN", "country")
SCRATCH = "warehouse.spark_verify"

failures: list[str] = []

_SSL = ssl.create_default_context(cafile=TRINO_CA or None) if TRINO_URL.startswith("https") else None


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
    if not ok:
        failures.append(label)


def _open(request: urllib.request.Request):
    return urllib.request.urlopen(request, timeout=120, context=_SSL)


def trino(sql: str) -> list[list[object]]:
    """Run one statement and return its rows (following nextUri)."""
    # With a bearer, Trino takes the session user from the token and refuses a
    # declared user that differs ("cannot impersonate"); only the anonymous and
    # Basic paths name one.
    headers = {"Content-Type": "text/plain"}
    if TRINO_TOKEN:
        headers["Authorization"] = f"Bearer {TRINO_TOKEN}"
    else:
        headers["X-Trino-User"] = TRINO_USER
        if TRINO_PASSWORD:
            token = base64.b64encode(f"{TRINO_USER}:{TRINO_PASSWORD}".encode()).decode()
            headers["Authorization"] = f"Basic {token}"

    request = urllib.request.Request(
        f"{TRINO_URL}/v1/statement", data=sql.encode(), method="POST", headers=headers
    )
    with _open(request) as response:
        body = json.load(response)

    rows: list[list[object]] = list(body.get("data") or [])
    while body.get("nextUri"):
        if body.get("error"):
            raise RuntimeError(json.dumps(body["error"], default=str)[:500])
        with _open(body["nextUri"]) as response:
            body = json.load(response)
        rows.extend(body.get("data") or [])
    if body.get("error"):
        raise RuntimeError(json.dumps(body["error"], default=str)[:500])
    return rows


def spark_rows(spark, sql: str) -> list[tuple]:
    return [tuple(row) for row in spark.sql(sql).collect()]


def spark_exec(spark, sql: str) -> None:
    """Run a DDL/DML statement. Connect plans are lazy, so collect to execute."""
    spark.sql(sql).collect()


def spark_session():
    """A Connect session with `warehouse` configured like `stardelt.spark()` does."""
    if not CATALOG_TOKEN:
        raise SystemExit(
            "verify-spark-iceberg: set TRINO_TOKEN (the signed-in person) or "
            "SPARK_CATALOG_TOKEN — the driver has no static catalog since platform#317."
        )
    from pyspark.sql import SparkSession  # imported late so `--help` stays cheap

    builder = SparkSession.builder.remote(SPARK_REMOTE).appName("verify-spark-iceberg")
    builder = builder.config(
        "spark.sql.catalog.warehouse", "org.apache.iceberg.spark.SparkCatalog"
    )
    for key, value in (
        ("type", "rest"),
        ("uri", CATALOG_URI),
        ("warehouse", "warehouse"),
        ("token", CATALOG_TOKEN),
        ("io-impl", "org.apache.iceberg.aws.s3.S3FileIO"),
        ("s3.endpoint", S3_ENDPOINT),
        ("s3.region", "us-east-1"),
        ("s3.path-style-access", "true"),
    ):
        builder = builder.config(f"spark.sql.catalog.warehouse.{key}", value)
    return builder.create()


def main() -> int:
    spark = spark_session()
    print(f"› Spark Connect: {SPARK_REMOTE}")
    print(f"› Trino:         {TRINO_URL}")
    print(f"› Table:         {TABLE}")
    print(f"› Spark version: {spark.version}")

    try:
        print(f"\n1. {TABLE} — Spark vs Trino")
        spark_count = spark_rows(spark, f"SELECT count(*) AS n FROM {TABLE}")[0][0]
        trino_count = trino(f"SELECT count(*) FROM {TABLE}")[0][0]
        print(f"  count(*) spark={spark_count} trino={trino_count}")
        check("count(*) agrees", int(spark_count) == int(trino_count))

        groupby_sql = (
            f"SELECT {GROUP_COLUMN}, count(*) AS n FROM {TABLE} "
            f"GROUP BY {GROUP_COLUMN} ORDER BY {GROUP_COLUMN}"
        )
        spark_groups = spark_rows(spark, groupby_sql)
        trino_groups = [tuple(row) for row in trino(groupby_sql)]
        print(f"  spark: {spark_groups}")
        print(f"  trino: {trino_groups}")
        check(f"GROUP BY {GROUP_COLUMN} agrees", spark_groups == trino_groups)

        print(f"\n2. a table written by Trino, read from Spark ({SCRATCH}.from_trino)")
        try:
            trino(f"CREATE SCHEMA IF NOT EXISTS {SCRATCH}")
            trino(f"CREATE TABLE {SCRATCH}.from_trino (id BIGINT, note VARCHAR)")
            trino(f"INSERT INTO {SCRATCH}.from_trino VALUES (1, 'from-trino'), (2, 'from-trino')")
            from_trino = spark_rows(
                spark, f"SELECT id, note FROM {SCRATCH}.from_trino ORDER BY id"
            )
            print(f"  spark reads: {from_trino}")
            check(
                "Spark reads Trino's table",
                from_trino == [(1, "from-trino"), (2, "from-trino")],
            )

            print(f"\n3. a table written by Spark, read from Trino ({SCRATCH}.from_spark)")
            spark_exec(
                spark, f"CREATE TABLE {SCRATCH}.from_spark (id BIGINT, note STRING) USING iceberg"
            )
            spark_exec(
                spark,
                f"INSERT INTO {SCRATCH}.from_spark VALUES (10, 'from-spark'), (20, 'from-spark')",
            )
            from_spark = [tuple(row) for row in trino(f"SELECT id, note FROM {SCRATCH}.from_spark ORDER BY id")]
            print(f"  trino reads: {from_spark}")
            check(
                "Trino reads Spark's table",
                from_spark == [(10, "from-spark"), (20, "from-spark")],
            )
        finally:
            print(f"\n4. cleaning up {SCRATCH}")
            for statement in (
                f"DROP TABLE IF EXISTS {SCRATCH}.from_trino",
                f"DROP TABLE IF EXISTS {SCRATCH}.from_spark",
                f"DROP NAMESPACE IF EXISTS {SCRATCH}",
            ):
                try:
                    spark_exec(spark, statement)
                except Exception as exc:  # report, do not mask the real failure
                    print(f"  cleanup: {statement} -> {type(exc).__name__}: {exc}")
    finally:
        spark.stop()

    if failures:
        print(f"\nverify-spark-iceberg: FAILED ({', '.join(failures)})")
        return 1
    print("\nverify-spark-iceberg: OK — two-way Iceberg round trip and Trino parity")
    return 0


if __name__ == "__main__":
    sys.exit(main())
