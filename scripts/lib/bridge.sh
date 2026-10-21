#!/usr/bin/env bash
# The bridge's policy paths, in one place (stardelt-platform#359).
#
#   . scripts/lib/bridge.sh
#
# Not a program: `source` it. It answers one question — which path on the OPA
# bridge answers which Trino question — so the scripts that ask the bridge
# (`bridge-replay.sh`, `bridge-latency.sh`) and the script that records what
# Trino asks (`bridge-capture.sh`) cannot drift from the value Trino is
# configured with (`helm-values/trino-identity.yaml`,
# `opa.policy.batched-uri` / `opa.policy.uri`).
#
# Why one variable and not three constants: the switch (platform#311) points
# `opa.policy.batched-uri` at `BRIDGE_BATCH_PATH`. A replay that still asks the
# chart's old `/v1/data/trino/batch` would pass while the engine calls something
# else — the failure mode this file exists to prevent. `make lint`
# (`scripts/check-bridge-uri.sh`) fails when the values file names another path.
#
# `scripts/tests/fixtures/trino-opa-requests.json` keeps the paths it was
# captured with (that is what Trino sent); `bridge-replay.sh` maps a captured
# batch path to `BRIDGE_BATCH_PATH` while asking, so a re-capture is not needed.

# The batched entry point Trino calls: the stardelt front rule (platform#359).
BRIDGE_BATCH_PATH="${BRIDGE_BATCH_PATH:-/v1/data/stardelt/batch}"
# The single-question entry point: the same front rule, which answers the
# catalog-level questions from the decision table and hands everything else to
# the chart's `allow` (platform#359).
BRIDGE_ALLOW_PATH="${BRIDGE_ALLOW_PATH:-/v1/data/stardelt/allow}"
# The chart's own rules, asked by nobody but the differential test: they are the
# oracle `--differential` compares the front entry points against.
BRIDGE_UPSTREAM_ALLOW_PATH="${BRIDGE_UPSTREAM_ALLOW_PATH:-/v1/data/trino/allow}"
BRIDGE_UPSTREAM_BATCH_PATH="${BRIDGE_UPSTREAM_BATCH_PATH:-/v1/data/trino/batch}"
