#!/usr/bin/env bash
# Measure what an authorization question costs on the bridge (stardelt-platform#359).
#
#   make bridge-latency
#
# The companion of `make bridge-replay`: same four principals, same bridge, but
# this one asks the questions whose price grew with the catalog count —
# `FilterCatalogs` with every catalog of the cluster plus system/tpch/tpcds, one
# `AccessCatalog`, one `SelectFromColumns` on a table that exists — and prints
# what they cost, plus whether the answer is still the chart's own answer.
#
# Why it exists: every question that reaches Lakekeeper costs ~0.15 s per
# distinct catalog (PR #364), so `SHOW CATALOGS` cost 1 to 2 s cold. Since
# platform#359 the front rule (`stardelt.front.rego`) answers the catalog-level
# questions from the table access-sync publishes, with no Lakekeeper call at all
# when the table is fresh. This probe is the number that says whether that holds,
# and it is a gate: `make catalog-authz` runs it, `FilterCatalogs` must stay
# <= 0.2 s median and a single question <= 0.05 s, or the run exits 1.
#
# What it prints:
#
# 1. `FilterCatalogs` with every catalog: five cold runs per principal (the
#    check set is rotated so each run is a different body) and one warm repeat.
#    min/median/max; exit 1 if any median > 0.2 s.
# 2. One `AccessCatalog` and one `SelectFromColumns` per principal, three runs
#    each: the single-question path Trino uses for every query. Exit 1 above
#    0.05 s median.
# 3. Correctness: the allowed set from the front entry points
#    (`scripts/lib/bridge.sh`, what Trino calls) against the chart's own
#    `/v1/data/trino/*` for the same body — every principal and every question
#    must agree. This is the oracle for "no answer changed": the old rule is
#    still there, untouched, and both are asked live. The dev seed's matrix is
#    checked for whichever of its catalogs this cluster has.
#
# Nothing is written; the probe pod is labelled like the coordinator (the label
# NetworkPolicy `lakekeeper-ingress` admits to 8282) and deleted on exit,
# including on failure.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
BRIDGE="${BRIDGE:-http://lakekeeper-opa:8282}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.10.1}"
RUNS="${RUNS:-5}"
# The ticket's gate (platform#359): `SHOW CATALOGS` under 0.2 s median, and one
# single-resource question under 0.05 s.
MEDIAN_LIMIT="${MEDIAN_LIMIT:-0.2}"
SINGLE_LIMIT="${SINGLE_LIMIT:-0.05}"
# Three runs for the single questions: one measurement is noise, and the median
# of three is what the gate compares.
SINGLE_RUNS=3

# The paths Trino is configured with, not copies of them (platform#359), plus
# the chart's own rules as the oracle.
# shellcheck source=lib/bridge.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/bridge.sh"

fail() { echo "bridge-latency: $*" >&2; exit 1; }

for tool in kubectl python3 curl jq base64; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
kubectl -n "$NAMESPACE" get "catalogs.stardelt.io" >/dev/null 2>&1 \
  || fail "no Catalog CRD in namespace $NAMESPACE — nothing to measure (make install-core?)"

# Every catalog Trino has: the platform catalog, the Ready `Catalog` objects
# (the same list `make catalogs` renders) and the three Trino built-ins.
CATALOGS=(warehouse)
while IFS= read -r name; do
  [ -n "$name" ] && CATALOGS+=("$name")
done < <(NAMESPACE="$NAMESPACE" bash scripts/render-catalogs.sh list)
CATALOGS+=(system tpch tpcds)
[ "${#CATALOGS[@]}" -ge 4 ] || fail "only ${#CATALOGS[@]} catalogs to ask about"

