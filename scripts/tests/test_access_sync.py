"""Unit tests for scripts/access-sync-job.py (platform#305, platform#306).

Standard library only, like the job: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. Both halves that speak HTTP run against real servers on threads
(`http.server`): a fake Lakekeeper (warehouses, roles, role assignees, warehouse
grants, project assignments) and a fake Keycloak (group by path, paged members), so
every request is exercised over the wire — URL, bearer header, body shape, status
codes — without a cluster. The Kubernetes half is stubbed at `k8s_request` with an
in-memory Catalog, the one seam the job has there (the real thing needs the Pod's
ServiceAccount token and CA file).
"""
import base64
import contextlib
import importlib.util
import io
import json
import logging
import re
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

JOB = Path(__file__).resolve().parents[1] / "access-sync-job.py"
_spec = importlib.util.spec_from_file_location("access_sync_job", JOB)
access_sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(access_sync)

S3 = {
    "endpoint": "http://seaweedfs-s3.stardelt.svc.cluster.local:8333",
    "bucket": "lakehouse",
    "region": "us-east-1",
    "access-key": "test-access-key",
    "secret-key": "test-secret-key",
}

# The fixture token's `sub`: the identity behind `oidc~<sub>` that Lakekeeper records
# as the creator's `ownership` on a warehouse. The canary test asserts it never
# reaches a log line.
TOKEN_SUB = "fixture-sub-9d41"


def _jwt_part(payload):
    """One base64url JWT segment, unpadded, the way a token carries it."""
    raw = json.dumps(payload).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


# Unsigned fixture JWT: the job reads the payload and never checks the signature.
TEST_TOKEN = "%s.%s.%s" % (
    _jwt_part({"alg": "none", "typ": "JWT"}),
    _jwt_part({"sub": TOKEN_SUB, "iss": "http://keycloak/realms/stardelt"}),
    "not-a-signature",
)


