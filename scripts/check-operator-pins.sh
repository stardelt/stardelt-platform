#!/usr/bin/env bash
# Compare the operator's golden Airflow loader digest with this repository's pin. The two install
# paths must run the same image, but the files live in two repositories, so no CI sees both.
#
#   scripts/check-operator-pins.sh
#
# Exit codes: 0 they agree or the operator checkout is absent (CI), 1 they differ, 3 a pin unreadable.
# Needs: bash, grep.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OPERATOR_DIR="${OPERATOR_DIR:-../stardelt-operator}"
values="$OPERATOR_DIR/crates/stardelt-operator/values/airflow.yaml"

if [ ! -f "$values" ]; then
  echo "check-operator-pins: SKIP (no operator checkout at $OPERATOR_DIR)"
  exit 0
fi

digest_of() { grep -m1 -E '^[[:space:]]+digest: sha256:' "$1" | grep -oE 'sha256:[0-9a-f]{64}' || true; }

platform="$(digest_of helm-values/airflow.yaml)"
operator="$(digest_of "$values")"
if [ -z "$platform" ] || [ -z "$operator" ]; then
  echo "check-operator-pins: UNVERIFIED (a digest could not be read)" >&2
  exit 3
fi
if [ "$platform" = "$operator" ]; then
  echo "check-operator-pins: PASS (both install paths run ${platform:0:19}…)"
  exit 0
fi
echo "✗ operator ${operator:0:19}… != platform ${platform:0:19}…" >&2
echo "  files: $values  vs  helm-values/airflow.yaml" >&2
echo "  fix: bump crates/stardelt-operator/values/airflow.yaml (both occurrences) and src/values.rs" >&2
exit 1
