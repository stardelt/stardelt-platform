"""Unit tests for scripts/access-sync-job.py (platform#305).

Standard library only, like the job: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. The Lakekeeper half runs against a real HTTP server on a thread
(`http.server`), so `ensure_warehouse` is exercised over the wire — URL, bearer header,
create body, 409 handling — without a cluster. The Kubernetes half is stubbed at
`k8s_request`, the one seam the job has there (the real thing needs the Pod's
ServiceAccount token and CA file).
"""
import importlib.util
import json
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


class FakeLakekeeper:
    """The management endpoints the job uses, on a thread.

    `GET /management/v1/warehouse` answers the shape the live 0.12.2 answers (both
    `id` and `warehouse-id`, equal); `POST` creates and answers `{"warehouse-id"}`.
    `conflict_on` makes the next POST for that name answer 409 *after* recording the
    warehouse — the lost race the job must treat as `exists`.
    """

    def __init__(self):
        self.warehouses = {}
        self.requests = []
        self.conflict_on = None
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

            def do_GET(self):
                state.requests.append(("GET", self.path, None))
                if self.path != "/management/v1/warehouse":
                    self._reply(404)
                    return
                self._reply(
                    200,
                    {
                        "warehouses": [
                            {"id": wid, "warehouse-id": wid, "name": name}
                            for name, wid in state.warehouses.items()
                        ]
                    },
                )

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                state.requests.append(("POST", self.path, body))
                if self.path != "/management/v1/warehouse":
                    self._reply(404)
                    return
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

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class JobTestCase(unittest.TestCase):
    """Points the job at the fake Lakekeeper and restores every global afterwards."""

    def setUp(self):
        self.fake = FakeLakekeeper()
        self.addCleanup(self.fake.stop)
        self._saved = (
            access_sync.LAKEKEEPER_URL,
            access_sync.lakekeeper_token,
            access_sync.PLATFORM_BUCKET,
        )
        access_sync.LAKEKEEPER_URL = self.fake.url
        access_sync.lakekeeper_token = lambda: "test-token"
        access_sync.PLATFORM_BUCKET = S3["bucket"]
        self.addCleanup(self._restore)

    def _restore(self):
        (
            access_sync.LAKEKEEPER_URL,
            access_sync.lakekeeper_token,
            access_sync.PLATFORM_BUCKET,
        ) = self._saved


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


if __name__ == "__main__":
    unittest.main()
