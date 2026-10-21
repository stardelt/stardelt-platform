#!/usr/bin/env bash
# Replay the captured Trino authorization questions against the live OPA bridge
# (stardelt-platform#333).
#
#   make bridge-replay                 # the whole contract, the probes, the matrix
#   bash scripts/bridge-replay.sh --data-only
#   bash scripts/bridge-replay.sh --differential
#
# Reads scripts/tests/fixtures/trino-opa-requests.json (written by
# `make bridge-capture`), substitutes one person's Keycloak `sub` for `<sub>`,
# and POSTs each body to the bridge from a throwaway pod labelled like the Trino
# coordinator — the label NetworkPolicy `lakekeeper-ingress` admits on 8282. It
# writes nothing and deletes the pod on exit, including on failure.
#
# It prints five tables, in this order:
#
# 1. The contract: every captured (operation, resource kind) shape, asked for
#    the three seed people and one `stardelt-admins` member. Rows are
#    classified from the operation — `must-allow` (a person cannot use Trino
#    without it: ExecuteQuery, SetSystemSessionProperty, ReadSystemInformation,
#    ShowFunctions/FilterFunctions), `owner-only` (a question about someone
#    else's query: false by design for everyone but an administrator, who may
#    view and kill any query — the file rules' `queries` section and the
#    bridge's admin branch both allow it) or `grants` (the catalog decides). A
#    `must-allow` row answered false is a DEFECT; an `owner-only` row answered
#    true for a non-administrator asker is a FAIL. `ImpersonateUser` is the
#    exception: its asking identity is always `superset`, so it is asked in
#    table 5.
# 2. The operations Trino 480 did not send in this capture (FilterFunctions,
#    CreateViewWithSelectFromColumns, ViewQueryOwnedBy, ReadSystemInformation),
#    asked with the shape the plugin builds for them.
# 3. The reads the bridge must allow: SELECT 1 (ExecuteQuery),
#    information_schema, and `system.runtime.nodes` — the last one is answered
#    from `allowUnmanagedCatalogs`, and the engine's file rules have made that
#    catalog administrator-only (platform#363), so an ordinary person is refused
#    before the bridge is asked. It stays a row because the bridge's answer is
#    part of the contract (an administrator reaches it through both layers).
# 4. The permission matrix: AccessCatalog/FilterCatalogs on every Ready Catalog
#    in the namespace, CreateSchema on each, and SelectFromColumns/InsertIntoTable
#    on `<catalog>.seed.nation` (skipped where that table is absent) and on
#    `warehouse.covid.covid_summary` — one expectation per row and person,
#    computed from the live Catalog objects and the persons' Keycloak groups
#    (platform#365), not from a table in this script.
# 5. Impersonation (platform#342): the captured `ImpersonateUser` body asked
#    with a different asking identity per row. `superset` may act as a person
#    (a lowercase Keycloak `sub`) and no one else may act as anyone — a person,
#    a service account, `admin`, an uppercase UUID and a `nova`-like name are
#    all denied. Exit 1 on any row that disagrees.
#
# Exit 1 when any answer is a non-JSON body, an HTTP error, an empty body or a
# missing `result` (the bridge must always answer), when a table row
# disagrees, or when a must-allow row is denied. `--data-only` asks tables 4 and
# 5 only: they are the gate `make catalog-authz` and, after platform#311,
# `make catalog-enforce` run before they trust the bridge.
#
# The questions go to the paths Trino is configured with (`scripts/lib/bridge.sh`:
# `data/stardelt/allow` and `data/stardelt/batch` since platform#359), not to the
# paths the fixture was captured with — the fixture is the evidence of what Trino
# *sends*, and the replay must ask it where the engine will. A captured body is
# unchanged; only its path is mapped. `--differential` is the correctness gate of
# the catalog decision table (platform#359, ticket step 4): the front entry
# points (`data.stardelt.*`, answered from the table access-sync publishes) and
# the chart's own rules (`data.trino.*`, which ask Lakekeeper) must give the SAME
# answer for every question — every Trino catalog, every table that actually
# exists, the three seed people, an administrator and a principal that is in no
# group. It needs no fixture and no expectations: the two paths are the oracle
# for each other, and a single difference exits 1.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
BRIDGE="${BRIDGE:-http://lakekeeper-opa:8282}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.10.1}"
FIXTURE="scripts/tests/fixtures/trino-opa-requests.json"
MODE="full"
case "${1:-}" in
  --data-only) MODE="data-only" ;;
  --differential) MODE="differential" ;;
  "") ;;
  *) echo "usage: bridge-replay.sh [--data-only|--differential]" >&2; exit 2 ;;
