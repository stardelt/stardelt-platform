#!/usr/bin/env bash
# Replay the captured Trino authorization questions against the live OPA bridge
# (stardelt-platform#333).
#
#   make bridge-replay                 # the whole contract, the probes, the matrix
#   bash scripts/bridge-replay.sh --data-only
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
#    else's query: false is by design) or `grants` (the catalog decides). A
#    `must-allow` row answered false is a DEFECT; an `owner-only` row answered
#    true is a FAIL. `ImpersonateUser` is the exception: its asking identity is
#    always `superset`, so it is asked in table 5.
# 2. The operations Trino 480 did not send in this capture (FilterFunctions,
#    CreateViewWithSelectFromColumns, ViewQueryOwnedBy, ReadSystemInformation),
#    asked with the shape the plugin builds for them.
# 3. The reads that must keep working for an ordinary person: SELECT 1
#    (ExecuteQuery), system.runtime.nodes, information_schema.
# 4. The permission matrix: AccessCatalog/FilterCatalogs on finance, product,
#    sandbox and warehouse, SelectFromColumns/InsertIntoTable/CreateSchema on
#    the seed tables — one expectation per row and person, from the seed's
#    grants (platform#309).
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
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
BRIDGE="${BRIDGE:-http://lakekeeper-opa:8282}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.10.1}"
FIXTURE="scripts/tests/fixtures/trino-opa-requests.json"
DATA_ONLY=0
[ "${1:-}" = "--data-only" ] && DATA_ONLY=1

fail() { echo "bridge-replay: $*" >&2; exit 1; }

for tool in kubectl python3 curl jq base64; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
[ -f "$FIXTURE" ] || fail "$FIXTURE is missing — run 'make bridge-capture' on a cluster first"
# The matrix is the dev seed's four catalogs (platform#309); on a cluster where
# they are not installed there is nothing to assert against, and an unmapped
# name would fail every row for the wrong reason.
for catalog in finance product sandbox warehouse; do
  kubectl -n "$NAMESPACE" get "catalogs.stardelt.io/$catalog" >/dev/null 2>&1 \
    || fail "no Catalog $catalog in namespace $NAMESPACE — run 'make seed-dev-access YES=1' first"
done

umask 077
tmp="$(mktemp -d)"
pod=""
cleanup() {
  keycloak_admin_stop
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
#    group. The bridge receives `sub`s, never usernames.
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

# 2. Build the plan: one job per (question, principal). The body is the
#    captured input with `<sub>` (the asking person) and `<peer>` (the other
#    person a query question is about) substituted; nothing else changes.
jobs="$(python3 - "$FIXTURE" "$tmp" "$DATA_ONLY" "${PRINCIPALS[@]}" <<'PY'
import json
import sys

fixture_path, out_dir, data_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
principals = []
for arg in sys.argv[4:]:
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
        query_id="", context=None):
    meta[job_id] = {
        "section": section,
        "operation": operation,
        "label": action_label(action),
        "class": klass,
        "labels": labels,
        "expect": expect,
    }
    for index, (_name, sub) in enumerate(principals):
        peer = subs[(index + 1) % len(subs)]
        person_body = json.dumps({"input": query_input(action, query_id, context)}) \
            .replace("<sub>", sub).replace("<peer>", peer)
        jobs.append({"id": "%s.%d" % (job_id, index), "path": path, "body": person_body})


ALLOW = "/v1/data/trino/allow"
BATCH = "/v1/data/trino/batch"
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

T = True
F = False

# -- table 4: the matrix ---------------------------------------------------
catalog_expected = {
    "finance": {"dev-finops": T, "dev-analytics": T, "dev-outsider": F, "admin": T},
    "product": {"dev-finops": T, "dev-analytics": T, "dev-outsider": F, "admin": T},
    "sandbox": {"dev-finops": T, "dev-analytics": T, "dev-outsider": T, "admin": T},
    "warehouse": {"dev-finops": T, "dev-analytics": T, "dev-outsider": T, "admin": T},
}
for catalog, expected in catalog_expected.items():
    add("mcat_" + catalog, "matrix", "AccessCatalog", ALLOW,
        {"operation": "AccessCatalog", "resource": {"catalog": {"name": catalog}}},
        expect={name: expected[name] for name in names})

