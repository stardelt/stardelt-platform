"""Unit tests for scripts/demo-reset-job.py (stardelt-platform#897).

Standard library only, no network and no cluster, like the other tests here:
`python3 -m unittest discover -s scripts/tests -v` runs them in CI. `run` is replaced by a
fake that records the SQL, so neither the issuer nor the query engine is reached; the
token exchange and the statement API are proved by the Job itself on a cluster
(`make demo-reset-now`). What can be decided offline is decided here: identifier quoting,
the exact drop order, and the validation that stops a run without its five settings.
"""
import contextlib
import importlib.util
import io
import os
import ssl
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
JOB_PATH = REPO / "scripts" / "demo-reset-job.py"


def load_job():
    spec = importlib.util.spec_from_file_location("demo_reset_job", JOB_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


JOB = load_job()


class Ident(unittest.TestCase):
    def test_double_quote_is_doubled(self):
        self.assertEqual(JOB.ident('a"b'), '"a""b"')

    def test_an_injected_statement_stays_one_identifier(self):
        self.assertEqual(JOB.ident("x; drop table y"), '"x; drop table y"')


class Reset(unittest.TestCase):
    def test_drops_tables_then_views_then_schemas_and_recreates_scratch(self):
        statements = []

        def fake_run(sql):
            statements.append(sql)
            if "select count(*)" in sql:
                return [[0]]
            if ".information_schema.tables" in sql:
                return [['s"1', "t", "BASE TABLE"], ['s"1', "v", "VIEW"]]
            if ".information_schema.schemata" in sql:
                return [["system"], ['s"1']]
            return []

        with mock.patch.object(JOB, "CATALOG", "playground"), mock.patch.object(JOB, "run", fake_run):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                failed = JOB.reset()

        self.assertEqual(failed, 0)
        self.assertEqual(
            output.getvalue().strip(),
            "demo-reset: removed 0 visitor pipeline(s); "
            "dropped 1 tables, 1 views, 1 schemas; scratch ready",
        )
        self.assertEqual(
            statements,
            [
                "select table_schema, table_name, table_type from playground.information_schema.tables"
                " where table_schema not in ('information_schema', 'system')",
                'drop table playground."s""1"."t"',
                'drop view playground."s""1"."v"',
                "select schema_name from playground.information_schema.schemata"
                " where schema_name not in ('information_schema', 'system')",
                'drop schema playground."s""1"',
                "create schema if not exists playground.scratch",
                "select count(*) from playground.information_schema.tables"
                " where table_schema not in ('information_schema', 'system')",
            ],
        )
        # The connector's own schemas are never dropped, even if a query returns them
        # (platform#943: the nightly Job failed on `drop schema playground.system`).
        self.assertNotIn('drop schema playground."system"', statements)
        self.assertNotIn('drop schema playground."information_schema"', statements)

    def test_a_refused_drop_fails_the_run_and_never_prints_scratch_ready(self):
        def fake_run(sql):
            if "select count(*)" in sql:
                return [[1]]
            if ".information_schema.tables" in sql:
                return [["scratch", "my_orders", "BASE TABLE"]]
            if ".information_schema.schemata" in sql:
                return [["scratch"]]
            if sql.startswith("drop table"):
                raise urllib.error.HTTPError("https://trino/", 403, "Access Denied", None, None)
            return []

        with mock.patch.object(JOB, "CATALOG", "playground"), mock.patch.object(JOB, "run", fake_run):
            output = io.StringIO()
            errors = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                failed = JOB.reset()

        self.assertGreaterEqual(failed, 1)
        self.assertNotIn("scratch ready", output.getvalue())
        self.assertIn(
            "drop failed: 403 Access Denied",
            errors.getvalue(),
        )
        self.assertIn(
            "demo-reset: 2 drop(s) failed; 1 object(s) remain in playground; scratch is NOT empty",
            errors.getvalue(),
        )

    def test_objects_left_after_a_silent_noop_fail_the_run(self):
        def fake_run(sql):
            if "select count(*)" in sql:
                return [[2]]
            if ".information_schema.tables" in sql:
                return [["scratch", "my_orders", "BASE TABLE"]]
            return []

        with mock.patch.object(JOB, "CATALOG", "playground"), mock.patch.object(JOB, "run", fake_run):
            output = io.StringIO()
            errors = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                failed = JOB.reset()

        self.assertEqual(failed, 2)
        self.assertNotIn("scratch ready", output.getvalue())
        self.assertIn("2 object(s) remain", errors.getvalue())


class VisitorPipelines(unittest.TestCase):
    """Decision 11: the visitors' pipelines are deleted, and only theirs.

    `k8s_request` is replaced the way `run` is: nothing here reaches an API server.
    """

    def test_the_selector_is_quoted_and_one_delete_goes_per_returned_name(self):
        calls = []
        names = ["plain", 'pipe"with"quotes', "with space/and slash"]

        def fake_request(method, path):
            calls.append((method, path))
            if method == "GET":
                return {"items": [{"metadata": {"name": name}} for name in names]}
            return None

        with mock.patch.object(JOB, "k8s_request", fake_request):
            count = JOB.delete_visitor_pipelines("stardelt")

        self.assertEqual(count, 3)
        self.assertEqual(
            calls[0],
            (
                "GET",
                "/apis/stardelt.io/v1alpha1/namespaces/stardelt/pipelines"
                "?labelSelector=stardelt.io/owner-group%3Dvisitors",
            ),
        )
        self.assertEqual(
            calls[1:],
            [
                (
                    "DELETE",
                    "/apis/stardelt.io/v1alpha1/namespaces/stardelt/pipelines/"
                    + urllib.parse.quote(name),
                )
                for name in names
            ],
        )

    def test_an_empty_listing_deletes_nothing(self):
        calls = []

        def fake_request(method, path):
            calls.append((method, path))
            return {"items": []}

        with mock.patch.object(JOB, "k8s_request", fake_request):
            self.assertEqual(JOB.delete_visitor_pipelines("stardelt"), 0)
        self.assertEqual([method for method, _ in calls], ["GET"])

    def test_the_count_reaches_the_summary(self):
        def fake_run(sql):
            if "select count(*)" in sql:
                return [[0]]
            return []

        with mock.patch.object(JOB, "CATALOG", "playground"), mock.patch.object(JOB, "run", fake_run):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                JOB.reset(2)

        self.assertEqual(
            output.getvalue().strip(),
            "demo-reset: removed 2 visitor pipeline(s); "
            "dropped 0 tables, 0 views, 0 schemas; scratch ready",
        )

    def test_main_deletes_the_pipelines_before_the_drop(self):
        order = []
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        ca = Path(directory.name) / "ca.crt"
        ca.write_text("a path that exists; the job only checks for it here")
        env = {
            "OIDC_ISSUER": "https://id.example.invalid/realms/stardelt",
            "TRINO_URL": "https://trino.stardelt.svc.cluster.local:8443",
            "TRINO_CA": str(ca),
            "CLIENT_ID": "sp-pipeline-demo",
            "CLIENT_SECRET": "never-read",
            "NAMESPACE": "stardelt",
        }

        def fake_delete(namespace):
            order.append(("pipelines", namespace))
            return 3

        def fake_reset(pipelines=0):
            order.append(("drop", pipelines))
            return 0

        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            JOB, "token", lambda: "never-read"
        ), mock.patch.object(JOB, "trino_context", lambda path: None), mock.patch.object(
            JOB, "delete_visitor_pipelines", fake_delete
        ), mock.patch.object(
            JOB, "reset", fake_reset
        ):
            self.assertEqual(JOB.main(), 0)

        self.assertEqual(order, [("pipelines", "stardelt"), ("drop", 3)])


