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
