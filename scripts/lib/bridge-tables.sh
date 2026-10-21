#!/usr/bin/env bash
# The tables that exist, for scripts that must ask about real objects
# (stardelt-platform#359).
#
#   . scripts/lib/bridge-tables.sh
#   bridge_tables_init      # starts a loopback port-forward to the catalog
#   bridge_tables           # prints one `<catalog>\t<schema>\t<table>` line per table
#   bridge_tables_stop      # stops the port-forward (put it in the caller's trap)
#
# Not a program: `source` it. Lakekeeper denies a table that does not exist and
# Trino only ever asks about a table it has resolved, so a synthetic name would
# compare a real answer with an impossible question — the differential and the
# latency probe need the objects themselves, not guesses.
#
# It asks the catalog's own Iceberg REST API (`GET /catalog/v1/config`, then
# namespaces and tables per warehouse) as `svc-catalog-trino`, the engine's own
# client: the same credential every query already uses. The Secret is read with
# kubectl, its values never reach argv or a log line, and the token is minted
# against the realm's token endpoint from that Secret.
#
# Inputs: NAMESPACE (default `stardelt`), BRIDGE_TABLES_LOG (a file for the
# port-forward's output; a temp file by default).
bridge_tables_port="${BRIDGE_TABLES_PORT:-}"      # set by bridge_tables_init
_bridge_tables_pid=""

bridge_tables_stop() {
  [ -z "$_bridge_tables_pid" ] || kill "$_bridge_tables_pid" 2>/dev/null || true
  _bridge_tables_pid=""
}

bridge_tables_init() {
  local namespace="${NAMESPACE:-stardelt}"
  local log="${BRIDGE_TABLES_LOG:-/dev/null}"
  bridge_tables_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')" \
    || return 1
  kubectl -n "$namespace" port-forward svc/lakekeeper "$bridge_tables_port:8181" >"$log" 2>&1 &
  _bridge_tables_pid=$!
  local _
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$bridge_tables_port") 2>/dev/null; then
      exec 3<&-
      return 0
    fi
    sleep 0.25
  done
  bridge_tables_stop
  return 1
}

bridge_tables() {
  local namespace="${NAMESPACE:-stardelt}"
  python3 - "$namespace" "http://127.0.0.1:${bridge_tables_port}" "$@" <<'PY'
import base64
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

namespace, base = sys.argv[1], sys.argv[2]
catalogs = sys.argv[3:]

secret = json.loads(
    subprocess.check_output(
        ["kubectl", "-n", namespace, "get", "secret", "svc-catalog-trino", "-o", "json"],
        text=True,
    )
)["data"]


def decoded(key):
    return base64.b64decode(secret[key]).decode()


form = urllib.parse.urlencode(
    {
        "grant_type": "client_credentials",
        "client_id": decoded("client-id"),
        "client_secret": decoded("client-secret"),
        "scope": "openid",
    }
).encode()
token = json.load(
    urllib.request.urlopen(
        urllib.request.Request(decoded("token-url"), data=form, method="POST"), timeout=30
    )
)["access_token"]


def get(path):
    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


for catalog in catalogs:
    try:
        prefix = get("/catalog/v1/config?warehouse=" + urllib.parse.quote(catalog))
        prefix = prefix["defaults"]["prefix"]
        namespaces = get("/catalog/v1/%s/namespaces" % prefix).get("namespaces") or []
        for namespace_parts in namespaces:
            schema = ".".join(namespace_parts)
            tables = get("/catalog/v1/%s/namespaces/%s/tables" % (prefix, schema)).get(
                "identifiers"
            ) or []
            for identifier in tables:
                print("%s\t%s\t%s" % (catalog, schema, identifier["name"]))
    except (urllib.error.URLError, KeyError, ValueError) as problem:
        print("bridge-tables: no table list for %s: %s" % (catalog, problem), file=sys.stderr)
PY
}
