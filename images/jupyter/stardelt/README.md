# stardelt notebook helper

The small package the notebook image ships: `stardelt.sql` (query as the
signed-in hub user), `stardelt.write_df` (governed DataFrame writes),
`stardelt.spark` (Spark Connect session), `stardelt.connection` (a named
connection to an outside system: your own or your group's; values are read from the secret store when you ask,
never kept or printed).

Pure Python, MIT. Installed in the image (`images/jupyter/Dockerfile`);
tested in CI (`images/jupyter/tests/`, the `notebook-helper` job in
`.github/workflows/ci.yml`). The full contract is the docstrings in
`__init__.py` — this file exists so the build backend has a readme.

## Notebook tasks: `python -m stardelt.notebook_run`

The pod a notebook task runs holds no storage credential: the DAG signs two URLs and the wrapper
downloads the pinned notebook from `NOTEBOOK_GET_URL`, runs papermill with `run_date`, `run_id`
and `NOTEBOOK_PARAMS` as raw `-r` parameters, uploads the executed copy to `NOTEBOOK_PUT_URL`
(after a failure too), and on SIGTERM cancels the statements it recorded in `STARDELT_QUERY_IDS`
before exiting 143 (papermill's own code otherwise, 2 for a contract error). Stages and byte counts
are logged — never a URL, a token, a parameter value or notebook text.

## Reading public S3 with Spark

A `stardelt.spark()` session reads a **public** S3 bucket anonymously, with either
URI form Spark understands:

```python
spark = stardelt.spark()
spark.read.csv("s3a://noaa-ghcn-pds/csv.gz/by_year/1763.csv.gz").count()
spark.read.parquet("s3://ookla-open-data/parquet/performance/type=fixed/year=2023/quarter=1/").limit(5).show()
```

Only public buckets answer: S3A runs with `AnonymousAWSCredentialsProvider`, so a
private bucket fails with an access error, and the platform's own storage
(`s3a://lakehouse/`) is not reachable this way — read it through Trino or an Iceberg
table, where the catalog's grants apply. The jars and the switch live in the Spark
image and `manifests/spark.yaml`; the platform README ("Reading public S3 with
Spark") has the details.

## Python on executors

UDFs run. `udf`, `pandas_udf`, `mapInPandas`, `applyInPandas`, `foreach` and
`foreachPartition` execute the Python you write on the Spark workers:

```python
from pyspark.sql import functions as F

spark = stardelt.spark()
spark.range(5).select(F.udf(lambda x: x + 1, "long")("id").alias("v")).show()
```

The worker interpreter is CPython **3.11** — the same minor as this notebook — with
exactly `pandas==2.2.3`, `pyarrow==18.1.0` and `numpy==2.0.2`, this image's versions.
Nothing else is installed there: a library you `import` inside a UDF, or install in
the notebook with `!pip install`, is **not** available on the executors. Do that work
in the notebook process instead (or ask for the library to be added to the Spark
image, `images/spark/Dockerfile`).

Python code crosses the wire as a pickle and PySpark compares the *minor* version, so
the two images must stay on one Python minor: if they drift apart, every one of those
calls fails with `[PYTHON_VERSION_MISMATCH] Python in worker has different version ...
than that in driver ...` while DataFrame and SQL keep working. Keep both on the same
Python minor: Spark Connect UDFs fail otherwise (platform#369).

## Keeping the shared driver healthy

Every session `stardelt.spark()` opens runs against the same driver — 1 GiB heap in a
3 GiB pod since platform#372, `spark.driver.maxResultSize` 512 MiB, and no Spark UI.
Patterns that are fine on a laptop fill that driver for everyone, so:

| Instead of | Do | Why |
|---|---|---|
| `df.toPandas()` / `df.collect()` on a big table | `df.limit(10_000).toPandas()`, aggregate first, or write the result with `df.writeTo("<catalog>.<schema>.<table>").createOrReplace()` and read it with SQL | the whole result lands in the 1 GiB driver heap; above 512 MiB the call fails |
| `spark.createDataFrame(big_pandas_or_list)` | write the data to a table once (`writeTo`), then `spark.table(...)` | local data is shipped inside every task of every job |
| a Python loop that runs one job per item | one query with a join or `groupBy`, or `df.repartition(n)` plus `mapInPandas` | every job adds a broadcast and a plan to the driver |
| `df.join(small_df, ...)` repeated in a loop | `from pyspark.sql.functions import broadcast`; `df.join(broadcast(small_df), ...)` once, outside the loop | one broadcast instead of one per iteration |
| `df.cache()` never released | `df.unpersist()` when done; cache only what several actions reuse | cached blocks occupy executor memory (1 GiB each) and are not freed by themselves |
| `pd.read_csv(chunksize=250_000)` then `spark.createDataFrame(chunk)` + `saveAsTable(append)` per chunk | chunks of at most 20_000 rows (about 1 MiB per task), write finished chunk numbers to a small table so a restart can resume, and see platform#378 for the planned loader | measured 2026-10-21: 250_000 rows = tasks of 11 MiB, 305 warnings in 3 h, driver OOMKilled |
| `df.count()` repeated to "check" | run it once, keep the number | each action is a job |

Executors: at most 2 x 1 core x 1 GiB today; sizes are designed in platform#375. If a call
fails with `maxResultSize`, write the result to a table instead of raising the limit.

`stardelt.spark_tips()` prints the seven rows into a notebook, so they are one cell away.