umask 077
tmp="$(mktemp -d)"
pod=""
cleanup() {
  keycloak_admin_stop
  typeset -f bridge_tables_stop >/dev/null 2>&1 && bridge_tables_stop
  [ -z "$pod" ] || kubectl -n "$NAMESPACE" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck disable=SC2034
KC_LOG_PREFIX=bridge-latency
# shellcheck source=lib/keycloak-admin.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"

kc() { curl --silent --show-error --max-time 30 "${HEAD[@]}" "${AUTH[@]}" "$@"; }

# The four principals of the permission matrix: three seed people and one member
# of the admin group. The bridge sees `sub`s, never usernames.
declare -A SUB=()
for user in dev-finops dev-analytics dev-outsider; do
  sub="$(kc --get --data-urlencode "username=$user" --data-urlencode 'exact=true' "$API/users" \
    | jq -r '.[0].id // ""')"
  [ -n "$sub" ] || fail "no user $user in realm $REALM — run 'make seed-dev-access YES=1' first"
  SUB[$user]="$sub"
done
admin_group="$(kc --get --data-urlencode 'search=stardelt-admins' "$API/groups" \
  | jq -r '[.[] | select(.name == "stardelt-admins")][0].id // ""')"
[ -n "$admin_group" ] || fail "no group stardelt-admins in realm $REALM"
admin_sub="$(kc --get "$API/groups/$admin_group/members" | jq -r '.[0].id // ""')"
[ -n "$admin_sub" ] || fail "group stardelt-admins has no member to ask as"

PRINCIPALS=(
  "dev-finops|${SUB[dev-finops]}"
  "dev-analytics|${SUB[dev-analytics]}"
  "dev-outsider|${SUB[dev-outsider]}"
  "admin|$admin_sub"
)

# One table that exists (scripts/lib/bridge-tables.sh), for the single
# `SelectFromColumns` question: the front rule answers it from the table, and
# Lakekeeper would deny a table that is not there.
# shellcheck source=lib/bridge-tables.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/bridge-tables.sh"
# shellcheck disable=SC2034  # read by scripts/lib/bridge-tables.sh
BRIDGE_TABLES_LOG="$tmp/port-forward.log"
object_catalogs=()
for catalog in "${CATALOGS[@]}"; do
  case "$catalog" in
    system|tpch|tpcds) ;;
    *) object_catalogs+=("$catalog") ;;
  esac
done
TABLE_CATALOG=""
TABLE_SCHEMA=""
TABLE_NAME=""
if bridge_tables_init; then
  TABLE="$(bridge_tables "${object_catalogs[@]}" 2>/dev/null | head -1)"
else
  TABLE=""
fi
if [ -n "$TABLE" ]; then
  IFS="$(printf '\t')" read -r TABLE_CATALOG TABLE_SCHEMA TABLE_NAME <<<"$TABLE"
  echo "SelectFromColumns is measured on $TABLE_CATALOG.$TABLE_SCHEMA.$TABLE_NAME"
else
  echo "bridge-latency: no table found — the single SelectFromColumns rows are skipped" >&2
fi

# 1. The plan: `RUNS` cold bodies per principal (a rotation of the same catalog
#    set, so every body is new), one warm repeat, the chart's own answer for the
#    unrotated body, and the single questions. `SINGLE_RUNS` runs each, with
#    fresh bodies, so the front path cannot answer a repeated body from OPA's
#    own decision cache.
python3 - "$tmp" "$RUNS" "$SINGLE_RUNS" "$TABLE_CATALOG" "$TABLE_SCHEMA" "$TABLE_NAME" \
  "${CATALOGS[@]}" -- "${PRINCIPALS[@]}" <<'PY'
import json
import sys

out_dir, runs, single_runs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
table_catalog, table_schema, table_name = sys.argv[4], sys.argv[5], sys.argv[6]
args = sys.argv[7:]
split = args.index("--")
catalogs = args[:split]
principals = []
for arg in args[split + 1:]:
    name, sub = arg.rsplit("|", 1)
    principals.append((name, sub))

batch_jobs = []
single_jobs = []


def envelope(sub, action, query_id=None):
    context = {"identity": {"user": sub, "groups": []},
               "softwareStack": {"trinoVersion": "480"}, "properties": {}}
    if query_id:
        context["queryId"] = query_id
    return json.dumps({"input": {"context": context, "action": action}})


def batch_body(sub, names):
    return envelope(sub, {"operation": "FilterCatalogs",
                          "filterResources": [{"catalog": {"name": name}} for name in names]})