esac
DATA_ONLY=0
[ "$MODE" = "data-only" ] && DATA_ONLY=1

# The paths the engine is configured with, not copies of them (platform#359).
# shellcheck source=lib/bridge.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/bridge.sh"

fail() { echo "bridge-replay: $*" >&2; exit 1; }

for tool in kubectl python3 curl jq base64; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
# The differential asks the two paths about each other and needs neither the
# captured fixture nor the layout's expectations.
[ "$MODE" = "differential" ] || [ -f "$FIXTURE" ] \
  || fail "$FIXTURE is missing — run 'make bridge-capture' on a cluster first"

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
KC_LOG_PREFIX=bridge-replay
# shellcheck source=lib/keycloak-admin.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-admin.sh"

kc() { curl --silent --show-error --max-time 30 "${HEAD[@]}" "${AUTH[@]}" "$@"; }

# 1. The four principals: the three seed people and one member of the admin
#    group. The bridge receives `sub`s, never usernames. Each principal's
#    Keycloak groups go with it: they are half of the live permission oracle
#    (scripts/lib/catalog-layout.py).
declare -A SUB=()
person_jsonl="$tmp/principals.jsonl"
: >"$person_jsonl"
add_person() {  # add_person <name> <keycloak-id>
  local person="$1" sub="$2" groups
  [ -n "$sub" ] || fail "no user $person in realm $REALM — run 'make seed-dev-access YES=1' first"
  groups="$(kc "$API/users/$sub/groups" | jq -c '[.[].name]')" \
    || fail "cannot read the groups of $person"
  SUB[$person]="$sub"
  jq -cn --arg name "$person" --arg sub "$sub" --argjson groups "$groups" \
    '{name: $name, sub: $sub, groups: $groups}' >>"$person_jsonl"
}

for user in dev-finops dev-analytics dev-outsider; do
  sub="$(kc --get --data-urlencode "username=$user" --data-urlencode 'exact=true' "$API/users" \
    | jq -r '.[0].id // ""')"
  add_person "$user" "$sub"
done

admin_group="$(kc --get --data-urlencode 'search=stardelt-admins' "$API/groups" \
  | jq -r '[.[] | select(.name == "stardelt-admins")][0].id // ""')"
[ -n "$admin_group" ] || fail "no group stardelt-admins in realm $REALM"
admin_sub="$(kc --get "$API/groups/$admin_group/members" | jq -r '.[0].id // ""')"
[ -n "$admin_sub" ] || fail "group stardelt-admins has no member to ask as"
add_person admin "$admin_sub"
jq -s '.' "$person_jsonl" >"$tmp/principals.json"



PRINCIPALS=(
  "dev-finops|${SUB[dev-finops]}"
  "dev-analytics|${SUB[dev-analytics]}"
  "dev-outsider|${SUB[dev-outsider]}"
  "admin|$admin_sub"
)

# The differential also asks as a principal that is in no group at all: a `sub`
# Trino would happily receive from a token, holding nothing. It is the deny side
# of the comparison — the table must deny it exactly where Lakekeeper does — and
# it needs no Keycloak user, because nobody has to be able to sign in as it.
if [ "$MODE" = "differential" ]; then
  PRINCIPALS+=("nobody|$(python3 -c 'import uuid; print(uuid.uuid4())')")
fi

# 3. One throwaway pod labelled like the coordinator (the only label
#    `lakekeeper-ingress` admits to 8282), used for every question.
start_probe_pod() {
  pod="qa-bridge-replay-$RANDOM"
  kubectl -n "$NAMESPACE" run "$pod" --image="$PROBE_IMAGE" --restart=Never \
    --labels='app.kubernetes.io/name=trino,app.kubernetes.io/component=coordinator' \
    --command -- sleep 1800 >/dev/null || fail "cannot start the probe pod"
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null \
    || fail "the probe pod never became ready"
}

# 4. Ask. One `kubectl exec` for the whole plan; the pod prints one
#    `<id>\t<http status>\t<body>` line per question. The script is single-quoted
#    on purpose: `$1`, `$path` and the rest are the pod's shell, not this file's.
# shellcheck disable=SC2016
PROBE='
while IFS="$(printf "\t")" read -r id path body; do
  [ -n "$id" ] || continue
  raw=$(printf "%s" "$body" | curl --silent --show-error --max-time 30 \
        --request POST "$1$path" --header "Content-Type: application/json" \
        --data-binary @- --write-out "\n%{http_code}" 2>/dev/null) || raw=""
  code=$(printf "%s" "$raw" | tail -n 1)
  payload=$(printf "%s" "$raw" | sed "\$d" | tr -d "\n")
  printf "%s\t%s\t%s\n" "$id" "$code" "$payload"
done
'