class FakeLakekeeper:
    """The management endpoints the job uses, on a thread.

    `GET /management/v1/warehouse` answers the shape the live 0.12.2 answers (both
    `id` and `warehouse-id`, equal); `POST` creates and answers `{"warehouse-id"}`.
    `conflict_on` makes the next POST for that name answer 409 *after* recording the
    warehouse — the lost race the job must treat as `exists`.

    Roles page with `pageSize`/`pageToken` like the live 0.12.2 (the snake_case
    spellings are ignored there, so the fake ignores them too and a wrong spelling
    would loop); a new role gets the creator's `ownership` entry, which the job must
    never touch.
    """

    def __init__(self):
        self.warehouses = {}
        self.requests = []
        self.conflict_on = None
        self.roles = {}
        self.role_assignments = {}
        self.warehouse_assignments = {}
        self.project_assignments = []
        state = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):  # keep the test output readable
                pass

            def _reply(self, code, payload=None):
                raw = json.dumps(payload if payload is not None else {}).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _body(self):
                length = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(length) or b"{}")

            def do_GET(self):
                state.requests.append(("GET", self.path, None))
                path, _, query = self.path.partition("?")
                if path == "/management/v1/warehouse":
                    self._reply(
                        200,
                        {
                            "warehouses": [
                                {"id": wid, "warehouse-id": wid, "name": name}
                                for name, wid in state.warehouses.items()
                            ]
                        },
                    )
                    return
                if path == "/management/v1/role":
                    params = dict(
                        item.split("=", 1) for item in query.split("&") if "=" in item
                    )
                    size = int(params.get("pageSize") or 10)
                    offset = int(params.get("pageToken") or 0)
                    roles = list(state.roles.values())
                    page = roles[offset : offset + size]
                    following = offset + len(page)
                    self._reply(
                        200,
                        {
                            "roles": page,
                            "next-page-token": (
                                str(following) if following < len(roles) else None
                            ),
                        },
                    )
                    return
                role = re.fullmatch(r"/management/v1/permissions/role/([^/]+)/assignments", path)
                if role:
                    self._reply(
                        200, {"assignments": state.role_assignments.get(role.group(1), [])}
                    )
                    return
                warehouse = re.fullmatch(
                    r"/management/v1/permissions/warehouse/([^/]+)/assignments", path
                )
                if warehouse:
                    self._reply(
                        200,
                        {
                            "assignments": state.warehouse_assignments.get(
                                warehouse.group(1), []
                            )
                        },
                    )
                    return
                if path == "/management/v1/permissions/project/assignments":
                    self._reply(200, {"assignments": state.project_assignments})
                    return
                self._reply(404)

            def do_POST(self):
                body = self._body()
                state.requests.append(("POST", self.path, body))
                path = self.path.partition("?")[0]
                if path == "/management/v1/warehouse":
                    name = body.get("warehouse-name")
                    if name == state.conflict_on:
                        state.conflict_on = None
                        state.warehouses[name] = "warehouse-raced"
                        self._reply(409, {"type": "conflict"})
                        return
                    if name in state.warehouses:
                        self._reply(409, {"type": "conflict"})
                        return
                    state.warehouses[name] = "warehouse-" + str(len(state.warehouses) + 1)
                    self._reply(201, {"warehouse-id": state.warehouses[name]})
                    return
                if path == "/management/v1/role":
                    name = body.get("name")
                    role_id = state.create_role(name, body.get("description"))
                    self._reply(201, {"id": role_id})
                    return
                role = re.fullmatch(r"/management/v1/permissions/role/([^/]+)/assignments", path)
                if role:
                    state.apply(state.role_assignments.setdefault(role.group(1), []), body)
                    self._reply(204)
                    return
                warehouse = re.fullmatch(
                    r"/management/v1/permissions/warehouse/([^/]+)/assignments", path
                )
                if warehouse:
                    state.apply(
                        state.warehouse_assignments.setdefault(warehouse.group(1), []),
                        body,
                    )
                    self._reply(204)
                    return
                if path == "/management/v1/permissions/project/assignments":
                    state.apply(state.project_assignments, body)
                    self._reply(204)
                    return
                self._reply(404)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @staticmethod
    def apply(current, body):
        """Apply a `{"writes": [...], "deletes": [...]}` body to an assignment list."""
        for entry in body.get("writes") or []:
            if entry not in current:
                current.append(entry)
        for entry in body.get("deletes") or []:
            if entry in current:
                current.remove(entry)

    def create_role(self, name, description=None):
        role_id = "role-" + (name or "").replace(" ", "-")
        self.roles[name] = {
            "id": role_id,
            "name": name,
            "description": "stardelt group " + name if description is None else description,
        }
        self.role_assignments[role_id] = [{"type": "ownership", "user": "oidc~operator"}]
        return role_id

    def add_warehouse(self, name):
        self.warehouses[name] = "warehouse-" + str(len(self.warehouses) + 1)
        return self.warehouses[name]

    def assignees(self, role_id):
        return {
            entry["user"]
            for entry in self.role_assignments.get(role_id, [])
            if entry.get("type") == "assignee"
        }

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class FakeKeycloak:
    """Group reads of the Keycloak admin API, on a thread.

    `groups` is `{name: [(sub, username)]}`; 404 for an unknown group and a page slice
    for `first`/`max` reproduce the two calls `keycloak_token()`-authenticated code
    makes. `forbidden` makes every read answer 403 — the case that must fail the tick
    before it writes anything.
    """

    def __init__(self, groups):
        self.groups = {
            name: {"id": "group-" + name, "members": members}
            for name, members in groups.items()
        }
        self.forbidden = False
        self.requests = []
        state = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _reply(self, code, payload=None):
                raw = json.dumps(payload if payload is not None else {}).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                state.requests.append(self.path)
                if state.forbidden:
                    self._reply(403, {"error": "forbidden"})
                    return
                path, _, query = self.path.partition("?")
                group_by_path = re.fullmatch(r"/admin/realms/stardelt/group-by-path/(.+)", path)
                if group_by_path:
                    group = state.groups.get(group_by_path.group(1))
                    if not group:
                        self._reply(404, {"error": "Group not found"})
                        return
                    self._reply(200, {"id": group["id"], "name": group_by_path.group(1)})
                    return
                members = re.fullmatch(r"/admin/realms/stardelt/groups/([^/]+)/members", path)
                if members:
                    params = dict(
                        item.split("=", 1) for item in query.split("&") if "=" in item
                    )
                    group = next(
                        (
                            entry
                            for entry in state.groups.values()
                            if entry["id"] == members.group(1)
                        ),
                        None,
                    )
                    if not group:
                        self._reply(404, {"error": "Group not found"})
                        return
                    first = int(params.get("first") or 0)
                    size = int(params.get("max") or 100)
                    self._reply(
                        200,
                        [
                            {"id": sub, "username": username, "enabled": True}
                            for sub, username in group["members"][first : first + size]
                        ],
                    )
                    return
                self._reply(404)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class FakeKubernetes:
    """One in-memory Catalog: GET returns it, PATCH /status merges into it."""

    def __init__(self, catalog):
        self.catalog = catalog
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            return 200, self.catalog
        if method == "PATCH" and path.endswith("/status"):
            self.catalog.setdefault("status", {}).update(body["status"])
            return 200, self.catalog
        return 404, None

    def patches(self):
        return [call for call in self.calls if call[0] == "PATCH"]

    def condition(self, condition_type):
        for condition in (self.catalog.get("status") or {}).get("conditions") or []:
            if condition.get("type") == condition_type:
                return condition
        return None