def catalog_body(sub, name, query_id):
    return envelope(sub, {"operation": "AccessCatalog",
                          "resource": {"catalog": {"name": name}}}, query_id)


def table_body(sub, catalog, schema, table, query_id):
    return envelope(sub, {"operation": "SelectFromColumns",
                          "resource": {"table": {"catalogName": catalog, "schemaName": schema,
                                                 "tableName": table}}}, query_id)


for name, sub in principals:
    order = []
    for run in range(runs):
        rotated = catalogs[run % len(catalogs):] + catalogs[:run % len(catalogs)]
        job_id = "cold.%s.%d" % (name, run)
        batch_jobs.append((job_id, "@BATCH@", batch_body(sub, rotated), rotated))
        order.append(rotated)
    batch_jobs.append(("warm.%s" % name, "@BATCH@", batch_body(sub, order[-1]), order[-1]))
    batch_jobs.append(("old.%s" % name, "@OLDBATCH@", batch_body(sub, catalogs), catalogs))
    # The same cold bodies on the chart's own path: the before/after of one run,
    # measured under the same conditions, with no Lakekeeper call avoided.
    for run in range(runs):
        rotated = catalogs[run % len(catalogs):] + catalogs[:run % len(catalogs)]
        batch_jobs.append(("oldcold.%s.%d" % (name, run), "@OLDBATCH@",
                           batch_body(sub, rotated), rotated))
    for run in range(single_runs):
        query_id = "20261021_120000_%05d_bench" % run
        single_jobs.append(("one.%s.%d" % (name, run), "@ALLOW@",
                            catalog_body(sub, catalogs[0], query_id), [catalogs[0]]))
        single_jobs.append(("oldone.%s.%d" % (name, run), "@OLDALLOW@",
                            catalog_body(sub, catalogs[0], query_id), [catalogs[0]]))
        if table_catalog:
            single_jobs.append(("tab.%s.%d" % (name, run), "@ALLOW@",
                                table_body(sub, table_catalog, table_schema, table_name, query_id),
                                [table_catalog]))
            single_jobs.append(("oldtab.%s.%d" % (name, run), "@OLDALLOW@",
                                table_body(sub, table_catalog, table_schema, table_name, query_id),
                                [table_catalog]))

with open(out_dir + "/jobs.tsv", "w", encoding="utf-8") as handle:
    for job_id, path, payload, names in batch_jobs + single_jobs:
        handle.write("%s\t%s\t%s\t%s\n" % (job_id, path, json.dumps(names), payload))
print(len(batch_jobs) + len(single_jobs))
PY
jobs_count="$(wc -l <"$tmp/jobs.tsv")"
[ "$jobs_count" -gt 0 ] || fail "the plan is empty"

# The four paths in one place.
sed -i -e "s|@BATCH@|$BRIDGE_BATCH_PATH|g" \
       -e "s|@OLDBATCH@|$BRIDGE_UPSTREAM_BATCH_PATH|g" \
       -e "s|@ALLOW@|$BRIDGE_ALLOW_PATH|g" \
       -e "s|@OLDALLOW@|$BRIDGE_UPSTREAM_ALLOW_PATH|g" "$tmp/jobs.tsv"

# 2. One throwaway pod labelled like the coordinator, one loop for the plan.
#    `time_total` is curl's wall time for the whole request — the number a
#    `SHOW CATALOGS` (or a query) waits for.
pod="qa-bridge-latency-$RANDOM"
kubectl -n "$NAMESPACE" run "$pod" --image="$PROBE_IMAGE" --restart=Never \
  --labels='app.kubernetes.io/name=trino,app.kubernetes.io/component=coordinator' \
  --command -- sleep 600 >/dev/null || fail "cannot start the probe pod"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null \
  || fail "the probe pod never became ready"

# shellcheck disable=SC2016
PROBE='
while IFS="$(printf "\t")" read -r id path names payload; do
  [ -n "$id" ] || continue
  raw=$(printf "%s" "$payload" | curl --silent --show-error --max-time 120 \
        --request POST "$1$path" --header "Content-Type: application/json" \
        --data-binary @- --write-out "\n%{time_total} %{http_code}" 2>/dev/null) || raw=""
  timing=$(printf "%s" "$raw" | tail -n 1)
  answer=$(printf "%s" "$raw" | sed "\$d" | tr -d "\n")
  printf "%s\t%s\t%s\t%s\n" "$id" "$timing" "$names" "$answer"