ask_bridge() {
  kubectl -n "$NAMESPACE" exec -i "$pod" -- sh -c "$PROBE" sh "$BRIDGE" \
    <"$tmp/jobs.tsv" >"$tmp/answers.tsv" || fail "the probe pod could not ask the bridge"
}

# ---------------------------------------------------------------------------
# --differential (platform#359, step 4): the front entry points against the
# chart's own rules, for every catalog and every table that exists.
# ---------------------------------------------------------------------------
if [ "$MODE" = "differential" ]; then
  # Every catalog Trino has: the platform catalog, the Ready `Catalog` objects
  # (the same list `make catalogs` renders) and the three Trino built-ins.
  CATALOGS=(warehouse)
  while IFS= read -r name; do
    [ -n "$name" ] && CATALOGS+=("$name")
  done < <(NAMESPACE="$NAMESPACE" bash scripts/render-catalogs.sh list)
  CATALOGS+=(system tpch tpcds)

  # The tables that actually exist (scripts/lib/bridge-tables.sh): Lakekeeper
  # denies a table that does not exist and Trino never asks about one, so a
  # synthetic name would compare a real answer with an impossible question.
  # shellcheck source=lib/bridge-tables.sh disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/lib/bridge-tables.sh"
  # shellcheck disable=SC2034  # read by scripts/lib/bridge-tables.sh
  BRIDGE_TABLES_LOG="$tmp/port-forward.log"
  bridge_tables_init || fail "cannot reach the catalog to list its tables"
  object_catalogs=()
  for catalog in "${CATALOGS[@]}"; do
    case "$catalog" in
      system|tpch|tpcds) ;;
      *) object_catalogs+=("$catalog") ;;
    esac
  done
  objects="$(bridge_tables "${object_catalogs[@]}")" || objects=""
  [ -n "$objects" ] || echo "bridge-replay: no table found — the differential asks the catalog-level questions only" >&2
  echo "bridge-replay: differential over ${#CATALOGS[@]} catalog(s) and $(printf '%s' "$objects" | grep -c . || true) table(s)"

  printf '%s\n' "$objects" >"$tmp/objects.tsv"
  pairs="$(python3 - "$tmp" "$tmp/objects.tsv" "$BRIDGE_ALLOW_PATH" "$BRIDGE_BATCH_PATH" \
    "$BRIDGE_UPSTREAM_ALLOW_PATH" "$BRIDGE_UPSTREAM_BATCH_PATH" \
    "${CATALOGS[@]}" -- "${PRINCIPALS[@]}" <<'PY'
import json
import sys

out_dir, objects_path, front_allow, front_batch, upstream_allow, upstream_batch = sys.argv[1:7]
args = sys.argv[7:]
split = args.index("--")
catalogs = args[:split]
objects = [
    line.split("\t")
    for line in open(objects_path, encoding="utf-8").read().splitlines()
    if line.strip()
]
principals = []
for arg in args[split + 1:]:
    name, sub = arg.rsplit("|", 1)
    principals.append((name, sub))

jobs = []
meta = {}


def add(label, body, batched=False):
    """One question, asked twice: front entry point and the chart's own rule."""
    job_id = "diff%04d" % len(meta)
    meta[job_id] = label
    if batched:
        jobs.append((job_id + ".front", front_batch, body))
        jobs.append((job_id + ".upstream", upstream_batch, body))
    else:
        jobs.append((job_id + ".front", front_allow, body))
        jobs.append((job_id + ".upstream", upstream_allow, body))


def envelope(user, action):
    return json.dumps({"input": {
        "context": {"identity": {"user": user, "groups": []},
                    "softwareStack": {"trinoVersion": "480"}, "properties": {}},
        "action": action,
    }})


for name, sub in principals:
    for catalog in catalogs:
        add("%s AccessCatalog %s" % (name, catalog),
            envelope(sub, {"operation": "AccessCatalog",
                           "resource": {"catalog": {"name": catalog}}}))
        add("%s CreateSchema %s" % (name, catalog),
            envelope(sub, {"operation": "CreateSchema",
                           "resource": {"schema": {"catalogName": catalog,
                                                   "schemaName": "replay_probe"}}}))
        for catalog_name, namespace, table in objects:
            if catalog_name != catalog:
                continue
            for operation in ("SelectFromColumns", "InsertIntoTable"):
                add("%s %s %s.%s.%s" % (name, operation, catalog, namespace, table),
                    envelope(sub, {"operation": operation,
                                   "resource": {"table": {"catalogName": catalog,
                                                          "schemaName": namespace,
                                                          "tableName": table}}}))
    add("%s FilterCatalogs" % name,
        envelope(sub, {"operation": "FilterCatalogs",
                       "filterResources": [{"catalog": {"name": catalog}}
                                           for catalog in catalogs]}),
        batched=True)

