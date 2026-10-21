#!/usr/bin/env python3
"""Print the node's memory budget: requests, limits and real use per pod (platform#373).

The single 16 GB dev node is the ceiling for every Spark size, and the number that
decides whether another pod fits is not the free memory but the *requests*: at 99 %
of allocatable a new request, however small, leaves the pod Pending. `make
node-budget` prints, in one screen:

    node <name>: allocatable <n> Mi | requests <n> Mi (<p> %) | limits <n> Mi (<p> %) | used <n> Mi (<p> %)
    over request (eviction candidates):    used - request > 0, the pods the kubelet
                                           evicts first under memory pressure
    slack (request not used):              request - used, the promise nothing uses
    headroom: <allocatable - requests> Mi by requests, <allocatable - used> Mi by use

Three read-only kubectl calls, no cluster change: `get nodes -o json`, `get pods -A
-o json`, `top pods -A --no-headers`. KUBECONFIG is honoured because kubectl reads it
from the environment. `used` is the sum of the pods' `kubectl top` rows, so it is
smaller than `kubectl top node` (that counts the kubelet, containerd and the rest of
the host too); `headroom ... by use` is therefore the pods' own slack, not the node's.

Every pod request or limit is the sum over its containers, and a missing value counts
as 0. Only `phase: Running` pods count — a completed or evicted object keeps its
requests but runs nowhere. A running pod without a metrics row counts as 0 used and
its USED cell is `?` (metrics can lag a few seconds behind a fresh pod).

Standard library only, like `scripts/access-sync-job.py`; `render()` is pure (no I/O)
and `main()` is the only part that talks to kubectl, so the unit tests run without a
cluster.
"""

import json
import subprocess
import sys

# Binary (Ki/Mi/Gi) and decimal (K/M/G) suffixes, longest first so `Mi` does not match
# `M`. A quantity without a suffix is bytes, which is what `kubectl top` prints for a
# small value.
_UNITS = (
    ("Ki", 1024),
    ("Mi", 1024 ** 2),
    ("Gi", 1024 ** 3),
    ("K", 1000),
    ("M", 1000 ** 2),
    ("G", 1000 ** 3),
)

_HEADERS = ("NAMESPACE/POD", "REQUEST", "LIMIT", "USED")


def parse_size(text):
    """A Kubernetes memory quantity as bytes; None, "" and 0 are 0.

    `Ki|Mi|Gi|K|M|G` are honoured (binary and decimal) and a bare number is bytes.
    Anything else raises ValueError — the callers decide whether that is a missing
    value or an error.
    """
    if text is None:
        return 0
    value = str(text).strip()
    if not value:
        return 0
    for suffix, factor in _UNITS:
        if value.endswith(suffix):
            return int(float(value[: -len(suffix)]) * factor)
    return int(float(value))


def _mib(value):
    """Bytes to whole MiB, rounded: 15987540Ki is the 15613 Mi that `kubectl` reports."""
    return int(round(value / 1048576.0))


def _percent(part, total):
    """Whole percent, truncated: 99.5 % of allocatable is the 99 % the node is at."""
    return int(100.0 * part / total) if total else 0


def _pod_memory(pod):
    """(requests, limits) in bytes, summed over the pod's containers; missing is 0."""
    requests = 0
    limits = 0
    for container in pod.get("spec", {}).get("containers") or []:
        resources = container.get("resources") or {}
        requests += parse_size((resources.get("requests") or {}).get("memory"))
        limits += parse_size((resources.get("limits") or {}).get("memory"))
    return requests, limits


def _top_rows(top_text):
    """{(namespace, pod): bytes used} from `kubectl top pods -A --no-headers`.

    The columns are NAMESPACE, POD, CPU, MEMORY; only the memory column is read. A row
    whose memory cell cannot be parsed (or a line that is too short) is dropped, so the
    pod shows up as "no metrics row" and is marked `?` rather than counted as 0 bytes.
    """
    rows = {}
    for line in (top_text or "").splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        try:
            rows[(fields[0], fields[1])] = parse_size(fields[3])
        except ValueError:
            continue
    return rows


def _table(rows):
    """Render (namespace, pod, requests, limits, used) rows under the four headers.

    `used` of None means "no metrics row" and prints `?`. The name column is
    left-aligned, the numbers right-aligned, two spaces between columns.
    """
    cells = [
        (
            "%s/%s" % (namespace, pod),
            str(_mib(requests)),
            str(_mib(limits)),
            "?" if used is None else str(_mib(used)),
        )
        for namespace, pod, requests, limits, used in rows
    ]
    widths = [
        max([len(header)] + [len(cell[index]) for cell in cells])
        for index, header in enumerate(_HEADERS)
    ]

    def line(values):
        return "  ".join(
            value.ljust(widths[index]) if index == 0 else value.rjust(widths[index])
            for index, value in enumerate(values)
        )

    return [line(_HEADERS)] + [line(cell) for cell in cells]


