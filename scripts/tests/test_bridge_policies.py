"""The bridge's catalog decision table, proved against a stub Lakekeeper (#359).

Run by `scripts/test-bridge-policies.sh` (CI, `make test-bridge-policies`), which
renders the Lakekeeper chart with this repo's values file and points
`BRIDGE_POLICY_DIR` at the extracted `lakekeeper-opa-policies` ConfigMap. This
module then:

* starts a stub Lakekeeper on a thread — the token endpoint, the warehouse-name
  lookup and `/management/v1/action/batch-check` — which implements Lakekeeper's
  relation model and its implication table (`modify` implies `select` implies
  `describe`, `create` implies `describe`, `manage_grants` implies nothing) and
  counts every request it answers;
* runs the real OPA engine (`opa eval`) over the chart's policies plus both
  stardelt files, so `http.send`, `time.now_ns()` and the policy behaviour are
  the ones the cluster runs;
* asks `data.stardelt.allow` / `data.stardelt.batch` and, for the same body,
  `data.trino.allow` / `data.trino.batch` (the chart's own rules) — the two must
  agree for every question, because the table may only ACCELERATE.

The cluster layout it describes is deliberately not the live one, and not the
deleted dev seed: each verb is held by a different group, so the implications,
the owner group (manage only) and a static assignee are all distinguishable.
`Grants`/`Objects` below are Lakekeeper's side of the story, written by hand;
`SPECS`/`MEMBERS`/`STATIC` are the `Catalog` objects' side, and the table the
tests publish is built by the job's own `catalog_verb_lists` — so a disagreement
between the two representations fails the differential instead of hiding.
"""
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import importlib.util

POLICY_DIR = os.environ.get("BRIDGE_POLICY_DIR", "")
OPA = os.environ.get("OPA", "opa")
JOB = Path(__file__).resolve().parents[1] / "access-sync-job.py"

_spec = importlib.util.spec_from_file_location("access_sync_job_bridge", JOB)
access_sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(access_sync)

# --- the two descriptions of the same intent ------------------------------

# Keycloak group members, by `sub` (what Trino sends as the user).
MEMBERS = {
    "finops": {"sub-finops"},
    "analytics": {"sub-ana"},
    "builders": {"sub-build"},
    "stewards": {"sub-steward"},
    "stardelt-users": {"sub-users"},
    "stardelt-admins": {"sub-admin"},
}
# Assignees with no Keycloak user (manifests/access-sync.yaml: `superset`).
STATIC = {"stardelt-users": {"superset"}}

# The `Catalog` objects: each verb on a different group, the owner holding only
# `manage` (so it must not be able to browse), `stardelt-users` browsing the
# platform catalog.
SPECS = {
    "gold": {
        "owner": "stewards",
        "grants": [
            {"group": "finops", "verb": "browse"},
            {"group": "analytics", "verb": "select"},
            {"group": "builders", "verb": "create"},
        ],
    },
    "silver": {
        "owner": "stewards",
        "grants": [{"group": "analytics", "verb": "write"}],
    },
    "warehouse": {
        "owner": "stewards",
        "grants": [{"group": "stardelt-users", "verb": "browse"}],
    },
}

# The same thing on Lakekeeper's side, as `sync_warehouse_grants` writes it: the
# verb->relation map of scripts/access-sync-job.py, spelled out.
GRANTS = {
    "gold": {
        ("stewards", "manage_grants"),
        ("finops", "describe"),
        ("analytics", "select"),
        ("builders", "create"),
    },
    "silver": {
        ("stewards", "manage_grants"),
        ("analytics", "modify"),
    },
    "warehouse": {
        ("stewards", "manage_grants"),
        ("stardelt-users", "describe"),
    },
}
# Every member of `stardelt-admins` is a `project_admin` of the project.
PROJECT_ADMINS = {"sub-admin"}
# What exists. A table that does not exist is denied by Lakekeeper even when the
# warehouse grant would allow it (measured on the dev cluster), which is why the
# policy's object-level fast path can only ever widen: Trino only asks about
# objects it has already resolved.
OBJECTS = {
    "gold": {"retail_demo": {"taxi_daily_metrics": "table"}},
    "silver": {"retail_demo": {"yellow_taxi_clean": "table"}},
    "warehouse": {"covid": {"covid_summary": "table"}},
}