class Environment(unittest.TestCase):
    """Each of the five settings stops the run with exit code 2 before any network call."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.ca = Path(directory.name) / "ca.crt"
        self.ca.write_text("a path that exists; the job only checks for it here")
        self.env = {
            "OIDC_ISSUER": "https://id.example.invalid/realms/stardelt",
            "TRINO_URL": "https://trino.stardelt.svc.cluster.local:8443",
            "TRINO_CA": str(self.ca),
            "CLIENT_ID": "sp-pipeline-demo",
            "CLIENT_SECRET": "never-read",
        }

    def test_each_missing_setting_is_exit_two(self):
        for name in ("OIDC_ISSUER", "TRINO_URL", "TRINO_CA", "CLIENT_ID", "CLIENT_SECRET"):
            env = {key: value for key, value in self.env.items() if key != name}
            with self.subTest(missing=name), mock.patch.dict(os.environ, env, clear=True):
                self.assertEqual(JOB.main(), 2)


class TrinoContext(unittest.TestCase):
    def test_the_one_anchor_is_the_only_addition(self):
        sentinel = object()
        with mock.patch.object(ssl, "create_default_context", return_value=sentinel) as create:
            self.assertIs(JOB.trino_context("/tmp/x"), sentinel)
        create.assert_called_once_with(cafile="/tmp/x")


if __name__ == "__main__":
    unittest.main()
