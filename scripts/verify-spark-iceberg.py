#!/usr/bin/env python3
"""Prove that Spark Connect and Trino read/write the same Iceberg tables.

Run from a pod that can reach both services, with the Spark Connect client
installed (it does not need a Spark installation):

    pip install pyspark-client==4.1.3
    SPARK_REMOTE=sc://spark-connect.stardelt.svc.cluster.local:15002 \
    TRINO_URL=http://trino.stardelt.svc.cluster.local:8080 \
      python3 scripts/verify-spark-iceberg.py

What it checks:

  1. `warehouse.demo.trips`: `count(*)` and `GROUP BY borough` from Spark and
     from Trino agree row for row.
  2. A table written by Trino is readable from Spark.
  3. A table written by Spark is readable from Trino.
  4. The scratch namespace `spark_verify` is dropped again.

`demo` is only read. The two round-trip tables live in `warehouse.spark_verify`
and are dropped at the end (also when a check fails). Exit status is non-zero if
anything disagrees — this is meant to be run, not read.

Trino is queried without credentials because the dev cluster currently serves
`/v1/statement` anonymously in-cluster; pass TRINO_USER/TRINO_PASSWORD to use
HTTP Basic instead. Basic over plain HTTP is refused by Trino's password
authenticator unless the ingress terminates TLS, which is why the default is
the in-cluster anonymous path and not an invented token flow.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.request

SPARK_REMOTE = os.environ.get("SPARK_REMOTE", "sc://spark-connect.stardelt.svc.cluster.local:15002")
TRINO_URL = os.environ.get("TRINO_URL", "http://trino.stardelt.svc.cluster.local:8080").rstrip("/")
TRINO_USER = os.environ.get("TRINO_USER", "spark-verify")
TRINO_PASSWORD = os.environ.get("TRINO_PASSWORD", "")
SCRATCH = "warehouse.spark_verify"

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
    if not ok:
        failures.append(label)


def trino(sql: str) -> list[list[object]]:
    """Run one statement and return its rows (following nextUri)."""
    headers = {"X-Trino-User": TRINO_USER, "Content-Type": "text/plain"}
    if TRINO_PASSWORD:
        token = base64.b64encode(f"{TRINO_USER}:{TRINO_PASSWORD}".encode()).decode()
        headers["Authorization"] = f"Basic {token}"

    request = urllib.request.Request(
        f"{TRINO_URL}/v1/statement", data=sql.encode(), method="POST", headers=headers
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        body = json.load(response)

    rows: list[list[object]] = list(body.get("data") or [])
    while body.get("nextUri"):
        if body.get("error"):
            raise RuntimeError(json.dumps(body["error"])[:500])
        with urllib.request.urlopen(body["nextUri"], timeout=120) as response:
            body = json.load(response)
        rows.extend(body.get("data") or [])
    if body.get("error"):
        raise RuntimeError(json.dumps(body["error"])[:500])
    return rows


def spark_rows(spark, sql: str) -> list[tuple]:
    return [tuple(row) for row in spark.sql(sql).collect()]


def spark_exec(spark, sql: str) -> None:
    """Run a DDL/DML statement. Connect plans are lazy, so collect to execute."""
    spark.sql(sql).collect()


def main() -> int:
    from pyspark.sql import SparkSession  # imported late so `--help` stays cheap

    spark = SparkSession.builder.remote(SPARK_REMOTE).appName("verify-spark-iceberg").getOrCreate()
    print(f"› Spark Connect: {SPARK_REMOTE}")
    print(f"› Trino:         {TRINO_URL}")
    print(f"› Spark version: {spark.version}")

    try:
        print("\n1. warehouse.demo.trips — Spark vs Trino")
        spark_count = spark_rows(spark, "SELECT count(*) AS n FROM warehouse.demo.trips")[0][0]
        trino_count = trino("SELECT count(*) FROM warehouse.demo.trips")[0][0]
        print(f"  count(*) spark={spark_count} trino={trino_count}")
        check("count(*) agrees", int(spark_count) == int(trino_count))

        borough_sql = (
            "SELECT borough, count(*) AS n FROM warehouse.demo.trips "
            "GROUP BY borough ORDER BY borough"
        )
        spark_boroughs = spark_rows(spark, borough_sql)
        trino_boroughs = [tuple(row) for row in trino(borough_sql)]
        print(f"  spark: {spark_boroughs}")
        print(f"  trino: {trino_boroughs}")
        check("GROUP BY borough agrees", spark_boroughs == trino_boroughs)

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
