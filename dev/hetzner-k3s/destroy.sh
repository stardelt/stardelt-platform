#!/usr/bin/env bash
# Delete the Hetzner dev server. The firewall and SSH key are kept for reuse.
set -euo pipefail
NAME="${NAME:-stardelt-dev}"

command -v hcloud >/dev/null 2>&1 || { echo "hcloud CLI not found" >&2; exit 1; }
if [ -z "${HCLOUD_TOKEN:-}" ]; then
  hcloud context active >/dev/null 2>&1 || {
    echo "No active hcloud context and HCLOUD_TOKEN is unset." >&2
    echo "  Run:  hcloud context create stardelt" >&2
    exit 1
  }
fi

if hcloud server describe "$NAME" >/dev/null 2>&1; then
  hcloud server delete "$NAME"
  echo "✓ deleted server '$NAME' (firewall + ssh key kept)"
else
  echo "server '$NAME' does not exist"
fi
