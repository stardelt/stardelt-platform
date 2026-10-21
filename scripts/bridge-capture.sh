#!/usr/bin/env bash
# Capture the authorization questions Trino actually asks an OPA authorizer
# (stardelt-platform#333, before the switch platform#311).
#
#   make bridge-capture
#
# Writes scripts/tests/fixtures/trino-opa-requests.json — the request bodies the
# bridge has to answer — from a throwaway Trino that asks a stub instead of the
# bridge. It is a development tool: no install step runs it, it changes nothing
# in the platform, and it deletes everything it creates (including on failure).
#
# Why a throwaway Trino and not the coordinator: the coordinator runs the
# file-based authorizer until platform#311, and its `access-control.properties`
# is a mounted ConfigMap the install owns. A capture must not touch it. The pod
# below is a full coordinator (coordinator=true, scheduler on the coordinator)
# with the *same image digest* as the real one, so the bodies are the bodies the
# cluster's Trino version sends, not what a document says it sends. It gets
# 768 MiB of heap — the node has room for that for a few minutes.
#
# The stub (`echo.py`, in the same ConfigMap) is a python http.server that
# answers `{"result": true}` to a single question and `{"result": [0,…,n-1]}`
# (every index) to a batch, and appends `{path, body}` to requests.jsonl. It
# allows everything on purpose: the battery below has to reach the points where
# Trino asks, and a denial at the first question would hide the rest.
#
# Pod labels are `app.kubernetes.io/name=trino-capture` — deliberately NOT the
# coordinator labels, so NetworkPolicy `lakekeeper-ingress` does not admit it to
# the real bridge (it only talks to its own stub on localhost).
#
# The fixture replaces the capture user with `<sub>`: the battery runs as a
# fresh UUID, the shape a Keycloak subject has, and `make bridge-replay`
# substitutes each seed person's id. Every body stays otherwise verbatim — the
# capture is the evidence, not a hand-written example.
#
# Fixture format (one entry per distinct path + operation + resource kind):
#
#   {"trinoImage": "...", "capturedAt": "...", "requests": [
#     {"path": "/v1/data/trino/allow", "operation": "AccessCatalog",
#      "resourceKind": "catalog", "input": {…}},
#     …]}
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
POD="bridge-capture"
CONFIGMAP="bridge-capture-config"
ECHO_IMAGE="${ECHO_IMAGE:-python:3.13-slim}"
FIXTURE="scripts/tests/fixtures/trino-opa-requests.json"
# request bodies the replay needs at least; below that the battery ran short.
MIN_PAIRS=20

fail() { echo "bridge-capture: $*" >&2; exit 1; }

for tool in kubectl python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done

# The image the live coordinator runs: the capture must send the same bytes a
# query on this cluster sends. A missing Deployment means this is not a
# platform cluster (a bare install-core has no Trino) — nothing to capture.
IMAGE="$(kubectl -n "$NAMESPACE" get deploy trino-coordinator \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ -n "$IMAGE" ] || fail "no Deployment trino-coordinator in namespace $NAMESPACE — run 'make trino' first"