def _node_block(node, running, top):
    """One node: the budget line, both sections and the headroom line."""
    name = node.get("metadata", {}).get("name") or "<unnamed>"
    allocatable = parse_size((node.get("status", {}).get("allocatable") or {}).get("memory"))

    rows = []
    for pod in running:
        if pod.get("spec", {}).get("nodeName") != name:
            continue
        metadata = pod.get("metadata") or {}
        requests, limits = _pod_memory(pod)
        used = top.get((metadata.get("namespace"), metadata.get("name")))
        rows.append((metadata.get("namespace"), metadata.get("name"), requests, limits, used))

    request_sum = sum(row[2] for row in rows)
    limit_sum = sum(row[3] for row in rows)
    used_sum = sum(row[4] or 0 for row in rows)

    lines = [
        "node %s: allocatable %d Mi | requests %d Mi (%d %%) | limits %d Mi (%d %%)"
        " | used %d Mi (%d %%)"
        % (
            name,
            _mib(allocatable),
            _mib(request_sum),
            _percent(request_sum, allocatable),
            _mib(limit_sum),
            _percent(limit_sum, allocatable),
            _mib(used_sum),
            _percent(used_sum, allocatable),
        )
    ]

    # used - request > 0 only: a pod at or below its request is not an eviction
    # candidate. Ties keep a stable order (namespace, then pod) so two runs agree.
    over = [
        (used - requests, namespace, pod, requests, limits, used)
        for namespace, pod, requests, limits, used in rows
        if (used or 0) - requests > 0
    ]
    over.sort(key=lambda row: (-row[0], row[1], row[2]))
    lines.append("over request (eviction candidates):")
    lines.extend(
        _table([(row[1], row[2], row[3], row[4], row[5]) for row in over[:10]])
    )

    slack = [
        (requests - (used or 0), namespace, pod, requests, limits, used)
        for namespace, pod, requests, limits, used in rows
    ]
    slack.sort(key=lambda row: (-row[0], row[1], row[2]))
    lines.append("slack (request not used):")
    lines.extend(
        _table([(row[1], row[2], row[3], row[4], row[5]) for row in slack[:10]])
    )

    lines.append(
        "headroom: %d Mi by requests, %d Mi by use"
        % (_mib(allocatable - request_sum), _mib(allocatable - used_sum))
    )
    return "\n".join(lines)


def render(nodes, pods, top_text):
    """The whole report as one string; pure, so the tests need no cluster.

    `nodes` and `pods` are the parsed `kubectl get ... -o json` documents, `top_text`
    the raw output of `kubectl top pods -A --no-headers`. One block per node, in name
    order (the dev cluster has one, so the report is exactly the documented shape).
    """
    top = _top_rows(top_text)
    running = [
        pod
        for pod in pods.get("items") or []
        if (pod.get("status") or {}).get("phase") == "Running"
    ]
    ordered = sorted(
        nodes.get("items") or [],
        key=lambda item: (item.get("metadata") or {}).get("name", ""),
    )
    return "\n\n".join(_node_block(node, running, top) for node in ordered)


def _first_line(text):
    """The first non-empty line of a kubectl failure, for the one-sentence error."""
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()
    return "no output"


def _fail(message):
    print("node-budget: %s" % message, file=sys.stderr)
    return 1


def _kubectl(*args):
    """Run kubectl with the caller's environment, so KUBECONFIG is honoured."""
    return subprocess.run(["kubectl"] + list(args), capture_output=True, text=True)


def main():
    try:
        nodes = _kubectl("get", "nodes", "-o", "json")
        if nodes.returncode != 0:
            return _fail("kubectl get nodes failed: %s" % _first_line(nodes.stderr))
        pods = _kubectl("get", "pods", "-A", "-o", "json")
        if pods.returncode != 0:
            return _fail("kubectl get pods failed: %s" % _first_line(pods.stderr))
        top = _kubectl("top", "pods", "-A", "--no-headers")
    except FileNotFoundError:
        return _fail("kubectl was not found (run 'make deps')")
    if top.returncode != 0:
        return _fail("kubectl top is unavailable: %s" % _first_line(top.stderr))

    try:
        report = render(json.loads(nodes.stdout), json.loads(pods.stdout), top.stdout)
    except json.JSONDecodeError as error:
        return _fail("kubectl returned unreadable JSON: %s" % error)
    if not report:
        return _fail("the cluster has no nodes")

    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