class JobTestCase(unittest.TestCase):
    """Points the job at the fakes and restores every global afterwards."""

    def setUp(self):
        self.fake = FakeLakekeeper()
        self.addCleanup(self.fake.stop)
        self._saved = (
            access_sync.LAKEKEEPER_URL,
            access_sync.KEYCLOAK_URL,
            access_sync.lakekeeper_token,
            access_sync.keycloak_token,
            access_sync.PLATFORM_BUCKET,
            access_sync.STATIC_ASSIGNEES,
            access_sync.s3_credentials,
            access_sync.list_catalogs,
            access_sync.k8s_request,
            access_sync.ROLE_PAGE,
        )
        access_sync.LAKEKEEPER_URL = self.fake.url
        access_sync.lakekeeper_token = lambda: TEST_TOKEN
        access_sync.PLATFORM_BUCKET = S3["bucket"]
        access_sync.STATIC_ASSIGNEES = "{}"
        access_sync.s3_credentials = lambda: dict(S3)
        self.addCleanup(self._restore)

    def _restore(self):
        (
            access_sync.LAKEKEEPER_URL,
            access_sync.KEYCLOAK_URL,
            access_sync.lakekeeper_token,
            access_sync.keycloak_token,
            access_sync.PLATFORM_BUCKET,
            access_sync.STATIC_ASSIGNEES,
            access_sync.s3_credentials,
            access_sync.list_catalogs,
            access_sync.k8s_request,
            access_sync.ROLE_PAGE,
        ) = self._saved

    def use_keycloak(self, groups):
        fake = FakeKeycloak(groups)
        self.addCleanup(fake.stop)
        access_sync.KEYCLOAK_URL = fake.url
        access_sync.keycloak_token = lambda: "keycloak-token"
        return fake

    def use_catalogs(self, *catalogs):
        """Wire main() to in-memory Catalogs and return the fake Kubernetes API."""
        catalogs = list(catalogs)
        kubernetes = FakeKubernetes(catalogs[0])
        access_sync.k8s_request = kubernetes.request
        access_sync.list_catalogs = lambda: catalogs
        return kubernetes

    def posts(self):
        return [request for request in self.fake.requests if request[0] == "POST"]


class CatalogProblemTest(JobTestCase):
    def test_accepts_a_valid_catalog(self):
        self.assertIsNone(access_sync.catalog_problem("finance", {}))
        self.assertIsNone(
            access_sync.catalog_problem("finance", {"storage": {"bucket": S3["bucket"]}})
        )
        self.assertIsNone(
            access_sync.catalog_problem("finance", {"storage": {"keyPrefix": "domains/finance"}})
        )
        self.assertIsNone(access_sync.catalog_problem("a" * 40, {}))

    def test_refuses_a_name_that_is_not_a_sql_identifier(self):
        for name in ("System", "9x", "a" * 41, "fin-ance", ""):
            with self.subTest(name=name):
                problem = access_sync.catalog_problem(name, {})
                self.assertIsNotNone(problem, "expected %r to be refused" % name)
                reason, message = problem
                self.assertEqual(reason, "InvalidName")
                self.assertIn("40 lower-case letters and digits", message)

    def test_refuses_a_reserved_name(self):
        for name in ("tpch", "system", "memory", "tpcds", "jmx"):
            with self.subTest(name=name):
                reason, message = access_sync.catalog_problem(name, {})
                self.assertEqual(reason, "ReservedName")
                self.assertIn("reserved", message)

    def test_reserved_underscore_name_never_reaches_the_reserved_check(self):
        """`information_schema` is reserved *and* not a SQL-identifier name: the name
        rule wins, exactly as in the operator's `CatalogDomainSpec::validate`."""
        reason, _ = access_sync.catalog_problem("information_schema", {})
        self.assertEqual(reason, "InvalidName")

    def test_refuses_a_foreign_bucket(self):
        reason, message = access_sync.catalog_problem("finance", {"storage": {"bucket": "finance"}})
        self.assertEqual(reason, "BucketsNotBuilt")
        self.assertIn("per-catalog buckets", message)
        self.assertIn("finance", message)


class WarehouseBodyTest(JobTestCase):
    def test_carries_the_prefix_and_the_platform_storage(self):
        body = access_sync.warehouse_body("finance", {}, dict(S3))
        self.assertEqual(body["warehouse-name"], "finance")
        self.assertEqual(body["project-id"], "00000000-0000-0000-0000-000000000000")
        profile = body["storage-profile"]
        self.assertEqual(profile["bucket"], S3["bucket"])
        self.assertEqual(profile["key-prefix"], "finance")
        self.assertEqual(profile["endpoint"], S3["endpoint"])
        self.assertEqual(profile["region"], S3["region"])
        self.assertTrue(profile["path-style-access"])
        self.assertEqual(profile["flavor"], "minio")
        self.assertFalse(profile["sts-enabled"])
        self.assertFalse(profile["remote-signing-enabled"])

    def test_uses_the_declared_key_prefix(self):
        body = access_sync.warehouse_body(
            "finance", {"storage": {"keyPrefix": "domains/finance"}}, dict(S3)
        )
        self.assertEqual(body["storage-profile"]["key-prefix"], "domains/finance")

    def test_takes_the_credential_only_from_its_argument(self):
        """No module global, environment or Secret read: the argument is the only source."""
        body = access_sync.warehouse_body("finance", {}, dict(S3))
        self.assertEqual(
            body["storage-credential"],
            {
                "type": "s3",
                "credential-type": "access-key",
                "aws-access-key-id": S3["access-key"],
                "aws-secret-access-key": S3["secret-key"],
            },
        )
        other = dict(S3, **{"access-key": "other-key", "secret-key": "other-secret"})
        body = access_sync.warehouse_body("finance", {}, other)
        self.assertEqual(body["storage-credential"]["aws-access-key-id"], "other-key")
        self.assertEqual(body["storage-credential"]["aws-secret-access-key"], "other-secret")