umask 077
tmp="$(mktemp -d)"
created=0
cleanup() {
  if [ "$created" = 1 ] && [ "${KEEP:-0}" != 1 ]; then
    kubectl -n "$NAMESPACE" delete pod "$POD" --wait=false >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete configmap "$CONFIGMAP" --wait=false >/dev/null 2>&1 || true
  fi
  if [ "${KEEP:-0}" = 1 ]; then
    echo "bridge-capture: KEEP=1 — pod $POD and ConfigMap $CONFIGMAP left in namespace $NAMESPACE" >&2
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# A fresh UUID as the user, so the captured string has the shape of a Keycloak
# `sub` — the same substitution `make bridge-replay` makes per person.
CAPTURE_USER="$(python3 -c 'import uuid; print(uuid.uuid4())')"

# ---------------------------------------------------------------------------
# 1. The configuration: a coordinator with no authentication, five catalogs
#    (tpch + four `memory` catalogs that accept DDL), and the OPA authorizer
#    pointing at the stub in the same pod.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/catalog"
cat >"$tmp/config.properties" <<'EOF'
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
query.max-memory=512MB
query.max-memory-per-node=256MB
EOF

cat >"$tmp/jvm.config" <<'EOF'
-server
-Xmx768M
-Xms256M
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+ExplicitGCInvokesConcurrent
-XX:+ExitOnOutOfMemoryError
-XX:-OmitStackTraceInFastThrow
-XX:ReservedCodeCacheSize=256M
-XX:PerMethodRecompilationCutoff=10000
-XX:PerBytecodeRecompilationCutoff=10000
-Djdk.attach.allowAttachSelf=true
-Djdk.nio.maxCachedBufferSize=2000000
-XX:+EnableDynamicAgentLoading
-XX:+UnlockDiagnosticVMOptions
-XX:G1NumCollectionsKeepPinned=10000000
EOF

cat >"$tmp/node.properties" <<'EOF'
node.environment=capture
node.id=bridge-capture
node.data-dir=/data/trino
EOF

cat >"$tmp/log.properties" <<'EOF'
io.trino=INFO
EOF

# The authorizer the switch (#311) turns on, with both URIs — including the
# batch one, so the capture proves whether 480 sends anything there.
cat >"$tmp/access-control.properties" <<'EOF'
access-control.name=opa
opa.policy.uri=http://localhost:8282/v1/data/trino/allow
opa.policy.batched-uri=http://localhost:8282/v1/data/trino/batch
opa.log-requests=true
opa.log-responses=true
EOF

cat >"$tmp/catalog/tpch.properties" <<'EOF'
connector.name=tpch
EOF

# The four catalogs of the dev seed (#309). `memory` accepts CREATE SCHEMA,
# CREATE TABLE, INSERT and CREATE VIEW without an object store, which is what
# the battery below needs; the requests are the same as against Iceberg.
for catalog in warehouse finance product sandbox; do
  cat >"$tmp/catalog/$catalog.properties" <<'EOF'
connector.name=memory
memory.max-data-per-node=128MB
EOF
done

# The stub. One file so the pod needs no writable image layer.
cat >"$tmp/echo.py" <<'EOF'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = "/captures/requests.jsonl"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"raw": raw.decode("utf-8", "replace")}
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(json.dumps({"path": self.path, "body": body}, sort_keys=True) + "\n")
        if self.path.rstrip("/").endswith("/batch"):
            action = (body.get("input") or {}).get("action") or {}
            resources = action.get("filterResources") or []
            answer = {"result": list(range(len(resources)))}
        else:
            answer = {"result": True}
        payload = json.dumps(answer).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", 8282), Handler).serve_forever()
EOF

# 2. The ConfigMap. Keys are flat; the pod projects them into /etc/trino and
#    /etc/trino/catalog with an `items` mapping, and echo.py into /etc/capture.
kubectl -n "$NAMESPACE" create configmap "$CONFIGMAP" \
  --from-file=config.properties="$tmp/config.properties" \
  --from-file=jvm.config="$tmp/jvm.config" \
  --from-file=node.properties="$tmp/node.properties" \
  --from-file=log.properties="$tmp/log.properties" \
  --from-file=access-control.properties="$tmp/access-control.properties" \
  --from-file=tpch.properties="$tmp/catalog/tpch.properties" \
  --from-file=warehouse.properties="$tmp/catalog/warehouse.properties" \
  --from-file=finance.properties="$tmp/catalog/finance.properties" \
  --from-file=product.properties="$tmp/catalog/product.properties" \
  --from-file=sandbox.properties="$tmp/catalog/sandbox.properties" \
  --from-file=echo.py="$tmp/echo.py" \
  --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f - >/dev/null

kubectl -n "$NAMESPACE" delete pod "$POD" --ignore-not-found --wait=true >/dev/null

kubectl -n "$NAMESPACE" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels:
    app.kubernetes.io/name: trino-capture
    app.kubernetes.io/part-of: stardelt