# Lakekeeper's actions per relation, and what each relation implies. This is the
# model the ticket states; the stub answers from it so the chart's own rules are
# asked a faithful Lakekeeper.
ACTIONS = {
    "describe": {"get_config", "list_namespaces", "get_metadata"},
    "select": {"read_data"},
    "modify": {"write_data", "commit", "drop", "rename", "delete"},
    "create": {"create_namespace", "create_table", "create_view"},
    "manage_grants": {"manage_grants"},
}
IMPLIES = {
    "manage_grants": set(),
    "create": {"describe"},
    "modify": {"select", "describe"},
    "select": {"describe"},
    "describe": set(),
}
ADMITTED = {"sub-finops", "sub-ana", "sub-build", "sub-steward", "sub-users", "superset", "sub-admin"}
MAPPED = ("gold", "silver", "warehouse")
UNMANAGED = ("system", "tpch")


def relation_for(action):
    """The relation Lakekeeper needs for one action, or None."""
    for relation, actions in ACTIONS.items():
        if action in actions:
            return relation
    return None


class StubLakekeeper:
    """Token endpoint, warehouse lookup and batch-check, on a thread.

    Counts every request so a test can prove the policy did (or did not) ask
    Lakekeeper. Answers exactly what the real one answers for this model.
    """

    def __init__(self):
        self.requests = []
        self.token_requests = 0
        # Authorization calls only: what a decision costs. The chart's rules also
        # look a warehouse id up (`/catalog/v1/config`), which the bridge caches
        # for an hour and which authorizes nothing, so it is not counted here.
        self.authorizations = 0
        state = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _reply(self, code, payload):
                raw = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_POST(self):
                state.requests.append(self.path)
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                if self.path == "/token":
                    # form-encoded, not JSON: read it and answer the only token.
                    state.token_requests += 1
                    self._reply(200, {"access_token": "stub-token"})
                    return
                body = json.loads(raw or b"{}")
                if self.path != "/management/v1/action/batch-check":
                    self._reply(404, {"type": "not found"})
                    return
                state.authorizations += 1
                results = [{"allowed": allows_check(check)} for check in body.get("checks") or []]
                self._reply(200, {"results": results, "batch-results": results})

            def do_GET(self):
                state.requests.append(self.path)
                path, _, query = self.path.partition("?")
                if path != "/catalog/v1/config":
                    self._reply(404, {"type": "not found"})
                    return
                warehouse = None
                for part in query.split("&"):
                    if part.startswith("warehouse="):
                        warehouse = part.split("=", 1)[1]
                if warehouse not in GRANTS:
                    self._reply(404, {"type": "not found"})
                    return
                self._reply(200, {"defaults": {"prefix": "prefix-" + warehouse}})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        )
        self.thread.start()

    def authorized(self):
        """How many authorization checks the policy asked Lakekeeper for."""
        return self.authorizations

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def warehouse_of(value):
    """The warehouse name behind a `warehouse-id` the stub handed out."""
    return value[len("prefix-"):] if value.startswith("prefix-") else None