class EnsureWarehouseTest(JobTestCase):
    def test_creates_once_then_reports_exists(self):
        warehouse_id, action = access_sync.ensure_warehouse("sandbox", {}, dict(S3))
        self.assertEqual(action, "created")
        self.assertTrue(warehouse_id)
        again, action = access_sync.ensure_warehouse("sandbox", {}, dict(S3))
        self.assertEqual((again, action), (warehouse_id, "exists"))
        creates = [r for r in self.fake.requests if r[0] == "POST"]
        self.assertEqual(len(creates), 1, "the second call must not create again")
        self.assertEqual(creates[0][2]["warehouse-name"], "sandbox")
        self.assertEqual(creates[0][2]["storage-profile"]["bucket"], S3["bucket"])

    def test_a_409_counts_as_exists(self):
        self.fake.conflict_on = "raced"
        warehouse_id, action = access_sync.ensure_warehouse("raced", {}, dict(S3))
        self.assertEqual(action, "exists")
        self.assertEqual(warehouse_id, "warehouse-raced")
        self.assertEqual(len([r for r in self.fake.requests if r[0] == "POST"]), 1)


class PatchStatusTest(JobTestCase):
    LIVE = {
        "metadata": {"generation": 3},
        "status": {
            "phase": "Ready",
            "warehouseId": "warehouse-1",
            "observedGeneration": 3,
            "conditions": [
                {
                    "type": "CatalogReady",
                    "status": "True",
                    "reason": "Ready",
                    "message": "Lakekeeper warehouse warehouse-1",
                    "observedGeneration": 3,
                    "lastTransitionTime": "2026-10-21T00:00:00+00:00",
                }
            ],
        },
    }

    def _stub_k8s(self, live):
        calls = []

        def request(method, path, body=None):
            calls.append((method, path, body))
            if method == "GET":
                return 200, live
            return 200, {}

        self._saved_k8s = access_sync.k8s_request
        access_sync.k8s_request = request
        self.addCleanup(setattr, access_sync, "k8s_request", self._saved_k8s)
        return calls

    def test_writes_nothing_when_the_status_matches(self):
        calls = self._stub_k8s(json.loads(json.dumps(self.LIVE)))
        changed = access_sync.patch_status(
            "finance", "Ready", "warehouse-1", "Ready", "Lakekeeper warehouse warehouse-1"
        )
        self.assertFalse(changed, "an unchanged status must not be written")
        self.assertEqual([call[0] for call in calls], ["GET"], "no PATCH may be sent")

    def test_writes_when_the_phase_changed(self):
        live = json.loads(json.dumps(self.LIVE))
        live["status"].update({"phase": "Invalid", "warehouseId": None})
        calls = self._stub_k8s(live)
        changed = access_sync.patch_status("finance", "Ready", "warehouse-1", "Ready", "Lakekeeper warehouse warehouse-1")
        self.assertTrue(changed)
        patches = [call for call in calls if call[0] == "PATCH"]
        self.assertEqual(len(patches), 1)
        self.assertTrue(patches[0][1].endswith("/apis/stardelt.io/v1alpha1/namespaces/stardelt/catalogs/finance/status"))
        self.assertEqual(patches[0][2]["status"]["phase"], "Ready")
        self.assertEqual(patches[0][2]["status"]["warehouseId"], "warehouse-1")

    def test_clears_a_stale_warehouse_id_when_invalid(self):
        live = json.loads(json.dumps(self.LIVE))
        live["status"].update({"phase": "Ready", "warehouseId": "warehouse-1"})
        calls = self._stub_k8s(live)
        changed = access_sync.patch_status("finance", "Invalid", None, "ReservedName", "catalog name `finance` is reserved")
        self.assertTrue(changed)
        patch = [call for call in calls if call[0] == "PATCH"][0]
        self.assertIsNone(patch[2]["status"]["warehouseId"])
        condition = patch[2]["status"]["conditions"][0]
        self.assertEqual((condition["status"], condition["reason"]), ("False", "ReservedName"))

    def test_writes_grants_ready_and_drift_and_leaves_foreign_conditions(self):
        live = json.loads(json.dumps(self.LIVE))
        live["status"]["conditions"].append(
            {"type": "SomeoneElse", "status": "True", "reason": "Kept"}
        )
        calls = self._stub_k8s(live)
        changed = access_sync.patch_status(
            "finance",
            "Ready",
            "warehouse-1",
            "Ready",
            "Lakekeeper warehouse warehouse-1",
            grants=(True, "Ready", "1 declared grant(s) on the warehouse", 2),
        )
        self.assertTrue(changed)
        conditions = [c for c in calls if c[0] == "PATCH"][0][2]["status"]["conditions"]
        self.assertEqual(
            [condition["type"] for condition in conditions],
            ["CatalogReady", "GrantsReady", "Drift", "SomeoneElse"],
        )
        self.assertEqual((conditions[1]["status"], conditions[1]["reason"]), ("True", "Ready"))
        self.assertEqual(
            (conditions[2]["status"], conditions[2]["reason"], conditions[2]["message"]),
            ("True", "ForeignGrants", "2 grant(s) on this warehouse belong to subjects the sync does not manage"),
        )

    def test_a_converged_grants_status_is_not_rewritten(self):
        live = json.loads(json.dumps(self.LIVE))
        calls = self._stub_k8s(live)
        access_sync.patch_status(
            "finance",
            "Ready",
            "warehouse-1",
            "Ready",
            "Lakekeeper warehouse warehouse-1",
            grants=(False, "UnknownGroup", "the realm has no group `ghost`", 0),
        )
        patches = [call for call in calls if call[0] == "PATCH"]
        self.assertEqual(len(patches), 1)
        converged = patches[0][2]["status"]["conditions"]
        live["status"]["conditions"] = converged
        calls.clear()
        changed = access_sync.patch_status(
            "finance",
            "Ready",
            "warehouse-1",
            "Ready",
            "Lakekeeper warehouse warehouse-1",
            grants=(False, "UnknownGroup", "the realm has no group `ghost`", 0),
        )
        self.assertFalse(changed)
        self.assertEqual([call[0] for call in calls], ["GET"])