with open(out_dir + "/jobs.tsv", "w", encoding="utf-8") as jobs_file:
    for job_id, path, body in jobs:
        jobs_file.write("%s\t%s\t%s\n" % (job_id, path, body))
with open(out_dir + "/meta.json", "w", encoding="utf-8") as meta_file:
    json.dump(meta, meta_file)
print(len(meta))
PY
)"
  [ "$pairs" -gt 0 ] || fail "the differential plan is empty"

  start_probe_pod
  ask_bridge

  python3 - "$tmp" "${PRINCIPALS[@]}" <<'PY'
import json
import sys

out_dir = sys.argv[1]
names = [arg.rsplit("|", 1)[0] for arg in sys.argv[2:]]
meta = json.load(open(out_dir + "/meta.json", encoding="utf-8"))

answers = {}
problems = []
for line in open(out_dir + "/answers.tsv", encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3:
        problems.append("malformed probe output: %r" % line[:120])
        continue
    job_id, code, payload = parts
    if code != "200":
        problems.append("%s: HTTP %s %s" % (job_id, code, payload[:120]))
        continue
    try:
        parsed = json.loads(payload)
    except ValueError:
        problems.append("%s: answer is not JSON: %r" % (job_id, payload[:120]))
        continue
    if "result" not in parsed:
        problems.append("%s: answer has no result: %r" % (job_id, payload[:120]))
        continue
    answers[job_id] = parsed["result"]


def cell(value):
    if value is True:
        return "yes"
    if value is False:
        return "no"
    if isinstance(value, list):
        return "[" + ",".join(str(item) for item in value) + "]"
    return json.dumps(value)


print("\nThe differential — the front entry points against the chart's own rules")
width = max([len(name) for name in names] + [9])
question_width = max([len(label.split(" ", 1)[1]) for label in meta.values()] + [10])
print("%-*s  %-*s  %-12s  %-12s  verdict" % (width, "principal", question_width, "question",
                                             "front", "upstream"))

differences = []
for job_id, label in meta.items():
    principal, question = label.split(" ", 1)
    front = answers.get(job_id + ".front")
    upstream = answers.get(job_id + ".upstream")
    verdict = "ok" if front == upstream else "DIFFERS"
    if front != upstream:
        differences.append((label, front, upstream))
    print("%-*s  %-*s  %-12s  %-12s  %s" % (
        width, principal, question_width, question, cell(front), cell(upstream), verdict))

if problems:
    print("\nbridge-replay: the bridge did not answer cleanly:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)

print("")
if differences or problems:
    for label, front, upstream in differences:
        print("DIFFERENCE: %s — front %s, upstream %s" % (label, cell(front), cell(upstream)),
              file=sys.stderr)
    print("bridge-replay: the differential FAILED — %d question(s), %d difference(s)"
          % (len(meta), len(differences)), file=sys.stderr)
    sys.exit(1)
print("bridge-replay: the differential is clean — %d question(s) asked twice, every answer equal"
      % len(meta))
PY
  exit 0
fi


# 1b. The live layout: every Ready Catalog and the expectations the grants imply
#    (platform#365). The matrix below is built from this file, not from a list of
#    names in this script.
kubectl -n "$NAMESPACE" get catalogs.stardelt.io -o json >"$tmp/catalogs.json" \
  || fail "cannot list Catalogs in namespace $NAMESPACE"
python3 scripts/lib/catalog-layout.py \
  --catalogs "$tmp/catalogs.json" --principals "$tmp/principals.json" >"$tmp/layout.json" \
  || fail "cannot compute the expectations from the live Catalog objects"
[ "$(jq '.catalogs | length' "$tmp/layout.json")" -gt 0 ] \
  || fail "no Ready Catalog in namespace $NAMESPACE — install the platform first"

# 2. Build the plan: one job per (question, principal). The body is the
#    captured input with `<sub>` (the asking person) and `<peer>` (the other
#    person a query question is about) substituted; nothing else changes.
jobs="$(python3 - "$FIXTURE" "$tmp" "$DATA_ONLY" "$tmp/layout.json" \
  "$BRIDGE_BATCH_PATH" "$BRIDGE_ALLOW_PATH" "${PRINCIPALS[@]}" <<'PY'
import json
import sys

fixture_path, out_dir, data_only, layout_path = (
    sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4])
batch_path, allow_path = sys.argv[5], sys.argv[6]
principals = []
for arg in sys.argv[7:]:
    name, sub = arg.rsplit("|", 1)
    principals.append((name, sub))
subs = [sub for _, sub in principals]
names = [name for name, _ in principals]

fixture = json.load(open(fixture_path, encoding="utf-8"))
jobs = []
meta = {}


def resource_label(resource):
    """A short human label for one OpaQueryInputResource."""
    if not isinstance(resource, dict) or not resource:
        return "-"
    kind = next(iter(resource))
    entity = resource[kind]
    if kind == "catalog":
        return entity.get("name", "?")
    if kind == "schema":
        return "%s.%s" % (entity.get("catalogName"), entity.get("schemaName"))
    if kind == "table":
        return "%s.%s.%s" % (entity.get("catalogName"), entity.get("schemaName"), entity.get("tableName"))
    if kind == "function":
        return "%s.%s(%s)" % (entity.get("catalogName"), entity.get("schemaName"), entity.get("functionName"))
    if kind == "user":
        return entity.get("user", "?")
    if kind == "systemSessionProperty":
        return entity.get("name", "?")
    return kind


def action_label(action):
    resource = action.get("resource")
    if isinstance(resource, dict) and resource:
        return resource_label(resource)
    filtered = action.get("filterResources") or []
    if not filtered:
        return "-"
    labels = [resource_label(item) for item in filtered]
    if len(labels) == 1:
        return labels[0]
    return "%d: %s" % (len(labels), ",".join(labels))


def query_input(action, query_id="", context=None):
    """The OpaQueryInput wrapper Trino sends, with `<sub>` as the person.

    A captured request keeps its captured context: for FilterViewQueryOwnedBy
    and KillQueryOwnedBy the asking identity is `<peer>` and the resource's
    user is `<sub>`, which is the only way those two questions mean anything.
    """
    if context is None:
        context = {
            "identity": {"user": "<sub>", "groups": []},
            "softwareStack": {"trinoVersion": "480"},
            "properties": {},
        }
        if query_id:
            context["queryId"] = query_id
    return {"context": context, "action": action}


def add(job_id, section, operation, path, action, klass="grants", labels=None, expect=None,
        query_id="", context=None, gated=False):
    meta[job_id] = {
        "section": section,
        "operation": operation,
        "label": action_label(action),
        "class": klass,
        "labels": labels,
        "expect": expect,
        "gated": gated,
    }
    for index, (_name, sub) in enumerate(principals):
        peer = subs[(index + 1) % len(subs)]
        person_body = json.dumps({"input": query_input(action, query_id, context)}) \
            .replace("<sub>", sub).replace("<peer>", peer)
        jobs.append({"id": "%s.%d" % (job_id, index), "path": path, "body": person_body})


# The two entry points Trino is configured with (scripts/lib/bridge.sh): the
# stardelt front rules since platform#359. The chart's own rules are what
# `--differential` compares them against.
ALLOW = allow_path
BATCH = batch_path
MUST_ALLOW = {"ExecuteQuery", "ReadSystemInformation", "SetSystemSessionProperty", "ShowFunctions", "FilterFunctions"}
OWNER_ONLY = {"ViewQueryOwnedBy", "FilterViewQueryOwnedBy", "KillQueryOwnedBy"}
# ImpersonateUser is captured too, but its asking identity is the service
# account `superset`, not a seed person — it is asked in table 5.
IMPERSONATION = {"ImpersonateUser"}

# -- table 1: every captured shape, once per principal ---------------------
if not data_only:
    for index, request in enumerate(fixture["requests"]):
        operation = request["operation"]
        if operation in IMPERSONATION:
            continue
        if operation in MUST_ALLOW:
            klass = "must-allow"
        elif operation in OWNER_ONLY:
            klass = "owner-only"
        else:
            klass = "grants"
        action = request["input"]["action"]
        filtered = action.get("filterResources")
        add("capture%02d" % index, "contract", operation, request["path"], action, klass=klass,
            labels=[resource_label(item) for item in filtered] if filtered else None,
            context=request["input"].get("context"))

# -- table 4: the matrix, from the live Catalog objects --------------------
# platform#365: the expectation comes from the grants on the Catalog objects and
# the principals' Keycloak groups (scripts/lib/catalog-layout.py), so the
# maintainer's five-catalog layout works without a catalog name in this script.
layout = json.load(open(layout_path, encoding="utf-8"))
catalog_names = [catalog["name"] for catalog in layout["catalogs"]]
expect_by_catalog = {catalog["name"]: catalog["expect"] for catalog in layout["catalogs"]}


def granted(verb, catalog):
    return {name: expect_by_catalog[catalog][name][verb] for name in names}


for catalog in catalog_names:
    add("mcat_" + catalog, "matrix", "AccessCatalog", ALLOW,
        {"operation": "AccessCatalog", "resource": {"catalog": {"name": catalog}}},
        expect=granted("browse", catalog))

add("mfiltercatalogs", "matrix", "FilterCatalogs", BATCH,
    {"operation": "FilterCatalogs",
     "filterResources": [{"catalog": {"name": catalog}} for catalog in catalog_names]},
    labels=catalog_names,
    expect={name: [catalog for catalog in catalog_names
                   if expect_by_catalog[catalog][name]["browse"]] for name in names})

for catalog in catalog_names:
    add("mcreate_" + catalog, "matrix", "CreateSchema", ALLOW,
        {"operation": "CreateSchema",
         "resource": {"schema": {"catalogName": catalog, "schemaName": "replay_probe", "properties": {}}}},
        expect=granted("create", catalog))

# Data rows: the seed tables and the warehouse demo table. A table question on a
# table Lakekeeper does not have is false for everyone (`error-on-not-found:
# false`), so the judge asks these rows only where the admin's answer is true —
# an admin holds `project_admin`, which makes that answer the existence oracle.
DATA_TABLES = [(catalog, "seed", "nation") for catalog in catalog_names]
if "warehouse" in catalog_names:
    DATA_TABLES.append(("warehouse", "covid", "covid_summary"))
for catalog, schema, table in DATA_TABLES:
    for operation, verb in (("SelectFromColumns", "select"), ("InsertIntoTable", "write")):
        add("mdata_%s_%s_%s" % (operation, catalog, table), "matrix", operation, ALLOW,
            {"operation": operation,
             "resource": {"table": {"catalogName": catalog, "schemaName": schema, "tableName": table}}},
            expect=granted(verb, catalog), gated=True)

# -- table 3: reads that must keep working --------------------------------
if not data_only:
    for job, operation, resource in (
        ("req_select1", "ExecuteQuery", None),
        ("req_nodes", "SelectFromColumns",
         {"table": {"catalogName": "system", "schemaName": "runtime", "tableName": "nodes"}}),
        ("req_infoschema", "SelectFromColumns",
         {"table": {"catalogName": "warehouse", "schemaName": "information_schema", "tableName": "tables"}}),
    ):
        action = {"operation": operation}
        if resource:
            action["resource"] = resource
        add(job, "required", operation, ALLOW, action,
            klass="must-allow", expect={name: True for name in names})

# -- table 2: operations Trino 480 did not send in this capture -----------
if not data_only:
    # platform#365: both per-catalog probes name a catalog from the live layout,
    # not a fixture that may be absent. A function list follows the catalog's
    # `browse` (the chart's rule) and creating a view follows the table's
    # `select`; both are read from the live grants, not assumed.
    probes = [
        ("probe_filter_functions", "FilterFunctions", BATCH,
         {"operation": "FilterFunctions",
          "filterResources": [{"function": {"catalogName": "warehouse", "schemaName": "seed", "functionName": "abs"}}]},
         "grants", ["warehouse.seed(abs)"],
         {name: (["warehouse.seed(abs)"] if expect_by_catalog["warehouse"][name]["browse"] else [])
          for name in names}, False),
        ("probe_create_view_select", "CreateViewWithSelectFromColumns", ALLOW,
         {"operation": "CreateViewWithSelectFromColumns",
          "resource": {"table": {"catalogName": "warehouse", "schemaName": "covid",
                                 "tableName": "covid_summary", "columns": ["name"]}}},
         "grants", None, {name: expect_by_catalog["warehouse"][name]["select"] for name in names}, True),
        ("probe_view_owned", "ViewQueryOwnedBy", ALLOW,
         {"operation": "ViewQueryOwnedBy", "resource": {"user": {"user": "<peer>"}}},
         # The administrator may view anybody's query (file rules: `queries`
         # allows view/kill for `stardelt-admins`; bridge: `allow_admin_system_access`).
         "owner-only", None, {name: name == "admin" for name in names}, False),
        ("probe_read_system", "ReadSystemInformation", ALLOW,
         {"operation": "ReadSystemInformation"},
         "must-allow", None, {name: True for name in names}, False),
    ]
    for job, operation, path, action, klass, labels, expect, gated in probes:
        add(job, "probe", operation, path, action, klass=klass, labels=labels, expect=expect,
            gated=gated)

# -- table 5: impersonation (platform#342) --------------------------------
# The captured body, asked with a different identity per row: ImpersonateUser
# is not a question about the seed people, it is a question about who may act
# as whom. Trino asks it while the session is created, so the captured context
# has no `queryId`; nothing else changes.
impersonation_capture = next(
    request["input"] for request in fixture["requests"] if request["operation"] == "ImpersonateUser")
person_a, person_b = subs[0], subs[1]
IMPERSONATION_ROWS = [
    ("superset acts as a person", "superset", person_a, True),
    ("a name is not a person", "superset", "admin", False),
    ("a service account is not a person", "superset", "service-account-pipeline-runner", False),
    ("the person's sub is lowercase", "superset", person_a.upper(), False),
    ("a person may not act as a person", person_a, person_b, False),
    ("Nova forwards its own token", "nova", person_a, False),
]
for index, (label, asker, target, expected) in enumerate(IMPERSONATION_ROWS):
    body_input = json.loads(json.dumps(impersonation_capture))
    body_input["context"]["identity"]["user"] = asker
    body_input["action"]["resource"]["user"]["user"] = target
    job_id = "imp%02d" % index
    meta[job_id] = {
        "section": "impersonation",
        "operation": "ImpersonateUser",
        "label": label,
        "asker": asker,
        "target": target,
        "class": "grants",
        "labels": None,
        "expect": expected,
    }
    jobs.append({"id": job_id, "path": ALLOW, "body": json.dumps({"input": body_input})})

with open(out_dir + "/jobs.tsv", "w", encoding="utf-8") as jobs_file:
    for job in jobs:
        jobs_file.write("%s\t%s\t%s\n" % (job["id"], job["path"], job["body"]))
with open(out_dir + "/meta.json", "w", encoding="utf-8") as meta_file:
    json.dump(meta, meta_file)
print(len(jobs))

PY
)"
[ "$jobs" -gt 0 ] || fail "the plan is empty"

