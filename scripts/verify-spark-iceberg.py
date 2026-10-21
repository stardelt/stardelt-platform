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
  4. Python on the executors: `udf`, `pandas_udf`, `mapInPandas`,
     `applyInPandas`, `foreach` and `foreachPartition` return the expected rows,
     and the worker interpreter is the client's Python minor. A mismatch is the
     `[PYTHON_VERSION_MISMATCH]` failure that makes every one of them fail
     (platform#369), so the guard prints both versions and fails with
     "keep both on the same Python minor: Spark Connect UDFs fail otherwise".
  5. The scratch namespace `spark_verify` is dropped again.

Trino is queried with the same `TRINO_TOKEN` as a bearer; `TRINO_USER` /
`TRINO_PASSWORD` (HTTP Basic) and anonymous access remain available for the
older in-cluster shapes. Exit status is non-zero if anything disagrees — this is
meant to be run, not read.
"""

from __future__ import annotations

import base64
import json
import os
import platform
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


# Python on the executors (platform#369). Every function below runs *in the
# worker* on an executor, never in this process, and pandas is not imported at
# module level on purpose: the closure has to pickle without pandas on the
# client (the documented verification pod installs `pyspark-client` only), and
# the worker has pandas from the Spark image.
def _python_version():
    import platform as _platform

    return _platform.python_version()


def _plus_one(value):
    return value + 1


def _one_more_per_batch(batches):
    for pdf in batches:
        yield pdf.assign(id=pdf["id"] + 1)


def _double_id_per_group(pdf):
    return pdf.assign(id=pdf["id"] * 2)


def _noop(_row) -> None:
    return None


def _noop_partition(rows) -> None:
    for _row in rows:
        pass


def check_python_on_executors(spark) -> None:
    """Prove the Python path works: UDFs, pandas UDFs, mapInPandas, foreach.

    A `[PYTHON_VERSION_MISMATCH]` between this client and the worker is the
    failure this guards: `udf`, `pandas_udf`, `mapInPandas`, `applyInPandas`,
    `foreach` and `foreachPartition` all die with it, while DataFrame/SQL keeps
    working (platform#369). Each check records its own failure, so the script
    exits non-zero instead of stopping at the first.
    """
    from pyspark.sql import functions as F

    client = platform.python_version()
    print(f"  client python {client}")
    try:
        worker = (
            spark.range(1).select(F.udf(_python_version, "string")().alias("version"))
        ).first()["version"]
    except Exception as exc:  # the mismatch arrives as a worker error
        print(f"  worker python: refused — {type(exc).__name__}: {str(exc)[:300]}")
        check(
            "worker Python matches the client",
            False,
            "keep both on the same Python minor: Spark Connect UDFs fail otherwise",
        )
    else:
        print(f"  worker python {worker}")
        same_minor = ".".join(client.split(".")[:2]) == ".".join(worker.split(".")[:2])
        check(
            "worker Python matches the client",
            same_minor,
            ""
            if same_minor
            else (
                f"keep both on the same Python minor: Spark Connect UDFs fail "
                f"otherwise ({worker} in the worker, {client} in the driver)"
            ),
        )

    def udf_rows() -> None:
        got = sorted(
            row.v
            for row in spark.range(5)
            .select(F.udf(_plus_one, "long")("id").alias("v"))
            .collect()
        )
        print(f"  udf(lambda x: x + 1) over range(5): {got}")
        check("udf runs on the executors", got == [1, 2, 3, 4, 5])

    def pandas_udf_rows() -> None:
        plus_one = F.pandas_udf(lambda series: series + 1, "long")
        frame = spark.range(5).select(plus_one("id").alias("v"))
        got = sorted(row.v for row in frame.collect())
        print(f"  pandas_udf: {got}")
        check("pandas_udf runs on the executors", got == [1, 2, 3, 4, 5])

    def map_in_pandas_rows() -> None:
        frame = spark.range(5).mapInPandas(_one_more_per_batch, "id long")
        got = sorted(row.id for row in frame.collect())
        print(f"  mapInPandas: {got}")
        check("mapInPandas runs on the executors", got == [1, 2, 3, 4, 5])

    def apply_in_pandas_rows() -> None:
        frame = (
            spark.range(10)
            .withColumn("g", F.col("id") % 2)
            .groupBy("g")
            .applyInPandas(_double_id_per_group, "g long, id long")
        )
        got = sorted((row.g, row.id) for row in frame.collect())
        print(f"  applyInPandas: {got}")
        expected = [(0, 0), (0, 4), (0, 8), (0, 12), (0, 16), (1, 2), (1, 6), (1, 10), (1, 14), (1, 18)]
        check("applyInPandas runs on the executors", got == expected)

    def foreach_rows() -> None:
        spark.range(5).foreach(_noop)
        spark.range(5).foreachPartition(_noop_partition)
        print("  foreach and foreachPartition: completed")
        check("foreach and foreachPartition run on the executors", True)

    def partition_count() -> None:
        count = (
            spark.range(1000)
            .repartition(8)
            .select(F.spark_partition_id())
            .distinct()
            .count()
        )
        print(f"  spark.range(1000).repartition(8) → {count} partitions")
        check("repartition(8) runs on eight partitions", count == 8)

    for label, run in (
        ("udf runs on the executors", udf_rows),
        ("pandas_udf runs on the executors", pandas_udf_rows),
        ("mapInPandas runs on the executors", map_in_pandas_rows),
        ("applyInPandas runs on the executors", apply_in_pandas_rows),
        ("foreach and foreachPartition run on the executors", foreach_rows),
        ("repartition(8) runs on eight partitions", partition_count),
    ):
        try:
            run()
        except Exception as exc:  # record it, keep checking, exit 1 at the end
            check(label, False, f"{type(exc).__name__}: {str(exc)[:300]}")


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

            print("\n4. Python on the executors (UDFs, pandas UDFs, mapInPandas, foreach)")
            check_python_on_executors(spark)
        finally:
            print(f"\n5. cleaning up {SCRATCH}")
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
    print("\nverify-spark-iceberg: OK — two-way Iceberg round trip, Trino parity, Python on the executors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