class DesiredRelationsTest(JobTestCase):
    def test_maps_the_five_verbs_to_lakekeeper_relations(self):
        spec = {
            "owner": "stardelt-admins",
            "grants": [
                {"group": "finance", "verb": "browse"},
                {"group": "analytics", "verb": "select"},
                {"group": "etl", "verb": "write"},
                {"group": "builders", "verb": "create"},
                {"group": "stewards", "verb": "manage"},
            ],
        }
        self.assertEqual(
            access_sync.desired_relations(spec),
            {
                ("manage_grants", "stardelt-admins"),
                ("describe", "finance"),
                ("select", "analytics"),
                ("modify", "etl"),
                ("create", "builders"),
                ("manage_grants", "stewards"),
            },
        )

    def test_the_owner_gets_manage_grants_and_nothing_else(self):
        """Ownership must not imply select (design §5.3, decision 2026-10-20)."""
        self.assertEqual(
            access_sync.desired_relations({"owner": "finops"}), {("manage_grants", "finops")}
        )
        self.assertNotIn(
            ("ownership", "finops"), access_sync.desired_relations({"owner": "finops"})
        )

    def test_an_unknown_verb_is_ignored_not_crashed(self):
        self.assertEqual(
            access_sync.desired_relations({"grants": [{"group": "x", "verb": "frobnicate"}]}),
            set(),
        )


class ManagedGroupsTest(JobTestCase):
    def test_owners_grant_groups_and_the_admin_group(self):
        catalogs = [
            {"spec": {"owner": "stardelt-admins", "grants": [{"group": "analytics", "verb": "select"}]}},
            {"spec": {"owner": "finops", "grants": []}},
            {"spec": {}},
        ]
        self.assertEqual(
            access_sync.managed_groups(catalogs),
            {"stardelt-admins", "finops", "analytics"},
        )


class GroupMembersTest(JobTestCase):
    def test_reads_every_member_by_subject(self):
        keycloak = self.use_keycloak({"finance": [("sub-1", "alice"), ("sub-2", "bob")]})
        self.assertEqual(access_sync.group_members("finance"), {"sub-1", "sub-2"})
        self.assertEqual(len(keycloak.requests), 2, "group-by-path then one members page")

    def test_pages_until_a_short_page(self):
        """101 members: page one is full, page two is short — both are read."""
        members = [("sub-%03d" % index, "user%d" % index) for index in range(101)]
        keycloak = self.use_keycloak({"finance": members})
        self.assertEqual(access_sync.group_members("finance"), {sub for sub, _ in members})
        self.assertEqual(len(keycloak.requests), 3)

    def test_a_group_that_is_not_in_the_realm_raises(self):
        self.use_keycloak({"finance": []})
        with self.assertRaises(access_sync.GroupUnknown):
            access_sync.group_members("ghost")

    def test_a_403_fails_the_run(self):
        keycloak = self.use_keycloak({"finance": []})
        keycloak.forbidden = True
        with self.assertRaises(SystemExit) as raised:
            access_sync.group_members("finance")
        self.assertEqual(raised.exception.code, 1)


