#!/usr/bin/env python3
"""Fail when the registry's tag moved ahead of a checked-in pin.

No cluster, no kubectl: it resolves each pin's tag with `PRINT_DIGEST=1` mode of
`scripts/pin-image.sh` and compares that digest with the one the manifests pin.
See stardelt-platform#556.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PIN_IMAGE = REPO / "scripts" / "pin-image.sh"

# (app, manifest, kind, tag): the registry tag whose digest the manifest must pin.
APPS = [
    ("nova", "manifests/nova-deployment.yaml", "image", "dev"),
    ("spark", "manifests/spark.yaml", "image", "dev"),
    ("stardelt-operator", "helm-values/operator.yaml", "tag", "dev"),
    ("superset", "helm-values/superset.yaml", "tag", "dev"),
    ("airflow", "helm-values/airflow.yaml", "digest", "demo"),
]

DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")


def _short(digest: str) -> str:
    m = re.search(r"sha256:([0-9a-f]{8})", digest)
    return m.group(1) + "…" if m else digest


def parse_pins(text: str, kind: str) -> list[str]:
    """Every `sha256:<64 hex>` this file pins for one app.

    kind="image": every `image: <repo>:dev@sha256:<digest>` line and every
    `spark.kubernetes.container.image <repo>:dev@sha256:<digest>` line.
    kind="tag":   the `tag: dev@sha256:<digest>` line, unquoted (helm-values/operator.yaml)
                  or quoted (helm-values/superset.yaml).
    kind="digest": the single bare `digest: sha256:<digest>` line
    (helm-values/airflow.yaml); anything but exactly one is "no pin".
    """
    if kind == "image":
        pattern = re.compile(
            r"^\s*(?:image:\s+ghcr\.io/stardelt/(?:nova|spark):dev@"
            r"|spark\.kubernetes\.container\.image\s+ghcr\.io/stardelt/spark:dev@)"
            r"(sha256:[0-9a-f]{64})\s*$",
            re.M,
        )
    elif kind == "tag":
        pattern = re.compile(r'^\s*tag:\s*"?\S+@(sha256:[0-9a-f]{64})"?\s*$', re.M)
    elif kind == "digest":
        pattern = re.compile(r"^\s*digest: (sha256:[0-9a-f]{64})\s*$", re.M)
        found = pattern.findall(text)
        return found if len(found) == 1 else []
    else:
        raise ValueError(f"unknown kind: {kind}")
    return pattern.findall(text)


def compare(
    app: str, pinned: list[str], resolved: str, where: str, tag: str = "dev"
) -> list[str]:
    """One line per pin: '✓ …' when it equals `resolved`, else '✗ … — run ./scripts/pin-image.sh <app>'."""
    lines: list[str] = []
    if pinned and all(p == resolved for p in pinned):
        suffix = f" ({len(pinned)} pins)" if len(pinned) > 1 else ""
        lines.append(f"✓ {app} {tag}@{_short(resolved)} matches {where}{suffix}")
        return lines
    for p in pinned:
        if p == resolved:
            lines.append(f"✓ {app} {tag}@{_short(resolved)} matches {where}")
        else:
            lines.append(
                f"✗ {app} pinned {_short(p)}, {tag} resolves to {_short(resolved)}"
                f" — run ./scripts/pin-image.sh {app}"
            )
    if not pinned:
        lines.append(f"✗ {app} has no pin in {where} — run ./scripts/pin-image.sh {app}")
    return lines


def exit_code(lines: list[str]) -> int:
    """0 when no line starts with '✗', else 1."""
    return 1 if any(line.startswith("✗") for line in lines) else 0


def resolve_digest(app: str, tag: str = "dev") -> tuple[str | None, str]:
    env = dict(os.environ)
    env["PRINT_DIGEST"] = "1"
    env["APP"] = app
    env["TAG"] = tag
    proc = subprocess.run(
        ["bash", str(PIN_IMAGE)],
        cwd=REPO,
        env=env,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        err = (proc.stderr.strip() or proc.stdout.strip() or "unknown error").splitlines()[0]
        return None, err
    digest = proc.stdout.strip()
    if not DIGEST_RE.fullmatch(digest):
        return None, f"unexpected output: {digest!r}"
    return digest, ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--allow-offline",
        action="store_true",
        help="treat an unreachable registry as a note, not a failure",
    )
    args = parser.parse_args(argv)

    lines: list[str] = []
    offline_failed = False
    for app, manifest, kind, tag in APPS:
        path = REPO / manifest
        text = path.read_text()
        pinned = parse_pins(text, kind)
        resolved, err = resolve_digest(app, tag)
        if resolved is None:
            lines.append(f"– {app}: the registry did not answer ({err})")
            if not args.allow_offline:
                offline_failed = True
            continue
        lines.extend(compare(app, pinned, resolved, manifest, tag))

    for line in lines:
        print(line)
    if offline_failed:
        return 1
    return exit_code(lines)


if __name__ == "__main__":
    raise SystemExit(main())
