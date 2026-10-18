#!/usr/bin/env bash
# Fail when the chart pins in the root Makefile and in chart/Chart.yaml disagree.
#
# The Makefile (`<COMPONENT>_VERSION := x.y.z`) is the source of truth for the
# bash install path; chart/Chart.yaml mirrors it for the umbrella chart. The
# operator pins the same versions in its own repo (stardelt-operator CI checks
# those against this Makefile).
#
#   bash scripts/check-version-parity.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Makefile variable prefix -> chart name in Chart.yaml
declare -A CHART_OF=(
  [CNPG]=cloudnative-pg
  [SEAWEEDFS]=seaweedfs
  [LAKEKEEPER]=lakekeeper
  [TRINO]=trino
  [AIRFLOW]=airflow
  [SUPERSET]=superset
  [JUPYTERHUB]=jupyterhub
)

# chart_yaml_version <chart> — version of the dependency with that name.
chart_yaml_version() {
  awk -v want="$1" '
    $1 == "-" && $2 == "name:" { name = $3; next }
    $1 == "name:"              { name = $2; next }
    $1 == "version:" && name == want { print $2; exit }
  ' chart/Chart.yaml
}

status=0
while IFS= read -r prefix; do
  chart="${CHART_OF[$prefix]}"
  make_version="$(sed -n "s/^${prefix}_VERSION[[:space:]]*:=[[:space:]]*\([^[:space:]#]*\).*/\1/p" Makefile)"
  yaml_version="$(chart_yaml_version "$chart")"
  if [[ -z "$make_version" || -z "$yaml_version" ]]; then
    echo "✗ $chart: missing pin (Makefile='${make_version}', Chart.yaml='${yaml_version}')" >&2
    status=1
  elif [[ "$make_version" != "$yaml_version" ]]; then
    echo "✗ $chart: Makefile pins $make_version but chart/Chart.yaml pins $yaml_version" >&2
    status=1
  else
    echo "✓ $chart $make_version"
  fi
done < <(printf '%s\n' "${!CHART_OF[@]}" | sort)
exit "$status"