class EnsureRoleTest(JobTestCase):
    def test_creates_once_with_the_stardelt_description(self):
        role_id = access_sync.ensure_role("finance")
        self.assertEqual(role_id, "role-finance")
        again = access_sync.ensure_role("finance")
        self.assertEqual(again, role_id)
        creates = [
            body for _, path, body in self.posts() if path == "/management/v1/role"
        ]
        self.assertEqual(len(creates), 1)
        self.assertEqual(creates[0]["name"], "finance")
        self.assertEqual(creates[0]["description"], "stardelt group finance")

    def test_a_foreign_role_with_the_same_name_is_never_edited(self):
        role_id = self.fake.create_role("finance", description="owned by somebody else")
        with self.assertRaises(access_sync.RoleConflict):
            access_sync.ensure_role("finance")
        self.assertEqual(self.fake.roles["finance"]["description"], "owned by somebody else")
        self.assertEqual(self.posts(), [])

    def test_pages_through_the_role_listing(self):
        access_sync.ROLE_PAGE = 1
        for name in ("zz-a", "zz-b", "stardelt-users"):
            self.fake.create_role(name)
        self.assertEqual(
            sorted(role["name"] for role in access_sync.list_roles()),
            ["stardelt-users", "zz-a", "zz-b"],
        )


class SyncAssigneesTest(JobTestCase):
    def test_writes_the_added_member_and_removes_the_former_one(self):
        role_id = self.fake.create_role("finance")
        self.assertEqual(access_sync.sync_assignees(role_id, {"sub-1"}), (1, 0))
        self.assertEqual(self.fake.assignees(role_id), {"oidc~sub-1"})
        self.assertEqual(access_sync.sync_assignees(role_id, {"sub-2"}), (1, 1))
        self.assertEqual(self.fake.assignees(role_id), {"oidc~sub-2"})

    def test_a_converged_role_writes_nothing(self):
        role_id = self.fake.create_role("finance")
        access_sync.sync_assignees(role_id, {"sub-1", "sub-2"})
        posts = len(self.posts())
        self.assertEqual(access_sync.sync_assignees(role_id, {"sub-2", "sub-1"}), (0, 0))
        self.assertEqual(len(self.posts()), posts, "a converged role must not POST")

    def test_ownership_is_never_touched(self):
        role_id = self.fake.create_role("finance")
        access_sync.sync_assignees(role_id, {"sub-1"})
        access_sync.sync_assignees(role_id, set())
        self.assertIn(
            {"type": "ownership", "user": "oidc~operator"}, self.fake.role_assignments[role_id]
        )


class SyncWarehouseGrantsTest(JobTestCase):
    def setUp(self):
        super().setUp()
        self.warehouse_id = self.fake.add_warehouse("warehouse")

    def test_grants_a_declared_relation_by_role(self):
        role_id = self.fake.create_role("finance")
        written, removed, drift = access_sync.sync_warehouse_grants(
            self.warehouse_id, {("select", "finance")}, {"finance": role_id}
        )
        self.assertEqual((written, removed, drift), (1, 0, 0))
        self.assertEqual(
            self.fake.warehouse_assignments[self.warehouse_id],
            [{"type": "select", "role": role_id}],
        )

    def test_removes_an_undeclared_managed_grant_and_counts_the_foreign_one(self):
        managed = self.fake.create_role("finance")
        foreign = self.fake.create_role("someone-else", description="not ours")
        self.fake.warehouse_assignments[self.warehouse_id] = [
            {"type": "describe", "role": managed},
            {"type": "select", "role": managed},
            {"type": "select", "role": foreign},
            {"type": "data_admin", "user": "oidc~trino"},
            {"type": "ownership", "user": "oidc~bootstrap"},
        ]
        written, removed, drift = access_sync.sync_warehouse_grants(
            self.warehouse_id,
            {("describe", "finance")},
            {"finance": managed},
            {managed},
        )
        self.assertEqual((written, removed, drift), (0, 1, 3))
        self.assertEqual(
            self.fake.warehouse_assignments[self.warehouse_id],
            [
                {"type": "describe", "role": managed},
                {"type": "select", "role": foreign},
                {"type": "data_admin", "user": "oidc~trino"},
                {"type": "ownership", "user": "oidc~bootstrap"},
            ],
        )

    def test_a_converged_warehouse_writes_nothing(self):
        role_id = self.fake.create_role("finance")
        access_sync.sync_warehouse_grants(
            self.warehouse_id, {("select", "finance"), ("describe", "finance")}, {"finance": role_id}
        )
        posts = len(self.posts())
        self.assertEqual(
            access_sync.sync_warehouse_grants(
                self.warehouse_id,
                {("describe", "finance"), ("select", "finance")},
                {"finance": role_id},
            ),
            (0, 0, 0),
        )
        self.assertEqual(len(self.posts()), posts)

    def test_apply_false_reads_and_counts_without_writing(self):
        role_id = self.fake.create_role("finance")
        self.fake.warehouse_assignments[self.warehouse_id] = [
            {"type": "select", "role": "role-someone-else"}
        ]
        self.assertEqual(
            access_sync.sync_warehouse_grants(
                self.warehouse_id, {("select", "finance")}, {"finance": role_id}, apply=False
            ),
            (0, 0, 1),
        )
        self.assertEqual(
            self.fake.warehouse_assignments[self.warehouse_id],
            [{"type": "select", "role": "role-someone-else"}],
        )

    def test_own_ownership_is_not_foreign(self):
        """The creator tuple Lakekeeper writes for this client is the sync's own record.

        It is the one assignment every created warehouse has (and the adopted
        `warehouse`, created before authorization existed, does not), so counting it
        made every created Catalog `Drift=True/ForeignGrants`. It is not drift, it is
        never deleted, and a second tick is still a no-op.
        """
        role_id = self.fake.create_role("finance")
        own = {"type": "ownership", "user": "oidc~" + TOKEN_SUB}
        self.fake.warehouse_assignments[self.warehouse_id] = [
            own,
            {"type": "select", "role": role_id},
        ]
        posts = len(self.posts())
        self.assertEqual(
            access_sync.sync_warehouse_grants(
                self.warehouse_id, {("select", "finance")}, {"finance": role_id}
            ),
            (0, 0, 0),
        )
        self.assertEqual(len(self.posts()), posts, "the own ownership must not be deleted")
        self.assertIn(own, self.fake.warehouse_assignments[self.warehouse_id])
        self.assertEqual(
            access_sync.sync_warehouse_grants(
                self.warehouse_id, {("select", "finance")}, {"finance": role_id}
            ),
            (0, 0, 0),
        )
        self.assertEqual(len(self.posts()), posts, "a converged tick must not POST")

    def test_another_users_ownership_is_foreign(self):
        """Only *this* client's ownership is ours; anybody else's is drift."""
        role_id = self.fake.create_role("finance")
        self.fake.warehouse_assignments[self.warehouse_id] = [
            {"type": "ownership", "user": "oidc~somebody-else"},
            {"type": "select", "role": role_id},
        ]
        self.assertEqual(
            access_sync.sync_warehouse_grants(
                self.warehouse_id, {("select", "finance")}, {"finance": role_id}
            ),
            (0, 0, 1),
        )

    def test_foreign_role_grant_is_foreign(self):
        role_id = self.fake.create_role("finance")
        self.fake.warehouse_assignments[self.warehouse_id] = [
            {"type": "describe", "role": "role-zz-foreign"},
        ]
        self.assertEqual(
            access_sync.sync_warehouse_grants(
                self.warehouse_id, {("select", "finance")}, {"finance": role_id}
            ),
            (1, 0, 1),
        )