filter_catalogs = ["finance", "product", "sandbox", "warehouse"]
add("mfiltercatalogs", "matrix", "FilterCatalogs", BATCH,
    {"operation": "FilterCatalogs",
     "filterResources": [{"catalog": {"name": catalog}} for catalog in filter_catalogs]},
    labels=filter_catalogs,
    expect={name: [catalog for catalog in filter_catalogs if catalog_expected[catalog][name]] for name in names})

DATA_ROWS = [
    ("SelectFromColumns", "finance", "seed", "nation", {"dev-finops": T, "dev-analytics": T, "dev-outsider": F, "admin": T}),
    ("InsertIntoTable", "finance", "seed", "nation", {"dev-finops": T, "dev-analytics": F, "dev-outsider": F, "admin": T}),
    ("SelectFromColumns", "product", "seed", "nation", {"dev-finops": F, "dev-analytics": T, "dev-outsider": F, "admin": T}),
    ("InsertIntoTable", "product", "seed", "nation", {"dev-finops": F, "dev-analytics": T, "dev-outsider": F, "admin": T}),
    ("SelectFromColumns", "sandbox", "seed", "nation", {"dev-finops": T, "dev-analytics": T, "dev-outsider": T, "admin": T}),
    ("InsertIntoTable", "sandbox", "seed", "nation", {"dev-finops": T, "dev-analytics": T, "dev-outsider": T, "admin": T}),
    ("SelectFromColumns", "warehouse", "covid", "covid_summary", {"dev-finops": T, "dev-analytics": T, "dev-outsider": T, "admin": T}),
]
for operation, catalog, schema, table, expected in DATA_ROWS:
    add("mdata_%s_%s" % (operation, catalog), "matrix", operation, ALLOW,
        {"operation": operation,
         "resource": {"table": {"catalogName": catalog, "schemaName": schema, "tableName": table}}},
        expect={name: expected[name] for name in names})

for catalog, expected in (
    ("finance", {"dev-finops": T, "dev-analytics": F, "dev-outsider": F, "admin": T}),
    ("product", {"dev-finops": F, "dev-analytics": T, "dev-outsider": F, "admin": T}),
    ("sandbox", {"dev-finops": T, "dev-analytics": T, "dev-outsider": T, "admin": T}),
    ("warehouse", {"dev-finops": T, "dev-analytics": T, "dev-outsider": T, "admin": T}),
):
    add("mcreate_" + catalog, "matrix", "CreateSchema", ALLOW,
        {"operation": "CreateSchema",
         "resource": {"schema": {"catalogName": catalog, "schemaName": "replay_probe", "properties": {}}}},
        expect={name: expected[name] for name in names})

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
    probes = [
        ("probe_filter_functions", "FilterFunctions", BATCH,
         {"operation": "FilterFunctions",
          "filterResources": [{"function": {"catalogName": "finance", "schemaName": "seed", "functionName": "abs"}}]},
         "grants", ["finance.seed(abs)"],
         {"dev-finops": ["finance.seed(abs)"], "dev-analytics": ["finance.seed(abs)"],
          "dev-outsider": [], "admin": ["finance.seed(abs)"]}),
        ("probe_create_view_select", "CreateViewWithSelectFromColumns", ALLOW,
         {"operation": "CreateViewWithSelectFromColumns",
          "resource": {"table": {"catalogName": "sandbox", "schemaName": "seed",
                                 "tableName": "nation", "columns": ["name"]}}},
         "grants", None, {name: True for name in names}),
        ("probe_view_owned", "ViewQueryOwnedBy", ALLOW,
         {"operation": "ViewQueryOwnedBy", "resource": {"user": {"user": "<peer>"}}},
         "owner-only", None, {name: False for name in names}),
        ("probe_read_system", "ReadSystemInformation", ALLOW,
         {"operation": "ReadSystemInformation"},
         "must-allow", None, {name: True for name in names}),
    ]
    for job, operation, path, action, klass, labels, expect in probes:
        add(job, "probe", operation, path, action, klass=klass, labels=labels, expect=expect)

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
    ("matrix", "4. The permission matrix (seed grants, platform#309)"),
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
            leaked = [name for name in names
                      if per_person[name] is True or (isinstance(per_person[name], list) and per_person[name])]
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
