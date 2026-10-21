"""Unit tests for scripts/node-budget.py (platform#373).

Standard library only, like the script: `python3 -m unittest discover -s scripts/tests -v`
runs them in CI. `render()` is pure, so every test drives canned `kubectl get ... -o
json` documents and a canned `kubectl top` text; the two tests that need kubectl
replace `subprocess.run`, so no cluster is touched.
"""
import contextlib
import importlib.util
import io
import json
import subprocess
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "node-budget.py"
_spec = importlib.util.spec_from_file_location("node_budget", SCRIPT)
node_budget = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(node_budget)

OVER = "over request (eviction candidates):"
SLACK = "slack (request not used):"

# Canned metrics: `ns-a/trino` 350 Mi of a 300 Mi request (over), `ns-a/spark` 500 of
# 200 (over), `ns-a/idle` 40 of 100 (slack). `ns-a/cold` has no row at all.
TOP = "ns-a  trino  10m  350Mi\nns-a  spark  10m  500Mi\nns-a  idle   1m   40Mi\n"


def node(memory="1000Mi", name="node-a"):
    return {"metadata": {"name": name}, "status": {"allocatable": {"memory": memory}}}


def pod(namespace, name, requests=None, limits=None, phase="Running", node_name="node-a"):
    """One single-container Pod; None leaves that half of `resources` out entirely."""
    resources = {}
    if requests is not None:
        resources["requests"] = {"memory": requests}
    if limits is not None:
        resources["limits"] = {"memory": limits}
    return {
        "metadata": {"namespace": namespace, "name": name},
        "spec": {"nodeName": node_name, "containers": [{"name": "main", "resources": resources}]},
        "status": {"phase": phase},
    }


def fixture_pods():
    """Requests 700 Mi, limits 1100 Mi, used 890 Mi; one over, one slack, one no metrics."""
    return {
        "items": [
            pod("ns-a", "trino", requests="300Mi", limits="400Mi"),
            pod("ns-a", "spark", requests="200Mi", limits="600Mi"),
            pod("ns-a", "idle", requests="100Mi", limits="100Mi"),
            pod("ns-a", "cold", requests="100Mi"),
            pod("ns-a", "pending", requests="900Mi", limits="900Mi", phase="Pending"),
        ]
    }


def report_for(pods=None, nodes=None, top=TOP):
    return node_budget.render(nodes or {"items": [node()]}, pods or fixture_pods(), top)


def table(report, header):
    """The (namespace/pod, request, limit, used) rows under one section header."""
    lines = report.splitlines()
    rows = []
    for line in lines[lines.index(header) + 2:]:
        if not line.strip() or line == OVER or line == SLACK or line.startswith("headroom:"):
            break
        rows.append(line.split())
    return rows


class ParseSize(unittest.TestCase):
    def test_parses_units_ki_mi_gi_and_bytes(self):
        self.assertEqual(node_budget.parse_size("1024Ki"), 1048576)
        self.assertEqual(node_budget.parse_size("512Mi"), 512 * 1024 ** 2)
        self.assertEqual(node_budget.parse_size("2Gi"), 2 * 1024 ** 3)
        self.assertEqual(node_budget.parse_size("1000K"), 1000 * 1000)
        self.assertEqual(node_budget.parse_size("5M"), 5 * 1000 ** 2)
        self.assertEqual(node_budget.parse_size("3G"), 3 * 1000 ** 3)
        self.assertEqual(node_budget.parse_size("1048576"), 1048576)
        self.assertEqual(node_budget.parse_size(None), 0)
        self.assertEqual(node_budget.parse_size(""), 0)
        with self.assertRaises(ValueError):
            node_budget.parse_size("12nonsense")

    def test_allocatable_ki_rounds_to_the_mib_kubectl_reports(self):
        # 15987540Ki is 15612.8 Mi; the node line in the ticket's verify says 15613 Mi.
        self.assertEqual(node_budget._mib(node_budget.parse_size("15987540Ki")), 15613)

    def test_percent_truncates_so_99_point_5_is_99(self):
        allocatable = node_budget.parse_size("15987540Ki")
        self.assertEqual(node_budget._percent(15536 * 1024 ** 2, allocatable), 99)
        self.assertEqual(node_budget._percent(0, allocatable), 0)
        self.assertEqual(node_budget._percent(1024, 0), 0)


class PodMemory(unittest.TestCase):
    def test_sums_containers_and_missing_values_are_zero(self):
        pod_doc = {
            "spec": {
                "containers": [
                    {"resources": {"requests": {"memory": "128Mi"}, "limits": {"memory": "256Mi"}}},
                    {"resources": {"requests": {"memory": "64Mi"}}},
                    {"name": "no-resources"},
                ]
            }
        }
        self.assertEqual(
            node_budget._pod_memory(pod_doc), (192 * 1024 ** 2, 256 * 1024 ** 2)
        )
        self.assertEqual(node_budget._pod_memory({"spec": {"containers": []}}), (0, 0))
        self.assertEqual(node_budget._pod_memory({}), (0, 0))