class OwnUserTest(JobTestCase):
    def test_own_user_id_from_token_payload(self):
        """The `sub` comes from the payload; the signature is never checked."""
        self.assertTrue(TEST_TOKEN.endswith(".not-a-signature"), "fixture is unsigned")
        self.assertEqual(access_sync.own_user_id(), "oidc~" + TOKEN_SUB)

    def test_own_user_id_is_none_without_a_readable_sub(self):
        access_sync.lakekeeper_token = lambda: "opaque-token"
        self.assertIsNone(access_sync.own_user_id())

    def test_own_user_id_never_logged(self):
        """caplog canary: the principal stays out of stdout, stderr and the log."""
        role_id = self.fake.create_role("finance")
        warehouse_id = self.fake.add_warehouse("warehouse")
        records = []

        class Sink(logging.Handler):
            def emit(self, record):
                records.append(record.getMessage())

        sink = Sink()
        root = logging.getLogger()
        previous_level = root.level
        root.addHandler(sink)
        root.setLevel(logging.DEBUG)
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                own = access_sync.own_user_id()
                access_sync.sync_warehouse_grants(
                    warehouse_id, {("select", "finance")}, {"finance": role_id}
                )
        finally:
            root.removeHandler(sink)
            root.setLevel(previous_level)
        self.assertEqual(own, "oidc~" + TOKEN_SUB)
        logged = "\n".join(records + [out.getvalue(), err.getvalue()])
        self.assertNotIn(TOKEN_SUB, logged)
        self.assertNotIn(TEST_TOKEN, logged)


class EnsureAdminGrantTest(JobTestCase):
    def test_writes_project_admin_once(self):
        role_id = self.fake.create_role("stardelt-admins")
        self.assertTrue(access_sync.ensure_admin_grant(role_id))
        self.assertEqual(
            self.fake.project_assignments, [{"type": "project_admin", "role": role_id}]
        )
        posts = len(self.posts())
        self.assertFalse(access_sync.ensure_admin_grant(role_id), "second call must not write")
        self.assertEqual(len(self.posts()), posts)


class StaticAssigneesTest(JobTestCase):
    def test_parses_the_environment(self):
        access_sync.STATIC_ASSIGNEES = '{"stardelt-users": ["superset"]}'
        self.assertEqual(access_sync.static_assignees(), {"stardelt-users": {"superset"}})

    def test_refuses_something_that_is_not_json(self):
        access_sync.STATIC_ASSIGNEES = "superset"
        with self.assertRaises(SystemExit):
            access_sync.static_assignees()


CATALOG = {
    "metadata": {"name": "warehouse", "generation": 1},
    "spec": {
        "lakehouseRef": {"name": "main"},
        "owner": "stardelt-admins",
        "grants": [
            {"group": "stardelt-users", "verb": "browse"},
            {"group": "stardelt-users", "verb": "select"},
        ],
    },
}


