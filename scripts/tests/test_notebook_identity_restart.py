"""The verifier never interrupts the spawn its own sign-in started (platform#1252).

`helm-values/jupyterhub.yaml` sets `auth.auto_login: true`, so the sign-in in step 1
spawns the server. The script's step 2 used to DELETE into that in-flight spawn;
JupyterHub answered `400 … pending stop`, created no pod, and gave up after 300 s.
These tests drive `ensure_fresh_server()` against a fake hub, so the sequence is pinned.
"""

import importlib.util
import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "verify-notebook-identity.py"


def load_script():
    spec = importlib.util.spec_from_file_location("verify_notebook_identity", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SpawnerRace(unittest.TestCase):
    def setUp(self):
        self.mod = load_script()
        self.mod.failures.clear()
        self.mod.RESTART_RETRY_SECONDS = 0
        self.mod.server_ready = lambda: True
        # A single poll is the answer for every path here.
        self.mod.wait_for = lambda predicate, what, timeout=None: predicate()

    def test_a_pending_spawn_is_waited_for_and_not_deleted(self):
        self.mod.server_state = lambda: "pending"
        calls = []

        def request(method, url, data=None):
            calls.append(method)
            return 200, url, "{}"

        self.mod.request = request
        self.assertTrue(self.mod.ensure_fresh_server())
        self.assertEqual(calls, [])

    def test_a_running_server_is_restarted_after_it_stops(self):
        states = iter(["ready", "stopped"])
        self.mod.server_state = lambda: next(states, "ready")
        calls = []

        def request(method, url, data=None):
            calls.append(method)
            # The hub answers DELETE with 204 and the spawn POST with 202
            # (its log in platform#1252 records `POST …/server => 202`).
            return (204 if method == "DELETE" else 202), url, ""

        self.mod.request = request
        self.assertTrue(self.mod.ensure_fresh_server())
        self.assertEqual(calls, ["DELETE", "POST"])

    def test_a_post_answered_pending_stop_is_retried(self):
        self.mod.server_state = lambda: "ready"
        answers = iter(
            [
                (204, ""),
                (400, '{"status": 400, "message": "analyst is pending stop"}'),
                (202, ""),
            ]
        )
        calls = []

        def request(method, url, data=None):
            calls.append(method)
            status, body = next(answers)
            return status, url, body

        self.mod.request = request
        self.assertTrue(self.mod.ensure_fresh_server())
        self.assertEqual(calls, ["DELETE", "POST", "POST"])

    def test_a_post_refused_for_another_reason_fails(self):
        self.mod.server_state = lambda: "ready"
        answers = iter([(204, ""), (400, '{"status": 400, "message": "no such user"}')])

        def request(method, url, data=None):
            status, body = next(answers)
            return status, url, body

        self.mod.request = request
        self.assertFalse(self.mod.ensure_fresh_server())
        self.assertIn("server restarted", self.mod.failures)


if __name__ == "__main__":
    unittest.main()
