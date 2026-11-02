"""The idempotence gate's snapshot of workloads (platform#479).

`scripts/platform.sh` compares a snapshot taken before and after the flow. A Deployment, a
StatefulSet or a DaemonSet is measured as the whole object without its status and bookkeeping, so a
readiness flap under load does not read as "the flow changed the cluster", and a changed image,
variable, replica count, label or annotation still does. The test runs the real `snapshot` function
of the script with a fake `kubectl` that answers from fixture files.
"""

import copy
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "platform.sh"

FAKE_KUBECTL = """#!/usr/bin/env bash
# kubectl -n NAMESPACE get KIND -o json
file="$FIXTURES/$4.json"
[ -f "$file" ] || exit 1
cat "$file"
"""


def workload(name, image="registry/app:1", ready=1, resource_version="100", generation=1):
    return {
        "metadata": {
            "name": name,
            "labels": {"app": name},
            "annotations": {"note": "a"},
            "resourceVersion": resource_version,
            "generation": generation,
            "managedFields": [{"manager": "kubectl", "time": "2026-11-02T10:00:00Z"}],
        },
        "spec": {
            "replicas": 1,
            "template": {"spec": {"containers": [{"name": name, "image": image}]}},
        },
        "status": {"readyReplicas": ready, "observedGeneration": generation},
    }


def cluster():
    return {
        "deployments": [workload("nova")],
        "statefulsets": [workload("openbao")],
        "daemonsets": [workload("collector")],
    }


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "needs bash and jq")
class WorkloadSnapshotTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = SCRIPT.read_text()
        kinds = re.search(r'^SNAPSHOT_KINDS="[^"]*"$', text, re.M | re.S)
        function = re.search(r"^snapshot\(\) \{\n.*?^\}\n", text, re.M | re.S)
        assert kinds and function, "SNAPSHOT_KINDS or snapshot() not found in platform.sh"
        cls.program = "set -euo pipefail\nNAMESPACE=stardelt\n" + kinds.group(0) + "\n" + function.group(0) + "snapshot\n"

    def snapshot(self, kinds):
        with tempfile.TemporaryDirectory() as tmp:
            fixtures = Path(tmp) / "fixtures"
            fixtures.mkdir()
            for kind, items in kinds.items():
                (fixtures / f"{kind}.json").write_text(json.dumps({"items": items}))
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            kubectl = bindir / "kubectl"
            kubectl.write_text(FAKE_KUBECTL)
            kubectl.chmod(0o755)
            env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", FIXTURES=str(fixtures))
            done = subprocess.run(
                ["bash", "-c", self.program], env=env, capture_output=True, text=True, check=True
            )
        return done.stdout.splitlines()

    def test_every_workload_is_one_short_line_named_by_kind(self):
        lines = self.snapshot(cluster())
        self.assertEqual(
            [line.split("=")[0] for line in lines],
            ["daemonsets/collector", "deployments/nova", "statefulsets/openbao"],
        )
        self.assertTrue(all(len(line) < 60 for line in lines), lines)

    def test_status_and_bookkeeping_do_not_move_the_snapshot(self):
        before = self.snapshot(cluster())
        flapped = cluster()
        for items in flapped.values():
            item = items[0]
            item["status"] = {"readyReplicas": 0, "observedGeneration": 7, "conditions": [{"type": "Available"}]}
            item["metadata"]["resourceVersion"] = "928936"
            item["metadata"]["generation"] = 4
            item["metadata"]["managedFields"] = [{"manager": "kube-controller-manager"}]
        self.assertEqual(self.snapshot(flapped), before)

    def test_a_changed_image_moves_only_that_workload(self):
        before = self.snapshot(cluster())
        changed = copy.deepcopy(cluster())
        changed["deployments"][0]["spec"]["template"]["spec"]["containers"][0]["image"] = "registry/app:2"
        after = self.snapshot(changed)
        self.assertNotEqual(after, before)
        self.assertEqual([a for a, b in zip(after, before) if a != b][0].split("=")[0], "deployments/nova")
        self.assertEqual(sum(1 for a, b in zip(after, before) if a != b), 1)

    def test_a_changed_replica_count_moves_the_snapshot(self):
        before = self.snapshot(cluster())
        changed = cluster()
        changed["statefulsets"][0]["spec"]["replicas"] = 3
        self.assertNotEqual(self.snapshot(changed), before)

    def test_a_changed_label_or_annotation_moves_the_snapshot(self):
        before = self.snapshot(cluster())
        labelled = cluster()
        labelled["daemonsets"][0]["metadata"]["labels"]["tier"] = "x"
        self.assertNotEqual(self.snapshot(labelled), before)
        annotated = cluster()
        annotated["deployments"][0]["metadata"]["annotations"]["note"] = "b"
        self.assertNotEqual(self.snapshot(annotated), before)


if __name__ == "__main__":
    unittest.main()