class MainTest(JobTestCase):
    """`main()` end to end against both fakes and an in-memory Catalog."""

    def setUp(self):
        super().setUp()
        self.keycloak = self.use_keycloak(
            {
                "stardelt-admins": [("sub-admin", "admin")],
                "stardelt-users": [("sub-1", "alice"), ("sub-2", "bob")],
            }
        )
        self.kubernetes = self.use_catalogs(json.loads(json.dumps(CATALOG)))

    def test_converges_roles_assignees_and_grants(self):
        self.assertEqual(access_sync.main(), 0)
        users_role = self.fake.roles["stardelt-users"]["id"]
        admins_role = self.fake.roles["stardelt-admins"]["id"]
        self.assertEqual(self.fake.assignees(users_role), {"oidc~sub-1", "oidc~sub-2"})
        self.assertEqual(self.fake.assignees(admins_role), {"oidc~sub-admin"})
        self.assertEqual(
            sorted(
                (entry["type"], entry["role"])
                for entry in self.fake.warehouse_assignments[
                    self.fake.warehouses["warehouse"]
                ]
            ),
            sorted([("describe", users_role), ("select", users_role), ("manage_grants", admins_role)]),
        )
        self.assertEqual(
            self.fake.project_assignments, [{"type": "project_admin", "role": admins_role}]
        )
        grants = self.kubernetes.condition("GrantsReady")
        self.assertEqual((grants["status"], grants["reason"]), ("True", "Ready"))
        self.assertEqual(self.kubernetes.condition("Drift")["status"], "False")

    def test_running_twice_writes_nothing_the_second_time(self):
        self.assertEqual(access_sync.main(), 0)
        requests = len(self.fake.requests)
        patches = len(self.kubernetes.patches())
        self.assertEqual(access_sync.main(), 0)
        self.assertEqual(
            [request for request in self.fake.requests[requests:] if request[0] != "GET"],
            [],
            "the second tick must not write to Lakekeeper",
        )
        self.assertEqual(len(self.kubernetes.patches()), patches, "the second tick must not write status")

    def test_static_assignees_yield_oidc_superset(self):
        access_sync.STATIC_ASSIGNEES = '{"stardelt-users": ["superset"]}'
        self.assertEqual(access_sync.main(), 0)
        users_role = self.fake.roles["stardelt-users"]["id"]
        self.assertEqual(
            self.fake.assignees(users_role),
            {"oidc~sub-1", "oidc~sub-2", "oidc~superset"},
        )

    def test_a_keycloak_403_fails_the_run_without_a_partial_write(self):
        self.keycloak.forbidden = True
        with self.assertRaises(SystemExit) as raised:
            access_sync.main()
        self.assertEqual(raised.exception.code, 1)
        self.assertEqual([request for request in self.fake.requests if request[0] != "GET"], [])
        self.assertEqual(self.kubernetes.patches(), [])

    def test_a_group_that_is_not_in_the_realm_is_a_verdict_not_a_failure(self):
        catalog = json.loads(json.dumps(CATALOG))
        catalog["spec"]["grants"].append({"group": "ghost", "verb": "select"})
        self.kubernetes = self.use_catalogs(catalog)
        self.assertEqual(access_sync.main(), 0)
        grants = self.kubernetes.condition("GrantsReady")
        self.assertEqual((grants["status"], grants["reason"]), ("False", "UnknownGroup"))
        self.assertIn("ghost", grants["message"])
        roles = {role["name"] for role in self.fake.roles.values()}
        self.assertNotIn("ghost", roles, "no role is created for a group that does not exist")

    def test_a_foreign_role_with_the_group_name_is_a_conflict(self):
        self.fake.create_role("stardelt-users", description="somebody else's role")
        self.assertEqual(access_sync.main(), 0)
        grants = self.kubernetes.condition("GrantsReady")
        self.assertEqual((grants["status"], grants["reason"]), ("False", "RoleConflict"))
        self.assertEqual(
            self.fake.roles["stardelt-users"]["description"], "somebody else's role"
        )

    def test_a_removed_member_loses_the_role_on_the_next_tick(self):
        self.assertEqual(access_sync.main(), 0)
        users_role = self.fake.roles["stardelt-users"]["id"]
        self.keycloak.groups["stardelt-users"]["members"] = [("sub-2", "bob"), ("sub-3", "carol")]
        self.assertEqual(access_sync.main(), 0)
        self.assertEqual(self.fake.assignees(users_role), {"oidc~sub-2", "oidc~sub-3"})

    def test_an_undeclared_grant_is_removed_on_the_next_tick(self):
        self.assertEqual(access_sync.main(), 0)
        users_role = self.fake.roles["stardelt-users"]["id"]
        self.fake.warehouse_assignments[self.fake.warehouses["warehouse"]].append(
            {"type": "modify", "role": users_role}
        )
        catalog = json.loads(json.dumps(CATALOG))
        self.kubernetes = self.use_catalogs(catalog)
        self.assertEqual(access_sync.main(), 0)
        self.assertNotIn(
            {"type": "modify", "role": users_role},
            self.fake.warehouse_assignments[self.fake.warehouses["warehouse"]],
        )


if __name__ == "__main__":
    unittest.main()
