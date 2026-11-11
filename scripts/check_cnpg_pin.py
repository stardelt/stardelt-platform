#!/usr/bin/env python3
"""Fail when the CloudNativePG chart pin leaves 0.28.x before the backup-plugin migration.

CNPG's native spec.backup.barmanObjectStore is removed in 1.30. The chart pin in the Makefile
(CNPG_VERSION) sits one minor below it; renovate must not move it before platform#192 lands.
Reads the Makefile only: no cluster, no helm.
"""
from __future__ import annotations

import argparse
import pathlib
import re

ALLOWED_PREFIX = "0.28."
VERSION_RE = re.compile(r"^CNPG_VERSION\s*:=\s*(\S+)\s*$", re.M)
DEFAULT_MAKEFILE = pathlib.Path(__file__).resolve().parents[1] / "Makefile"


def cnpg_version(text: str) -> str:
    """The Makefile's CNPG_VERSION, or SystemExit when the line is missing."""
    match = VERSION_RE.search(text)
    if not match:
        raise SystemExit("✗ CNPG_VERSION: not found in the Makefile")
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--makefile", type=pathlib.Path, default=DEFAULT_MAKEFILE)
    args = parser.parse_args()
    version = cnpg_version(args.makefile.read_text())
    if not version.startswith(ALLOWED_PREFIX):
        print(
            f"✗ CloudNativePG chart {version}: keep the pin on {ALLOWED_PREFIX}x until the "
            "barmanObjectStore plugin migration is done and verified (platform#192)."
        )
        return 1
    print(f"✓ CloudNativePG chart {version} — still below the 1.30 backup-plugin migration (platform#192)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
