#!/usr/bin/env bash
# Prove the bridge's catalog decision table policy against a stub Lakekeeper
# (stardelt-platform#359).
#
#   bash scripts/test-bridge-policies.sh        # or: make test-bridge-policies
#
# The policy under test is not a copy: this renders the Lakekeeper chart with
# helm-values/lakekeeper.yaml exactly as `make catalog-authz` installs it and
# extracts the `lakekeeper-opa-policies` ConfigMap, so the chart's own rules and
# both stardelt files are what `opa eval` sees. scripts/tests/test_bridge_policies.py
# then runs a stub Lakekeeper (token endpoint, warehouse config, and a
# batch-check that implements Lakekeeper's relations and its implication table)
# and asks the policy every question the tests describe — with the real OPA
# engine, so `http.send`, `time.now_ns()` and the cache behave as in the cluster,
# and every Lakekeeper call is counted.
#
# What it proves (ticket #359, step 5): a fresh table answers the catalog-level
# questions without a single Lakekeeper call, in both directions; a stale table,
# a missing table, drift, and every object-level denial fall through to the
# chart's rules; the verb implications (write => select => browse, create =>
# browse, select not=> write), the admin list and the static assignee `superset`
# behave; and for every question the front entry points answer exactly what the
# chart's own `allow`/`batch` answer.
#
# Needs `helm` with the lakekeeper repo (`helm repo add lakekeeper
# https://lakekeeper.github.io/lakekeeper-charts/`) and the `opa` binary
# (`OPA=/path/to/opa`, else `opa` in PATH). CI downloads OPA 1.16.1 — see
# .github/workflows/ci.yml.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
# The chart version the cluster runs (Makefile <COMPONENT>_VERSION, checked
# against chart/Chart.yaml by scripts/check-version-parity.sh).
LAKEKEEPER_VERSION="${LAKEKEEPER_VERSION:-$(sed -n 's/^LAKEKEEPER_VERSION *:= *//p' Makefile | head -1)}"
OPA="${OPA:-opa}"
OUT_DIR=".build/bridge-policies"

# The test layout: the catalogs the harness asks about (Trino name = Lakekeeper
# warehouse, like render-catalogs.sh renders them). `system` and `tpch` are
# deliberately absent — they are Trino's own, unmanaged, and must keep costing
# nothing.
CATALOGS='[{"trinoCatalog":"warehouse","lakekeeperWarehouse":"warehouse"},
{"trinoCatalog":"gold","lakekeeperWarehouse":"gold"},
{"trinoCatalog":"silver","lakekeeperWarehouse":"silver"}]'

fail() { echo "test-bridge-policies: $*" >&2; exit 1; }

command -v helm >/dev/null 2>&1 || fail "helm not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v "$OPA" >/dev/null 2>&1 \
  || fail "the opa binary is not on PATH (set OPA=/path/to/opa; CI downloads 1.16.1)"
[ -n "$LAKEKEEPER_VERSION" ] || fail "cannot read LAKEKEEPER_VERSION from the Makefile"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

rendered="$(mktemp)"
helm_log="$(mktemp)"
trap 'rm -f "$rendered" "$helm_log"' EXIT

helm template lakekeeper lakekeeper/lakekeeper \
  --version "$LAKEKEEPER_VERSION" \
  --namespace "$NAMESPACE" \
  -f helm-values/lakekeeper.yaml \
  --set-json "OPABridge.catalogs=$CATALOGS" >"$rendered" 2>"$helm_log" \
  || { cat "$helm_log" >&2; fail "helm template failed (is the lakekeeper repo added?)"; }

python3 - "$rendered" "$OUT_DIR" <<'PY'
import os
import sys

import yaml

rendered, out_dir = sys.argv[1], sys.argv[2]
docs = [doc for doc in yaml.safe_load_all(open(rendered, encoding="utf-8")) if doc]
maps = [
    doc
    for doc in docs
    if doc.get("kind") == "ConfigMap"
    and doc["metadata"]["name"] == "lakekeeper-opa-policies"
]
if len(maps) != 1:
    sys.exit("expected exactly one lakekeeper-opa-policies ConfigMap, found %d" % len(maps))
policies = maps[0].get("data") or {}
for name in ("stardelt.front.rego", "trino.stardelt.rego", "catalogs.rego", "trino.main.rego"):
    if name not in policies:
        sys.exit("the rendered policies have no %s" % name)
for name, body in policies.items():
    with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
        handle.write(body)
print("rendered %d policy file(s) from the chart" % len(policies))
PY

# `opa check` first: a broken bundle must say so in one line, not in 40 evals.
"$OPA" check "$OUT_DIR" || fail "the rendered policy bundle does not compile"

BRIDGE_POLICY_DIR="$OUT_DIR" OPA="$OPA" \
  python3 -m unittest discover -s scripts/tests -p 'test_bridge_policies.py' -v