def allows_check(check):
    """One Lakekeeper batch-check, answered from the model above."""
    identity = (check.get("identity") or {}).get("user") or ""
    principal = identity[len("oidc~"):] if identity.startswith("oidc~") else identity
    operation = check.get("operation") or {}
    kind = next(iter(operation))
    detail = operation[kind]
    action = (detail.get("action") or {}).get("action")
    relation = relation_for(action)
    warehouse = warehouse_of(detail.get("warehouse-id") or "")
    if relation is None or warehouse not in GRANTS:
        return False

    def holds(required):
        if principal in PROJECT_ADMINS:
            return True
        # Lakekeeper's assignees are `oidc~<sub>`; the model here holds the bare
        # `sub` (a Keycloak member's id) and bare static principals (`superset`).
        for role, granted in GRANTS[warehouse]:
            if principal not in MEMBERS.get(role, set()) and principal not in STATIC.get(
                role, set()
            ):
                continue
            if required == granted or required in IMPLIES[granted]:
                return True
        return False

    if kind == "warehouse":
        return holds(relation)
    if kind == "namespace":
        namespace = ".".join(detail.get("namespace") or [])
        if action.startswith("create_"):
            return holds(relation)
        return namespace in OBJECTS.get(warehouse, {}) and holds(relation)
    if kind in ("table", "view"):
        namespace = ".".join(detail.get("namespace") or [])
        name = detail.get("table")
        found = OBJECTS.get(warehouse, {}).get(namespace, {}).get(name)
        if action in ("create_table", "create_view"):
            found = kind if namespace in OBJECTS.get(warehouse, {}) else None
        return found == kind and holds(relation)
    return False


def catalog_body(user, catalog):
    return {
        "context": {"identity": {"user": user, "groups": []},
                    "softwareStack": {"trinoVersion": "480"}, "properties": {}},
        "action": {"operation": "AccessCatalog", "resource": {"catalog": {"name": catalog}}},
    }


def table_body(user, operation, catalog, namespace, table):
    return {
        "context": {"identity": {"user": user, "groups": []},
                    "softwareStack": {"trinoVersion": "480"}, "properties": {}},
        "action": {
            "operation": operation,
            "resource": {"table": {"catalogName": catalog, "schemaName": namespace,
                                   "tableName": table}},
        },
    }


def schema_body(user, catalog, name="replay_probe"):
    return {
        "context": {"identity": {"user": user, "groups": []},
                    "softwareStack": {"trinoVersion": "480"}, "properties": {}},
        "action": {
            "operation": "CreateSchema",
            "resource": {"schema": {"catalogName": catalog, "schemaName": name,
                                    "properties": {}}},
        },
    }


def filter_catalogs_body(user, catalogs):
    return {
        "context": {"identity": {"user": user, "groups": []},
                    "softwareStack": {"trinoVersion": "480"}, "properties": {}},
        "action": {
            "operation": "FilterCatalogs",
            "filterResources": [{"catalog": {"name": name}} for name in catalogs],
        },
    }


def filter_columns_body(user, catalog, namespace, table, columns):
    return {
        "context": {"identity": {"user": user, "groups": []},
                    "softwareStack": {"trinoVersion": "480"}, "properties": {}},
        "action": {
            "operation": "FilterColumns",
            "filterResources": [{"table": {"catalogName": catalog, "schemaName": namespace,
                                           "tableName": table, "columns": columns}}],
        },
    }


def access_table(drift=(), now=None, omit=()):
    """The document access-sync publishes, built by the job's own function."""
    import time

    stamp = int(time.time()) if now is None else now
    catalogs = []
    for name, spec in SPECS.items():
        if name in omit:
            continue
        catalogs.append((name, spec, 1 if name in drift else 0))
    table = access_sync.access_table(catalogs, MEMBERS, STATIC)
    table["generatedAt"] = stamp
    return table


