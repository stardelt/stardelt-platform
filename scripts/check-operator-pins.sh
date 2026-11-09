#!/usr/bin/env bash
# Compare the operator's golden Airflow loader digest with this repository's pin. The two install
# paths must run the same image, but the files live in two repositories, so no CI sees both.
#
#   scripts/check-operator-pins.sh
#
# The operator side is read from `origin/main` of the operator checkout, not from its working tree:
# the pin must be judged on the same revision the images come from, so a checkout that is one merge
# behind does not report a false mismatch (stardelt-platform#734). A checkout without an
# `origin/main` ref (tarball, shallow clone) falls back to the working tree and says so.
#
# Exit codes: 0 they agree or the operator checkout is absent (CI), 1 they differ, 3 a pin unreadable.
# Needs: bash, git, grep.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OPERATOR_DIR="${OPERATOR_DIR:-../stardelt-operator}"
operator_path="crates/stardelt-operator/values/airflow.yaml"
values="$OPERATOR_DIR/$operator_path"

if [ ! -f "$values" ]; then
  echo "check-operator-pins: SKIP (no operator checkout at $OPERATOR_DIR)"
  exit 0
fi

digest_of() { grep -m1 -E '^[[:space:]]+digest: sha256:' "$1" | grep -oE 'sha256:[0-9a-f]{64}' || true; }

operator_file="$values"
pass_note=" (working tree; no origin/main)"
fail_note="$pass_note"
if git -C "$OPERATOR_DIR" rev-parse --git-dir >/dev/null 2>&1 &&
   git -C "$OPERATOR_DIR" rev-parse --verify --quiet origin/main >/dev/null; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  if git -C "$OPERATOR_DIR" show "origin/main:$operator_path" >"$tmp"; then
    operator_file="$tmp"
    pass_note="; operator at origin/main $(git -C "$OPERATOR_DIR" rev-parse --short origin/main)"
    fail_note=""
  fi
fi

platform="$(digest_of helm-values/airflow.yaml)"
operator="$(digest_of "$operator_file")"
if [ -z "$platform" ] || [ -z "$operator" ]; then
  echo "check-operator-pins: UNVERIFIED (a digest could not be read)" >&2
  exit 3
fi
if [ "$platform" = "$operator" ]; then
  echo "check-operator-pins: PASS (both install paths run ${platform:0:19}…${pass_note})"
  exit 0
fi
echo "✗ operator ${operator:0:19}… != platform ${platform:0:19}…${fail_note}" >&2
echo "  files: $values  vs  helm-values/airflow.yaml" >&2
echo "  fix: bump crates/stardelt-operator/values/airflow.yaml (both occurrences) and src/values.rs" >&2
exit 1
