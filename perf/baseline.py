#!/usr/bin/env python3
"""Trino TPC-H baseline: three fixed queries, median/p95 over warm runs.

Engine wall time only (POST /v1/statement plus nextUri paging). No
dependencies beyond the standard library. See perf/README.md.
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread


QUERIES = (
    (
        "q1_aggregate",
        """SELECT l_returnflag, l_linestatus, sum(l_quantity), sum(l_extendedprice),
       sum(l_extendedprice * (1 - l_discount)),
       sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)),
       avg(l_quantity), avg(l_extendedprice), avg(l_discount), count(*)
FROM {catalog}.{schema}.lineitem GROUP BY 1, 2 ORDER BY 1, 2""",
    ),
    (
        "q6_filter",
        """SELECT sum(l_extendedprice * l_discount)
FROM {catalog}.{schema}.lineitem
WHERE l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1995-01-01'
  AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24""",
    ),
    (
        "q3_join",
        """SELECT o_orderpriority, count(*)
FROM {catalog}.{schema}.orders JOIN {catalog}.{schema}.lineitem ON l_orderkey = o_orderkey
WHERE o_orderdate >= DATE '1995-01-01' GROUP BY 1 ORDER BY 1""",
    ),
)


def _auth_headers() -> dict[str, str]:
    token = os.environ.get("TRINO_TOKEN", "").strip()
    if token:
        return {"Authorization": f"Bearer {token}"}
    user = os.environ.get("TRINO_USER", "")
    password = os.environ.get("TRINO_PASSWORD", "")
    if not user:
        raise SystemExit("set TRINO_TOKEN, or TRINO_USER and TRINO_PASSWORD")
    headers = {"X-Trino-User": user}
    if password:
        pair = base64.b64encode(f"{user}:{password}".encode()).decode()
        headers["Authorization"] = f"Basic {pair}"
    return headers


def run_statement(trino_url: str, sql: str) -> tuple[list[list[object]], int]:
    """Execute one statement, following nextUri. Returns (rows, elapsed_ms)."""
    headers = {"Content-Type": "text/plain"}
    headers.update(_auth_headers())
    url = f"{trino_url.rstrip('/')}/v1/statement"
    start = time.monotonic()
    request = urllib.request.Request(url, data=sql.encode(), method="POST", headers=headers)
    with urllib.request.urlopen(request, timeout=600) as response:
        body = json.load(response)
    rows: list[list[object]] = list(body.get("data") or [])
    while body.get("nextUri"):
        if body.get("error"):
            raise RuntimeError(json.dumps(body["error"], default=str)[:500])
        with urllib.request.urlopen(body["nextUri"], timeout=600) as response:
            body = json.load(response)
        rows.extend(body.get("data") or [])
    if body.get("error"):
        raise RuntimeError(json.dumps(body["error"], default=str)[:500])
    elapsed_ms = int(round((time.monotonic() - start) * 1000))
    return rows, elapsed_ms


def percentile(values: list[int], pct: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    k = (len(ordered) - 1) * pct / 100.0
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return ordered[lo]
    return int(round(ordered[lo] * (hi - k) + ordered[hi] * (k - lo)))


def median(values: list[int]) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return int(round((ordered[mid - 1] + ordered[mid]) / 2))


def summarize(runs_ms: list[int], runs: int) -> dict[str, object]:
    if runs == 1:
        sample = runs_ms
        note = "single run (no warm-up discarded)"
    else:
        sample = runs_ms[1:]
        note = None
    result: dict[str, object] = {
        "runsMs": runs_ms,
        "medianMs": median(sample),
        "p95Ms": percentile(sample, 95),
        "minMs": min(sample) if sample else 0,
    }
    if note:
        result["note"] = note
    return result


def measure_queries(trino_url: str, catalog: str, schema: str, runs: int) -> list[dict[str, object]]:
    results = []
    for name, template in QUERIES:
        sql = template.format(catalog=catalog, schema=schema)
        run_times: list[int] = []
        row_count = 0
        for i in range(runs):
            rows, elapsed_ms = run_statement(trino_url, sql)
            run_times.append(elapsed_ms)
            row_count = len(rows)
            label = "cold" if i == 0 and runs > 1 else "warm"
            print(f"  {name} run {i + 1}/{runs} ({label}): {elapsed_ms} ms, {row_count} rows")
        summary = summarize(run_times, runs)
        results.append(
            {
                "name": name,
                "sql": " ".join(sql.split()),
                "rows": row_count,
                **summary,
            }
        )
    return results


def print_table(results: list[dict[str, object]], runs: int) -> None:
    if runs == 1:
        print("\nquery            rows   median   p95   min   (ms, single run)")
    else:
        print("\nquery            rows   median   p95   min   (ms, warm runs)")
    print("-" * 62)
    for q in results:
        print(
            f"{q['name']:<15} {q['rows']:>5}  {q['medianMs']:>6}  {q['p95Ms']:>5}  {q['minMs']:>5}"
        )


def write_json(path: str, payload: dict[str, object]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


class _SelfTestHandler(BaseHTTPRequestHandler):
    page1 = {"id": "q1", "data": [[1, "a"]], "nextUri": None}
    page2 = {"data": [[2, "b"]]}
    call_count = 0

    def do_POST(self):  # noqa: N802
        type(self).call_count += 1
        body = dict(self.page1)
        body["nextUri"] = f"http://{self.server.server_address[0]}:{self.server.server_address[1]}/next/1"
        self._send(body)

    def do_GET(self):  # noqa: N802
        self._send(self.page2)

    def _send(self, body: dict[str, object]) -> None:
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        return


def self_test() -> int:
    # Bypass auth for the local fake server.
    os.environ["TRINO_TOKEN"] = "test-token"
    os.environ.pop("TRINO_USER", None)
    os.environ.pop("TRINO_PASSWORD", None)

    server = HTTPServer(("127.0.0.1", 0), _SelfTestHandler)
    port = server.server_address[1]
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        trino_url = f"http://127.0.0.1:{port}"
        rows, elapsed = run_statement(trino_url, "SELECT 1")
        assert rows == [[1, "a"], [2, "b"]], f"paging concat failed: {rows}"
        assert elapsed >= 0, "elapsed must be non-negative"
        assert _SelfTestHandler.call_count == 1, "expected one POST"

        # Aggregation: discard first run when runs > 1.
        runs_ms = [412, 398, 405]
        summary = summarize(runs_ms, 3)
        # warm runs [398,405]: median (398+405)/2 rounded = 402, p95 linear = 405, min 398
        assert summary["medianMs"] == 402, f"median mismatch: {summary}"
        assert summary["p95Ms"] == 405, f"p95 mismatch: {summary}"
        assert summary["minMs"] == 398, f"min mismatch: {summary}"
        assert summary["runsMs"] == runs_ms
        assert "note" not in summary

        single = summarize([500], 1)
        assert single["medianMs"] == 500 and single["p95Ms"] == 500 and single["minMs"] == 500
        assert "note" in single

        print("self-test ok")
        return 0
    finally:
        server.shutdown()
        _SelfTestHandler.call_count = 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Trino TPC-H baseline")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()

    trino_url = os.environ.get("TRINO_URL", "").strip()
    if not trino_url:
        raise SystemExit("set TRINO_URL")
    _auth_headers()  # validate auth config early

    catalog = os.environ.get("PERF_CATALOG", "tpch")
    schema = os.environ.get("PERF_SCHEMA", "sf1")
    runs = int(os.environ.get("PERF_RUNS", "3"))
    if runs < 1:
        raise SystemExit("PERF_RUNS must be >= 1")

    print(f"› Trino:   {trino_url}")
    print(f"› Catalog: {catalog}.{schema}")
    print(f"› Runs:    {runs} per query" + (" (first discarded)" if runs > 1 else " (no warm-up discarded)"))
    print()

    results = measure_queries(trino_url, catalog, schema, runs)
    print_table(results, runs)

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(os.path.dirname(__file__), "results", f"{ts}.json")
    payload = {
        "generatedAt": generated_at,
        "trinoUrl": trino_url,
        "catalog": catalog,
        "schema": schema,
        "runs": runs,
        "queries": results,
    }
    write_json(path, payload)
    print(f"\nwrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