# 3. One throwaway pod labelled like the coordinator (the only label
#    `lakekeeper-ingress` admits to 8282), used for every question.
pod="qa-bridge-replay-$RANDOM"
kubectl -n "$NAMESPACE" run "$pod" --image="$PROBE_IMAGE" --restart=Never \
  --labels='app.kubernetes.io/name=trino,app.kubernetes.io/component=coordinator' \
  --command -- sleep 600 >/dev/null || fail "cannot start the probe pod"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null \
  || fail "the probe pod never became ready"

# 4. Ask. One `kubectl exec` for the whole plan; the pod prints one
#    `<id>\t<http status>\t<body>` line per question. The script is single-quoted
#    on purpose: `$1`, `$path` and the rest are the pod's shell, not this file's.
# shellcheck disable=SC2016
PROBE='
while IFS="$(printf "\t")" read -r id path body; do
  [ -n "$id" ] || continue
  raw=$(printf "%s" "$body" | curl --silent --show-error --max-time 30 \
        --request POST "$1$path" --header "Content-Type: application/json" \
        --data-binary @- --write-out "\n%{http_code}" 2>/dev/null) || raw=""
  code=$(printf "%s" "$raw" | tail -n 1)
  payload=$(printf "%s" "$raw" | sed "\$d" | tr -d "\n")
  printf "%s\t%s\t%s\n" "$id" "$code" "$payload"
