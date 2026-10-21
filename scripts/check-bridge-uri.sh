#!/usr/bin/env bash
# One source for the bridge's policy paths (stardelt-platform#359).
#
#   make lint
#
# `scripts/lib/bridge.sh` holds the two paths Trino is configured with. The
# replay, the latency probe and the capture read them from there; this check
# makes sure `helm-values/trino-identity.yaml` — the file that configures Trino
# — agrees. Without it the replay could keep passing while the engine asks a
# different path (which is exactly what the switch #311 changes).
#
# The values file may not carry the OPA authorizer at all (an install without
# the switch): then there is nothing to compare and the check says so. Once the
# file names `opa.policy.batched-uri` or `opa.policy.uri`, both must match.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VALUES="helm-values/trino-identity.yaml"

# shellcheck source=lib/bridge.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/bridge.sh"

batched="${BRIDGE_BATCH_PATH#/v1/data/}"
allow="${BRIDGE_ALLOW_PATH#/v1/data/}"

fail() { echo "check-bridge-uri: $*" >&2; exit 1; }

[ -f "$VALUES" ] || fail "$VALUES is missing"

declared_batched="$(sed -n 's|^[[:space:]]*opa\.policy\.batched-uri=.*/v1/data/\([^[:space:]]*\)$|\1|p' "$VALUES" | sort -u)"
declared_allow="$(sed -n 's|^[[:space:]]*opa\.policy\.uri=.*/v1/data/\([^[:space:]]*\)$|\1|p' "$VALUES" | sort -u)"

if [ -z "$declared_batched" ] && [ -z "$declared_allow" ]; then
  echo "check-bridge-uri: $VALUES names no OPA policy path (the switch is not applied) — nothing to compare"
  exit 0
fi

[ "$declared_batched" = "$batched" ] \
  || fail "$VALUES: opa.policy.batched-uri must end in /v1/data/$batched (scripts/lib/bridge.sh BRIDGE_BATCH_PATH), found '${declared_batched:-none}'"
[ "$declared_allow" = "$allow" ] \
  || fail "$VALUES: opa.policy.uri must end in /v1/data/$allow (scripts/lib/bridge.sh BRIDGE_ALLOW_PATH), found '${declared_allow:-none}'"

echo "check-bridge-uri: OK — $VALUES asks /v1/data/$allow and /v1/data/$batched"
