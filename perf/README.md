# Trino baseline (perf)

Measures end-to-end **engine** wall time for three fixed TPC-H queries against
the Trino coordinator: the `POST /v1/statement` plus all `nextUri` paging, timed
with `time.monotonic()`. It is a repeatable baseline for the current node, not a
benchmark suite.

## What it measures / does not measure

- **Measures:** Trino statement latency on the `tpch` connector (planning,
  scheduling, execution, result paging) for `q1_aggregate`, `q6_filter`,
  `q3_join`.
- **Does not measure:** permission overhead, Iceberg/Lakekeeper, Spark, or the
  experience of a restricted user. The `tpch`/`tpcds` catalogs are
  **administrator-only by design** (`helm-values/trino-identity.yaml`), so the
  live run uses an administrator token and the numbers are for the engine only.

## Run

Mint an administrator token with the existing script (credentials stay with the
maintainer; never commit them):

```bash
MINT_ONLY=1 TOKEN_FILE=/tmp/perf.token \
  ISSUER=https://id.alpha.dev.stardelt.io/realms/stardelt \
  USER=<admin user> PASSWORD=<its password> \
  CLIENT_SECRET_FILE=<(kubectl -n stardelt get secret stardelt-oidc-clients -o jsonpath='{.data.trino}' | base64 -d) \
  python3 scripts/verify-trino-auth.py
TRINO_URL=https://trino.alpha.dev.stardelt.io TRINO_TOKEN="$(cat /tmp/perf.token)" \
  python3 perf/baseline.py
```

Or `make perf-baseline` with `TRINO_URL` and `TRINO_TOKEN` in the environment.

`PERF_CATALOG` (default `tpch`), `PERF_SCHEMA` (default `sf1`) and `PERF_RUNS`
(default `3`) are overridable; `sf10` needs only `PERF_SCHEMA=sf10` and no code
change. The first run of each query is discarded (cold JVM/cache/S3 listing);
with `PERF_RUNS=1` the single run is reported as-is.

Results are written to `perf/results/<UTC timestamp>.json` (git-ignored). Tables
for a release belong in `stardelt-internal`.
