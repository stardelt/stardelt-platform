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
            if ".information_schema.tables" in sql:
                return [['s"1', "t", "BASE TABLE"], ['s"1', "v", "VIEW"]]
            if ".information_schema.schemata" in sql:
                return [['s"1']]
            return []

        with mock.patch.object(JOB, "CATALOG", "playground"), mock.patch.object(JOB, "run", fake_run):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                failed = JOB.reset()

        self.assertEqual(failed, 0)
        self.assertEqual(
            output.getvalue().strip(),
            "demo-reset: dropped 1 tables, 1 views, 1 schemas; scratch ready",
        )
        self.assertEqual(
            statements,
            [
                "select table_schema, table_name, table_type from playground.information_schema.tables"
                " where table_schema <> 'information_schema'",
                'drop table playground."s""1"."t"',
                'drop view playground."s""1"."v"',
                "select schema_name from playground.information_schema.schemata"
                " where schema_name <> 'information_schema'",
                'drop schema playground."s""1"',
                "create schema if not exists playground.scratch",
            ],
        )


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