class BridgePolicyTest(unittest.TestCase):
    """Every case from ticket #359, step 5, plus the differential."""

    @classmethod
    def setUpClass(cls):
        if not POLICY_DIR:
            raise unittest.SkipTest("BRIDGE_POLICY_DIR is not set")
        if not Path(POLICY_DIR).is_dir():
            raise RuntimeError("%s is not a directory" % POLICY_DIR)
        if not (os.sep in OPA or Path(OPA).exists()):
            raise RuntimeError("the opa binary is not on PATH (set OPA=/path/to/opa)")
        cls.stub = StubLakekeeper()
        cls.env = dict(os.environ)
        cls.env.update(
            {
                "LAKEKEEPER_URL": cls.stub.url,
                "LAKEKEEPER_TOKEN_ENDPOINT": cls.stub.url + "/token",
                "LAKEKEEPER_CLIENT_ID": "stub-client",
                "LAKEKEEPER_CLIENT_SECRET": "stub-secret",
                "LAKEKEEPER_SCOPE": "lakekeeper",
                "TRINO_ALLOW_UNMANAGED_CATALOGS": "true",
            }
        )
        cls.env.pop("TRINO_ADMIN_USERS", None)
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.addClassCleanup(cls.stub.stop)

    def setUp(self):
        self.stub.requests.clear()
        self.stub.token_requests = 0
        self.stub.authorizations = 0
        self._files = 0

    # -- the engine --------------------------------------------------------

    def _file(self, payload):
        self._files += 1
        path = Path(self.tmp.name) / ("%s-%d-%d.json" % (self.id(), self._files, os.getpid()))
        path.write_text(json.dumps(payload), encoding="utf-8")
        return str(path)

    def _eval(self, query, body, table):
        args = [OPA, "eval", "--format=json", "-d", POLICY_DIR]
        if table is not None:
            args += ["-d", self._file({"stardelt": {"access": table}})]
        args += ["-i", self._file(body), query]
        completed = subprocess.run(args, capture_output=True, text=True, timeout=120,
                                   env=self.env)
        self.assertEqual(
            completed.returncode, 0,
            "opa eval failed: %s" % (completed.stderr or completed.stdout)[:800],
        )
        payload = json.loads(completed.stdout)
        if not payload.get("result"):
            return {}
        return payload["result"][0]["expressions"][0]["value"]

    def front(self, body, table, batched=False):
        """The front entry point's answer, without asking the chart's rules."""
        query = "data.stardelt.batch" if batched else "data.stardelt.allow"
        # `data.trino.*` is only consulted by the policy as its fallback, so the
        # call count below says whether the table answered on its own.
        return self._eval(query, body, table)

    def both(self, body, table, batched=False):
        """`(front, upstream)` in ONE evaluation, for the differential."""
        if batched:
            query = '{"front": data.stardelt.batch, "upstream": data.trino.batch}'
        else:
            query = '{"front": data.stardelt.allow, "upstream": data.trino.allow}'
        value = self._eval(query, body, table)
        return value.get("front"), value.get("upstream")

    # -- step 5: the ticket's cases ---------------------------------------

    def test_fresh_table_allows_a_catalog_without_asking_lakekeeper(self):
        self.assertIs(self.front(catalog_body("sub-finops", "gold"), access_table()), True)
        self.assertEqual(self.stub.authorized(), 0, "a fresh table must answer on its own")
        self.assertEqual(self.stub.token_requests, 0, "not even a token request")

    def test_fresh_table_denies_a_catalog_without_asking_lakekeeper(self):
        """The catalog-level answer is decisive in BOTH directions."""
        self.assertIs(self.front(catalog_body("sub-finops", "silver"), access_table()), False)
        self.assertEqual(self.stub.authorized(), 0)

    def test_a_stale_table_falls_through_to_lakekeeper(self):
        self.assertIs(self.front(catalog_body("sub-finops", "gold"), access_table(now=0)), True)
        self.assertGreater(self.stub.authorized(), 0, "a stale table must not answer")
        self.assertIs(self.front(catalog_body("sub-finops", "silver"), access_table(now=0)), False)

    def test_a_missing_table_falls_through_to_lakekeeper(self):
        self.assertIs(self.front(catalog_body("sub-finops", "gold"), None), True)
        self.assertGreater(self.stub.authorized(), 0)

    def test_a_catalog_missing_from_the_table_falls_through(self):
        """A Catalog that became Ready since the last tick is not in it yet."""
        table = access_table(omit=("gold",))
        self.assertIs(self.front(catalog_body("sub-finops", "gold"), table), True)
        self.assertGreater(self.stub.authorized(), 0)

    def test_drift_falls_through_to_lakekeeper(self):
        table = access_table(drift=("gold",))
        self.assertIs(self.front(catalog_body("sub-finops", "gold"), table), True)
        self.assertGreater(self.stub.authorized(), 0, "a drifted catalog must not be answered locally")

    def test_an_object_level_denial_falls_through_to_lakekeeper(self):
        """A browse holder is no select holder: the denial is Lakekeeper's."""
        body = table_body("sub-finops", "SelectFromColumns", "gold", "retail_demo",
                          "taxi_daily_metrics")
        self.assertIs(self.front(body, access_table()), False)
        self.assertGreater(self.stub.authorized(), 0, "the policy may never deny an object question")

    def test_an_object_level_allow_does_not_ask_lakekeeper(self):
        body = table_body("sub-ana", "SelectFromColumns", "gold", "retail_demo",
                          "taxi_daily_metrics")
        self.assertIs(self.front(body, access_table()), True)
        self.assertEqual(self.stub.authorized(), 0)

    def test_an_admin_is_allowed_through_the_all_list(self):
        for catalog, operation, body in (
            ("gold", "AccessCatalog", catalog_body("sub-admin", "gold")),
            ("silver", "SelectFromColumns",
             table_body("sub-admin", "SelectFromColumns", "silver", "retail_demo",
                        "yellow_taxi_clean")),
        ):
            with self.subTest(catalog=catalog, operation=operation):
                self.assertIs(self.front(body, access_table()), True)
                self.assertEqual(self.stub.authorized(), 0)

    def test_write_implies_select_implies_browse(self):
        """`analytics` holds `write` on silver: everything below it is implied."""
        table = access_table()
        self.assertIs(self.front(catalog_body("sub-ana", "silver"), table), True)
        self.assertIs(self.front(table_body("sub-ana", "SelectFromColumns", "silver",
                                            "retail_demo", "yellow_taxi_clean"), table), True)
        self.assertIs(self.front(table_body("sub-ana", "InsertIntoTable", "silver",
                                            "retail_demo", "yellow_taxi_clean"), table), True)
        self.assertEqual(self.stub.authorized(), 0)

    def test_select_does_not_imply_write(self):
        table = access_table()
        self.assertIs(self.front(table_body("sub-ana", "InsertIntoTable", "gold",
                                            "retail_demo", "taxi_daily_metrics"), table), False)
        self.assertGreater(self.stub.authorized(), 0, "the write denial comes from Lakekeeper")

    def test_create_implies_browse(self):
        table = access_table()
        self.assertIs(self.front(catalog_body("sub-build", "gold"), table), True)
        self.assertIs(self.front(schema_body("sub-build", "gold"), table), True)
        self.assertIs(self.front(table_body("sub-build", "SelectFromColumns", "gold",
                                            "retail_demo", "taxi_daily_metrics"), table), False)
        self.assertGreater(self.stub.authorized(), 0, "only the select question reaches Lakekeeper")

    def test_a_static_assignee_is_in_the_table(self):
        """`superset` has no Keycloak user; `stardelt-users` holds browse on warehouse."""
        self.assertIs(self.front(catalog_body("superset", "warehouse"), access_table()), True)
        self.assertEqual(self.stub.authorized(), 0)

    def test_the_owner_group_gets_no_browse(self):
        """Ownership is `manage_grants`; it grants no data right (design §5.3)."""
        table = access_table()
        self.assertIs(self.front(catalog_body("sub-steward", "gold"), table), False)
        self.assertEqual(self.stub.authorized(), 0, "the catalog-level deny is decisive")

    def test_a_question_without_a_resource_falls_through(self):
        """`ExecuteQuery` and `ReadSystemInformation` carry no `resource` at all.

        The front rule must answer them as the chart does (`true`). A local rule
        that receives `input.action.resource` by reference is *undefined* when the
        field is missing, which would also poison the `not` in the fallback and
        deny every query — the live replay caught exactly that.
        """
        for operation in ("ExecuteQuery", "ReadSystemInformation"):
            with self.subTest(operation=operation):
                body = {
                    "context": {"identity": {"user": "sub-finops", "groups": []},
                                "softwareStack": {"trinoVersion": "480"}, "properties": {}},
                    "action": {"operation": operation},
                }
                front, upstream = self.both(body, access_table())
                self.assertIs(front, True)
                self.assertIs(upstream, True, "the chart answers these without Lakekeeper")

    def test_an_unmanaged_catalog_costs_nothing(self):
        self.assertIs(self.front(catalog_body("sub-finops", "system"), access_table()), True)
        self.assertEqual(self.stub.authorized(), 0)

    def test_filter_catalogs_answers_from_the_table(self):
        body = filter_catalogs_body("sub-finops", ["gold", "silver", "system", "tpch"])
        self.assertEqual(self.front(body, access_table(), batched=True), [0, 2, 3])
        self.assertEqual(self.stub.authorized(), 0)

    def test_filter_columns_answers_column_positions(self):
        body = filter_columns_body("sub-ana", "gold", "retail_demo", "taxi_daily_metrics",
                                   ["a", "b", "c"])
        self.assertEqual(self.front(body, access_table(), batched=True), [0, 1, 2])
        self.assertEqual(self.stub.authorized(), 0)

    def test_a_stale_table_makes_filter_catalogs_ask(self):
        body = filter_catalogs_body("sub-finops", ["gold", "silver", "system"])
        self.assertEqual(self.front(body, access_table(now=0), batched=True), [0, 2])
        self.assertGreater(self.stub.authorized(), 0)

    # -- the differential --------------------------------------------------

    def test_the_front_entry_points_equal_the_charts_rules(self):
        """For every question and every state of the table: same answer as `trino.*`.

        This is the correctness rule of the ticket: the table may only accelerate,
        never change. A difference is printed with the body that produced it.
        """
        # Every state a healthy sync can leave behind. `all` is never empty while
        # the admin group has a member (the sync fails the tick otherwise), and a
        # person the sync has not written into the admin role yet is a Catalog
        # with `drift` — not a silent local denial — so there is no state that
        # lists a catalog but omits its administrators.
        states = {
            "fresh": access_table(),
            "stale": access_table(now=0),
            "missing": None,
            "drift": access_table(drift=("gold", "silver", "warehouse")),
            # A Catalog that became Ready since the last tick: the table is fresh
            # but does not list it yet, which must fall through per catalog.
            "new-catalog": access_table(omit=("silver",)),
        }
        questions = [
            ("AccessCatalog gold", lambda user: (catalog_body(user, "gold"), False)),
            ("AccessCatalog silver", lambda user: (catalog_body(user, "silver"), False)),
            ("AccessCatalog system", lambda user: (catalog_body(user, "system"), False)),
            ("SelectFromColumns gold", lambda user: (
                table_body(user, "SelectFromColumns", "gold", "retail_demo",
                           "taxi_daily_metrics"), False)),
            ("InsertIntoTable silver", lambda user: (
                table_body(user, "InsertIntoTable", "silver", "retail_demo",
                           "yellow_taxi_clean"), False)),
            ("CreateSchema gold", lambda user: (schema_body(user, "gold"), False)),
            ("FilterCatalogs", lambda user: (
                filter_catalogs_body(user, ["gold", "silver", "warehouse", "system", "tpch"]),
                True)),
        ]
        users = sorted(ADMITTED) + ["sub-nobody"]
        differences = []
        for state, table in states.items():
            for user in users:
                for label, build in questions:
                    body, batched = build(user)
                    front, upstream = self.both(body, table, batched=batched)
                    if front != upstream:
                        differences.append(
                            "%-9s %-15s %-24s front=%s upstream=%s"
                            % (state, user, label, json.dumps(front), json.dumps(upstream))
                        )
        if differences:
            self.fail(
                "the table changed an answer (%d difference(s)):\n  %s"
                % (len(differences), "\n  ".join(differences))
            )


if __name__ == "__main__":
    unittest.main()