spec:
  restartPolicy: Never
  # The image runs as uid/gid 1000 (trino); the shared emptyDirs are root-owned
  # without this, and Trino cannot write node.data-dir.
  securityContext:
    fsGroup: 1000
  volumes:
    - name: config
      configMap:
        name: ${CONFIGMAP}
        items:
          - {key: config.properties, path: config.properties}
          - {key: jvm.config, path: jvm.config}
          - {key: node.properties, path: node.properties}
          - {key: log.properties, path: log.properties}
          - {key: access-control.properties, path: access-control.properties}
          - {key: tpch.properties, path: catalog/tpch.properties}
          - {key: warehouse.properties, path: catalog/warehouse.properties}
          - {key: finance.properties, path: catalog/finance.properties}
          - {key: product.properties, path: catalog/product.properties}
          - {key: sandbox.properties, path: catalog/sandbox.properties}
    - name: echo-script
      configMap:
        name: ${CONFIGMAP}
        items:
          - {key: echo.py, path: echo.py}
    - name: data
      emptyDir: {}
    - name: captures
      emptyDir: {}
  containers:
    - name: trino
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      resources:
        requests: {cpu: "100m", memory: 768Mi}
        limits: {memory: 1536Mi}
      volumeMounts:
        - {name: config, mountPath: /etc/trino, readOnly: true}
        - {name: data, mountPath: /data/trino}
        - {name: captures, mountPath: /captures}
    - name: echo
      image: ${ECHO_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["python3", "-u", "/etc/capture/echo.py"]
      resources:
        requests: {cpu: "10m", memory: 32Mi}
        limits: {memory: 128Mi}
      volumeMounts:
        - {name: echo-script, mountPath: /etc/capture, readOnly: true}
        - {name: captures, mountPath: /captures}
YAML
created=1

kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null \
  || { kubectl -n "$NAMESPACE" logs "$POD" -c trino --tail=40 2>/dev/null || true; fail "the capture pod never became ready"; }

# Ready means the containers are running; Trino itself is up when /v1/info
# stops saying starting. Ask from the echo container — same network namespace,
# and python is its own tool, so the Trino image needs nothing extra.
echo "› waiting for Trino $IMAGE to accept queries"
kubectl -n "$NAMESPACE" exec -i "pod/$POD" -c echo -- python3 - <<'PY' || fail "Trino never finished starting"
import json, sys, time, urllib.request
for _ in range(120):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/v1/info", timeout=2) as response:
            info = json.load(response)
        if not info.get("starting"):
            print("  nodeVersion=%s" % info.get("nodeVersion"))
            break
    except Exception:
        pass
    time.sleep(2)
else:
    sys.exit("no /v1/info after 240s")
PY

# ---------------------------------------------------------------------------
# 3. The battery. Statements that need a table create it first; the stub allows
#    everything, so each statement reaches the authorizer the way it would on a
#    real cluster. `ok` and `expect-fail` only decide whether the statement's
#    outcome is worth printing — every statement runs either way, and every
#    statement's requests are captured.
# ---------------------------------------------------------------------------
BATTERY=(
  "ok|CREATE SCHEMA finance.seed"
  "ok|CREATE TABLE finance.seed.nation AS SELECT * FROM tpch.tiny.nation"
  "ok|CREATE SCHEMA product.seed"
  "ok|CREATE TABLE product.seed.nation AS SELECT * FROM tpch.tiny.nation"
  "ok|CREATE SCHEMA sandbox.seed"
  "ok|CREATE TABLE sandbox.seed.nation AS SELECT * FROM tpch.tiny.nation"
  "ok|CREATE SCHEMA warehouse.demo"
  "ok|CREATE TABLE warehouse.demo.trips (n_name varchar)"
  "ok|SHOW CATALOGS"
  "ok|SHOW SCHEMAS FROM finance"
  "ok|SHOW TABLES FROM finance.seed"
  "ok|DESCRIBE finance.seed.nation"
  "ok|SELECT count(*) FROM finance.seed.nation"
  # The ticket's statement, verbatim. Trino's TPCH connector has no `n_`
  # prefix (its columns are nationkey/name/regionkey/comment), so this one is
  # rejected by the analyzer; the next line is the same read that parses, which
  # is what produces SelectFromColumns on product.
  "expect-fail|SELECT n_name FROM product.seed.nation WHERE n_nationkey < 3"
  "ok|SELECT name FROM product.seed.nation WHERE nationkey < 3"
  "ok|INSERT INTO finance.seed.nation SELECT * FROM tpch.tiny.nation"
  "ok|CREATE SCHEMA finance.tmp"
  "ok|CREATE TABLE finance.tmp.t AS SELECT 1 a"
  "ok|DROP TABLE finance.tmp.t"
  "ok|DROP SCHEMA finance.tmp"
  "ok|CREATE VIEW sandbox.seed.v AS SELECT * FROM sandbox.seed.nation"
  "ok|SELECT * FROM system.runtime.queries LIMIT 3"
  "ok|SELECT * FROM system.runtime.nodes"
  "ok|SELECT * FROM warehouse.information_schema.tables LIMIT 3"
  "ok|EXPLAIN SELECT 1"
  "ok|SHOW SESSION LIKE 'query_max%'"
  "ok|SET SESSION query_max_run_time = '5m'"
  "ok|SELECT current_user"
  "ok|SELECT 1"
  "ok|EXPLAIN ANALYZE SELECT 1"
  "expect-fail|CALL system.runtime.kill_query(query_id => 'x', message => 'y')"
  # The ticket's `SHOW FUNCTIONS LIMIT 3`: Trino 480's grammar has no LIMIT
  # there. The three FROM variants below are what reach the authorizer
  # (FilterFunctions batched, per schema).
  "expect-fail|SHOW FUNCTIONS LIMIT 3"
  "ok|SHOW FUNCTIONS FROM system.runtime"
  "ok|SHOW FUNCTIONS FROM tpch.tiny"
  "ok|SHOW FUNCTIONS FROM finance.seed"
  "expect-fail|SHOW GRANTS"
)

echo "› running ${#BATTERY[@]} statements as $CAPTURE_USER"
for row in "${BATTERY[@]}"; do
  IFS='|' read -r expectation statement <<<"$row"
  if kubectl -n "$NAMESPACE" exec "pod/$POD" -c trino -- \
      trino --server http://localhost:8080 --user "$CAPTURE_USER" \
            --output-format TSV --execute "$statement" >"$tmp/last.out" 2>"$tmp/last.err"; then
    printf '  ok           %s\n' "$statement"
  elif [ "$expectation" = "expect-fail" ]; then
    printf '  failed (ok)  %s — %s\n' "$statement" "$(head -c 160 "$tmp/last.err" | tr '\n' ' ')"
  else
    # A statement that should work but did not still sent its questions; keep
    # going so one connector limit does not truncate the capture.
    printf '  failed       %s — %s\n' "$statement" "$(head -c 160 "$tmp/last.err" | tr '\n' ' ')"
  fi
done

# 3b. The operations that only exist between two people: Trino asks
#     FilterViewQueryOwnedBy only for a query someone *else* owns
#     (AccessControlUtil.filterQueries) and KillQueryOwnedBy only when the
#     killer is not the owner. So: one query as the capture user, a second user
#     asks about it, and the same second user tries to kill it. The probe talks
#     to the HTTP statement API directly (the CLI cannot keep a query running
#     while it runs another), from the echo container — same pod, same network.
PEER_USER="$(python3 -c 'import uuid; print(uuid.uuid4())')"
echo "› asking about another person's query ($PEER_USER)"
kubectl -n "$NAMESPACE" exec -i "pod/$POD" -c echo -- \
  python3 - "$CAPTURE_USER" "$PEER_USER" <<'PY' || echo "  (the ownership probe did not finish; the capture continues)"
import json
import sys
import threading
import time
import urllib.request

owner, other = sys.argv[1:3]
BASE = "http://127.0.0.1:8080"


def post(user, sql):
    request = urllib.request.Request(
        BASE + "/v1/statement",
        data=sql.encode("utf-8"),
        headers={"X-Trino-User": user, "Content-Type": "text/plain; charset=utf-8"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def run(user, sql, polls=60):
    data = post(user, sql)
    for _ in range(polls):
        next_uri = data.get("nextUri")
        if not next_uri:
            break
        time.sleep(0.5)
        with urllib.request.urlopen(next_uri, timeout=60) as response:
            data = json.load(response)
    return data


# A sum over one hundred TPCH scale factors: a real scan (a `count(*)` is
# answered from table statistics and finishes instantly). Trino cancels a query
# as soon as its client goes away, so a thread keeps fetching its nextUri while
# the other person asks about it and kills it.
started = post(owner, "SELECT sum(orderkey) FROM tpch.sf100.lineitem")
query_id = started.get("id")
stop = threading.Event()


def keep_alive(next_uri):
    while next_uri and not stop.is_set():
        time.sleep(0.4)
        try:
            with urllib.request.urlopen(next_uri, timeout=30) as response:
                next_uri = json.load(response).get("nextUri")
        except Exception:
            return


threading.Thread(target=keep_alive, args=(started.get("nextUri"),), daemon=True).start()
time.sleep(2.0)

run(other, "SELECT * FROM system.runtime.queries")
result = run(other, "CALL system.runtime.kill_query(query_id => '%s', message => 'capture')" % query_id, polls=5)
stop.set()
print(json.dumps({"ownerQueryId": query_id, "killError": (result.get("error") or {}).get("message")}))
PY

# ---------------------------------------------------------------------------
# 4. Take the evidence out, then build the fixture: one entry per distinct
#    (path, operation, resource kind), capture user replaced by `<sub>`.
# ---------------------------------------------------------------------------
kubectl -n "$NAMESPACE" exec "pod/$POD" -c echo -- cat /captures/requests.jsonl >"$tmp/requests.jsonl"
requests="$(wc -l <"$tmp/requests.jsonl" | tr -d ' ')"
[ "$requests" -gt 0 ] || fail "the stub recorded no request — did Trino use the OPA authorizer?"

mkdir -p "$(dirname "$FIXTURE")"
python3 - "$tmp/requests.jsonl" "$FIXTURE" "$IMAGE" "$CAPTURE_USER" "$PEER_USER" "$tmp/pairs" <<'PY'
import datetime
import json
import sys

raw_path, fixture_path, image, capture_user, peer_user, count_path = sys.argv[1:7]

seen = {}
total = 0
for line in open(raw_path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    entry = json.loads(line)
    body = entry.get("body") or {}
    raw_input = body.get("input")
    if not isinstance(raw_input, dict):
        continue
    action = raw_input.get("action") or {}
    operation = action.get("operation") or "?"
    resource = action.get("resource") or {}
    kind = next(iter(resource), None) if isinstance(resource, dict) else None
    if kind is None:
        filtered = action.get("filterResources") or []
        if filtered and isinstance(filtered[0], dict):
            kind = next(iter(filtered[0]), None)
    total += 1
    key = (entry.get("path"), operation, kind)
    if key in seen:
        continue
    seen[key] = {
        "path": entry.get("path"),
        "operation": operation,
        "resourceKind": kind,
        "input": raw_input,
    }

# The user strings are the two things the replay substitutes: `<sub>` is the
# person asking, `<peer>` is the other person whose query the question is about
# (FilterViewQueryOwnedBy, KillQueryOwnedBy) — capturing those two operations
# needs a query that someone else owns.
serialized = json.dumps(
    {
        "trinoImage": image,
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "requests": [seen[key] for key in sorted(seen, key=lambda k: (k[1], k[2] or "", k[0]))],
    },
    indent=2,
    sort_keys=False,
)
serialized = serialized.replace(capture_user, "<sub>").replace(peer_user, "<peer>")

with open(fixture_path, "w", encoding="utf-8") as fixture:
    fixture.write(serialized + "\n")

kinds = sorted({(entry["operation"], entry["resourceKind"]) for entry in seen.values()})
print("  %d request(s) -> %d distinct (operation, resource kind) pair(s)" % (total, len(kinds)))
for operation, kind in kinds:
    print("    %-32s %s" % (operation, kind or "-"))
with open(count_path, "w", encoding="utf-8") as count:
    count.write(str(len(kinds)))
PY
pairs="$(cat "$tmp/pairs")"
[ "$pairs" -ge "$MIN_PAIRS" ] \
  || fail "only $pairs distinct (operation, resource kind) pairs, expected at least $MIN_PAIRS — the battery did not cover the contract"

echo ""
echo "bridge-capture: OK — $requests request(s) captured from $IMAGE into $FIXTURE"
echo "next: make bridge-replay (against the live bridge)"