done
'
kubectl -n "$NAMESPACE" exec -i "$pod" -- sh -c "$PROBE" sh "$BRIDGE" \
  <"$tmp/jobs.tsv" >"$tmp/answers.tsv" || fail "the probe pod could not ask the bridge"

# 3. Judge. Latency first, then the answers.
python3 - "$tmp" "$MEDIAN_LIMIT" "$SINGLE_LIMIT" "$RUNS" "$SINGLE_RUNS" \
  "$TABLE_CATALOG" "$TABLE_SCHEMA" "$TABLE_NAME" -- "${PRINCIPALS[@]}" <<'PY'
import json
import statistics
import sys

out_dir, limit, single_limit = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
runs, single_runs = int(sys.argv[4]), int(sys.argv[5])
table_catalog, table_schema, table_name = sys.argv[6], sys.argv[7], sys.argv[8]
args = sys.argv[10:]
names = [arg.rsplit("|", 1)[0] for arg in args]

answers = {}
problems = []
for line in open(out_dir + "/answers.tsv", encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 4:
        problems.append("malformed probe output: %r" % line[:120])
        continue
    job_id, timing, resources, payload = parts
    resources = json.loads(resources)
    try:
        timing_value, code = timing.split()
        timing_value = float(timing_value)
    except ValueError:
        timing_value, code = None, "?"
    if code != "200":
        problems.append("%s: HTTP %s %s" % (job_id, code, payload[:120]))
    try:
        parsed = json.loads(payload)
    except ValueError:
        problems.append("%s: answer is not JSON: %r" % (job_id, payload[:120]))
        parsed = {}
    if "result" not in parsed or parsed["result"] is None:
        problems.append("%s: answer has no result: %r" % (job_id, payload[:120]))
        parsed = {"result": None}
    answers[job_id] = {"seconds": timing_value, "allowed": parsed["result"], "resources": resources}

first = answers.get("cold.%s.0" % names[0], {"resources": []})
print("FilterCatalogs: %d catalog(s) — %s" % (len(first["resources"]), ", ".join(first["resources"])))

exit_code = 0
if problems:
    print("bridge-latency: the bridge did not answer cleanly:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)
    exit_code = 1


def allowed_names(answer):
    allowed = answer.get("allowed")
    if not isinstance(allowed, list):
        return set()
    resources = answer["resources"]
    return {resources[i] for i in allowed if 0 <= i < len(resources)}


print("\n1. What one FilterCatalogs costs (%d cold runs, bodies rotated; `before` is the"
      " chart's own path on the same bodies)" % runs)
print("%-14s  %9s  %9s  %9s  %9s  %8s" % ("principal", "before", "median", "max", "warm", "cold"))
for name in names:
    cold = [answers["cold.%s.%d" % (name, run)]["seconds"] for run in range(runs)
            if answers.get("cold.%s.%d" % (name, run))]
    before = [answers["oldcold.%s.%d" % (name, run)]["seconds"] for run in range(runs)
              if answers.get("oldcold.%s.%d" % (name, run))]
    warm = answers.get("warm.%s" % name, {}).get("seconds")
    if not cold or any(value is None for value in cold) or warm is None:
        print("%-14s  %9s  %9s  %9s  %9s  %8s" % (name, "?", "?", "?", "?", "?"))
        exit_code = 1
        continue
    median = statistics.median(cold)
    before_median = statistics.median(before) if before else None
    verdict = "" if median <= limit else "  > %.2fs" % limit
    print("%-14s  %8s  %8.3fs  %8.3fs  %8.3fs  %8d%s" % (
        name,
        "%.3fs" % before_median if before_median is not None else "?",
        median, max(cold), warm, len(cold), verdict))
    if median > limit:
        exit_code = 1
    if allowed_names(answers["cold.%s.0" % name]) != allowed_names(answers["warm.%s" % name]):
        print("  FAIL: the warm (cached) answer differs from the cold one for %s" % name,
              file=sys.stderr)
        exit_code = 1

print("\n2. One question, what every query pays (median of %d, gate %.2fs)" % (single_runs, single_limit))
print("%-14s  %-28s  %8s  %s" % ("principal", "question", "median", "the chart's own rule"))
for name in names:
    rows = [("AccessCatalog %s" % first["resources"][0] if first["resources"] else "AccessCatalog",
             "one.%s" % name, "oldone.%s" % name)]
    if table_catalog:
        rows.append(("SelectFromColumns %s" % table_name, "tab.%s" % name, "oldtab.%s" % name))
    for label, front_prefix, upstream_prefix in rows:
        times = [answers["%s.%d" % (front_prefix, run)]["seconds"] for run in range(single_runs)
                 if answers.get("%s.%d" % (front_prefix, run))]
        fronts = [answers["%s.%d" % (front_prefix, run)]["allowed"] for run in range(single_runs)
                  if answers.get("%s.%d" % (front_prefix, run))]
        upstreams = [answers["%s.%d" % (upstream_prefix, run)]["allowed"] for run in range(single_runs)
                     if answers.get("%s.%d" % (upstream_prefix, run))]
        if not times or any(value is None for value in times):
            print("%-14s  %-28s  %8s  %s" % (name, label, "?", "?"))
            exit_code = 1
            continue
        median = statistics.median(times)
        same = all(front == upstream for front, upstream in zip(fronts, upstreams))
        verdict = "" if median <= single_limit else "  > %.2fs" % single_limit
        print("%-14s  %-28s  %7.4fs  %s%s" % (name, label, median,
                                              "identical" if same else "DIFFERS", verdict))
        if median > single_limit or not same:
            exit_code = 1

# The seed matrix of #309/#311, for whichever of its four catalogs exist here.
EXPECTED = {
    "finance": {"dev-finops": True, "dev-analytics": True, "dev-outsider": False, "admin": True},
    "product": {"dev-finops": True, "dev-analytics": True, "dev-outsider": False, "admin": True},
    "sandbox": {"dev-finops": True, "dev-analytics": True, "dev-outsider": True, "admin": True},
    "warehouse": {"dev-finops": True, "dev-analytics": True, "dev-outsider": True, "admin": True},
}
present = [catalog for catalog in EXPECTED if catalog in first["resources"]]
print("\n3. The answers, and whether the front rule agrees with the chart's rules")
print("%-14s  %-58s  %s" % ("principal", "allowed catalogs", "the chart's own rule"))
for name in names:
    front = answers["cold.%s.0" % name]
    old = answers["old.%s" % name]
    labels = front["resources"]
    allowed = [labels[i] for i in front["allowed"] if 0 <= i < len(labels)]
    same = front["allowed"] == old["allowed"]
    print("%-14s  %-58s  %s" % (name, ",".join(allowed) if allowed else "none",
                                "identical" if same else "DIFFERS"))
    if not same:
        exit_code = 1

if present:
    print("\n4. The permission matrix the dev seed declares (platform#309)")
    print("%-14s  %s" % ("principal", "".join("  %-10s" % catalog for catalog in present)))
    for name in names:
        front = answers["cold.%s.0" % name]
        labels = front["resources"]
        allowed = {labels[i] for i in front["allowed"] if 0 <= i < len(labels)}
        cells = ""
        wrong = []
        for catalog in present:
            got = catalog in allowed
            cells += "  %-10s" % ("yes" if got else "no")
            if got != EXPECTED[catalog][name]:
                wrong.append(catalog)
        print("%-14s  %s%s" % (name, cells, "  FAIL (%s)" % ",".join(wrong) if wrong else ""))
        if wrong:
            exit_code = 1
else:
    print("\n4. The dev seed's matrix is not installed on this cluster — skipped")

print("")
if exit_code == 0:
    print("bridge-latency: OK — every median <= %.2fs (single questions <= %.2fs), "
          "both paths agree" % (limit, single_limit))
else:
    print("bridge-latency: FAILED — see the rows above", file=sys.stderr)
sys.exit(exit_code)
PY