class Sections(unittest.TestCase):
    def test_node_line_has_the_ticket_shape(self):
        first = report_for().splitlines()[0]
        self.assertEqual(
            first,
            "node node-a: allocatable 1000 Mi | requests 700 Mi (70 %)"
            " | limits 1100 Mi (110 %) | used 890 Mi (89 %)",
        )

    def test_over_request_lists_only_positive_and_sorted(self):
        rows = table(report_for(), OVER)
        self.assertEqual([row[0] for row in rows], ["ns-a/spark", "ns-a/trino"])
        self.assertEqual(rows[0][1:], ["200", "600", "500"])
        self.assertEqual(rows[1][1:], ["300", "400", "350"])

    def test_slack_sorted_descending(self):
        rows = table(report_for(), SLACK)
        self.assertEqual(
            [row[0] for row in rows], ["ns-a/cold", "ns-a/idle", "ns-a/trino", "ns-a/spark"]
        )
        # request - used, descending: 100, 60, -50, -300.
        self.assertEqual([row[1:] for row in rows], [
            ["100", "0", "?"],
            ["100", "100", "40"],
            ["300", "400", "350"],
            ["200", "600", "500"],
        ])

    def test_pod_without_top_row_is_marked(self):
        report = report_for()
        cold = [row for row in table(report, SLACK) if row[0] == "ns-a/cold"]
        self.assertEqual(len(cold), 1)
        self.assertEqual(cold[0][3], "?")
        # ... and it counts as 0 bytes used, not as a missing pod: 350 + 500 + 40.
        self.assertIn("| used 890 Mi (89 %)", report)

    def test_headroom_line_matches_the_sums(self):
        last = report_for().splitlines()[-1]
        self.assertEqual(last, "headroom: 300 Mi by requests, 110 Mi by use")

    def test_not_running_pods_are_ignored(self):
        report = report_for()
        self.assertNotIn("pending", report)
        self.assertIn("requests 700 Mi (70 %)", report)
        self.assertNotIn("1600 Mi", report)

    def test_sections_stop_at_ten_rows(self):
        pods = {
            "items": [pod("ns-a", "p%02d" % i, requests="1Mi") for i in range(12)]
        }
        top = "\n".join("ns-a  p%02d  1m  %dMi" % (i, 10 + i) for i in range(12))
        rows = table(report_for(pods=pods, top=top), OVER)
        self.assertEqual(len(rows), 10)
        self.assertEqual(rows[0][0], "ns-a/p11")
        self.assertEqual(rows[-1][0], "ns-a/p02")


class Kubectl(unittest.TestCase):
    def completed(self, code, stdout="", stderr=""):
        return subprocess.CompletedProcess(args=["kubectl"], returncode=code, stdout=stdout, stderr=stderr)

    def run_main(self, results):
        stderr = io.StringIO()
        with mock.patch.object(node_budget.subprocess, "run", side_effect=results), \
                contextlib.redirect_stderr(stderr):
            code = node_budget.main()
        return code, stderr.getvalue()

    def test_kubectl_failure_exits_one_with_one_sentence(self):
        code, stderr = self.run_main([
            self.completed(1, stderr="error: connection refused\nmore detail")
        ])
        self.assertEqual(code, 1)
        self.assertEqual(stderr.strip().splitlines(), [
            "node-budget: kubectl get nodes failed: error: connection refused"
        ])

    def test_top_unavailable_exits_one_with_one_sentence(self):
        nodes = json.dumps({"items": [node()]})
        pods = json.dumps(fixture_pods())
        code, stderr = self.run_main([
            self.completed(0, stdout=nodes),
            self.completed(0, stdout=pods),
            self.completed(1, stderr="error: Metrics API not available"),
        ])
        self.assertEqual(code, 1)
        self.assertEqual(stderr.strip().splitlines(), [
            "node-budget: kubectl top is unavailable: error: Metrics API not available"
        ])

    def test_missing_kubectl_exits_one_with_one_sentence(self):
        code, stderr = self.run_main([FileNotFoundError("kubectl")])
        self.assertEqual(code, 1)
        self.assertEqual(stderr.strip().splitlines(), [
            "node-budget: kubectl was not found (run 'make deps')"
        ])

    def test_success_prints_the_report_and_exits_zero(self):
        nodes = json.dumps({"items": [node()]})
        pods = json.dumps(fixture_pods())
        stdout = io.StringIO()
        results = [
            self.completed(0, stdout=nodes),
            self.completed(0, stdout=pods),
            self.completed(0, stdout=TOP),
        ]
        with mock.patch.object(node_budget.subprocess, "run", side_effect=results), \
                contextlib.redirect_stdout(stdout):
            code = node_budget.main()
        self.assertEqual(code, 0)
        self.assertTrue(stdout.getvalue().startswith("node node-a: allocatable 1000 Mi"))


if __name__ == "__main__":
    unittest.main()