done
'
kubectl -n "$NAMESPACE" exec -i "$pod" -- sh -c "$PROBE" sh "$BRIDGE" \
  <"$tmp/jobs.tsv" >"$tmp/answers.tsv" || fail "the probe pod could not ask the bridge"

# 5. Judge: compare with the expectations, print the tables, set the exit code.
python3 - "$tmp" "$DATA_ONLY" "${PRINCIPALS[@]}" <<'PY'
import json
import sys

out_dir, data_only = sys.argv[1], sys.argv[2] == "1"
names = [arg.rsplit("|", 1)[0] for arg in sys.argv[3:]]

meta = json.load(open(out_dir + "/meta.json", encoding="utf-8"))
answers = {}
problems = []

for line in open(out_dir + "/answers.tsv", encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3:
        problems.append("malformed probe output: %r" % line[:120])
        continue
    job_id, code, payload = parts
    if code != "200":
        problems.append("%s: HTTP %s %s" % (job_id, code, payload[:120]))
        answers[job_id] = None
        continue
    try:
        parsed = json.loads(payload)
    except ValueError:
        problems.append("%s: answer is not JSON: %r" % (job_id, payload[:120]))
        answers[job_id] = None
        continue
    if "result" not in parsed or parsed["result"] is None:
        problems.append("%s: answer has no result: %r" % (job_id, payload[:120]))
        answers[job_id] = None
        continue
    answers[job_id] = parsed["result"]


def normalize(job_id, value):
    """Map a bridge answer to what the expectation compares against."""
    labels = meta[job_id.rsplit(".", 1)[0]]["labels"]
    if isinstance(value, list) and labels is not None:
        return [labels[index] for index in value if 0 <= index < len(labels)]
    return value


def cell(value):
    if value is True:
        return "yes"
    if value is False:
        return "no"
    if value is None:
        return "?"
    if isinstance(value, list):
        return ",".join(value) if value else "none"
    return json.dumps(value)


sections = [
    ("contract", "1. The contract — every shape Trino 480 sent, asked for four principals"),
    ("probe", "2. Operations Trino 480 did not send in this capture (shape from the plugin)"),
    ("required", "3. Reads that must keep working"),
    ("matrix", "4. The permission matrix (live Catalog grants and Keycloak groups, platform#365)"),
    ("impersonation", "5. Impersonation — only Superset may act as a person (platform#342)"),
]

exit_code = 0
if problems:
    print("bridge-replay: the bridge did not answer cleanly:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)
    exit_code = 1

for section, title in sections:
    if data_only and section not in ("matrix", "impersonation"):
        continue
    print("\n" + title)
    keys = [key for key in meta if meta[key]["section"] == section]
    if section == "impersonation":
        width = max([len(meta[key]["asker"]) for key in keys] + [6])
        print("%-*s  %-38s  %-6s  %s" % (width, "asking", "target", "answer", "verdict  case"))
        for job_id in keys:
            request_meta = meta[job_id]
            answer = answers.get(job_id)
            want = request_meta["expect"]
            verdict = "ok" if answer is want else "FAIL"
            note = ""
            if answer is not want:
                note = "(want %s)" % cell(want)
                exit_code = 1
            print("%-*s  %-38s  %-6s  %-7s %s %s" % (width, request_meta["asker"],
                                                     request_meta["target"][:38],
                                                     cell(answer), verdict,
                                                     request_meta["label"], note))
        continue
    width = max([len(meta[key]["operation"]) for key in keys] + [9])
    print("%-*s  %-40s%s  verdict" % (width, "operation", "resource",
                                      "".join("  %-24s" % name for name in names)))
    for job_id in keys:
        request_meta = meta[job_id]
        per_person = {}
        for index, name in enumerate(names):
            raw = answers.get("%s.%d" % (job_id, index))
            per_person[name] = normalize("%s.%d" % (job_id, index), raw)
        cells = "".join("  %-24s" % cell(per_person[name]) for name in names)
        expect = request_meta["expect"]
        klass = request_meta["class"]
        if request_meta.get("gated") and "admin" in names:
            admin_answer = answers.get("%s.%d" % (job_id, names.index("admin")))
            if admin_answer is False:
                # The admin holds `project_admin`: a false table answer means the
                # table does not exist, and Lakekeeper answers false for every
                # person then. Skipping is the honest verdict, not a FAIL.
                print("%-*s  %-40s%s  %-7s %s" % (
                    width, request_meta["operation"], request_meta["label"][:40],
                    "".join("  %-24s" % "-" for name in names), "skip",
                    "(no such table — the fixtures create it)"))
                continue
        verdict = "ok"
        note = ""
        if expect is not None:
            wrong = []
            for name in names:
                if name in expect and per_person[name] != expect[name]:
                    wrong.append("%s want %s" % (name, cell(expect[name])))
            if wrong:
                verdict = "FAIL"
                note = "(" + "; ".join(wrong) + ")"
                exit_code = 1
        elif klass == "must-allow":
            denied = [name for name in names if per_person[name] is not True]
            if denied:
                verdict = "DEFECT"
                note = "(denied: %s)" % ",".join(denied)
                exit_code = 1
        elif klass == "owner-only":
            # These questions are about somebody else's query, and the captured
            # body says who asks: the context identity is `<peer>` and the
            # resource is `<sub>` (see `query_input`), so row i's answer is the
            # answer for the *next* principal in the list, not for the person
            # the column is named after. An administrator may view any query
            # (`queries` file rules, the bridge's admin branch), so exactly the
            # rows whose asker is the administrator may come back allowed.
            leaked = []
            for index, name in enumerate(names):
                asker = names[(index + 1) % len(names)]
                allowed = per_person[name] is True or (
                    isinstance(per_person[name], list) and per_person[name])
                if allowed and asker != "admin":
                    leaked.append("%s (asked by %s)" % (name, asker))
            if leaked:
                verdict = "FAIL"
                note = "(allowed: %s)" % ",".join(leaked)
                exit_code = 1
        if klass == "must-allow" and verdict == "ok":
            note = "(required)"
        print("%-*s  %-40s%s  %-7s %s" % (width, request_meta["operation"],
                                          request_meta["label"][:40], cells, verdict, note))

print("")
if exit_code == 0:
    print("bridge-replay: OK — %d question(s) answered, every assertion holds" % len(answers))
else:
    print("bridge-replay: FAILED — see the rows marked DEFECT/FAIL above", file=sys.stderr)
sys.exit(exit_code)
PY
