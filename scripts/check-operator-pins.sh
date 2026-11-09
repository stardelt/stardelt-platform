#!/usr/bin/env bash
# Compare the operator's golden image digests with this repository's pins, for every image both
# install paths share. The files live in two repositories, so no CI sees both on one revision.
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

# name|platform file|operator file (relative to the operator checkout)
images=(
  "loader|helm-values/airflow.yaml|crates/stardelt-operator/values/airflow.yaml"
  "spark|manifests/spark.yaml|crates/stardelt-operator/values/spark.yaml"
  "superset|helm-values/superset.yaml|crates/stardelt-operator/values/superset.yaml"
)

if [ ! -d "$OPERATOR_DIR" ]; then
  echo "check-operator-pins: SKIP (no operator checkout at $OPERATOR_DIR)"
  exit 0
fi

# The loader file pins with `digest: sha256:`; the Spark files carry the digest twice inside a
# `ghcr.io/stardelt/spark:dev@sha256:…` reference. Read whichever form the file has: the first
# `digest:` line, else the first `sha256:<64 hex>` match.
digest_of() {
  local d
  d="$(grep -m1 -E '^[[:space:]]+digest: sha256:' "$1" | grep -oE 'sha256:[0-9a-f]{64}' || true)"
  if [ -z "$d" ]; then
    d="$(grep -m1 -oE 'sha256:[0-9a-f]{64}' "$1" || true)"
  fi
  printf '%s\n' "$d"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

note=""
if git -C "$OPERATOR_DIR" rev-parse --git-dir >/dev/null 2>&1 &&
   git -C "$OPERATOR_DIR" rev-parse --verify --quiet origin/main >/dev/null; then
  :
else
  note=" (working tree; no origin/main)"
fi

fail=0
for image in "${images[@]}"; do
  IFS='|' read -r name platform_file operator_path <<<"$image"
  operator_file="$tmpdir/$name.yaml"
  if [ -n "$note" ] || ! git -C "$OPERATOR_DIR" show "origin/main:$operator_path" >"$operator_file"; then
    cp "$OPERATOR_DIR/$operator_path" "$operator_file"
    note=" (working tree; no origin/main)"
  fi

  platform="$(digest_of "$platform_file")"
  operator="$(digest_of "$operator_file")"
  if [ -z "$platform" ] || [ -z "$operator" ]; then
    echo "check-operator-pins: UNVERIFIED ($name: a digest could not be read in $platform_file or $OPERATOR_DIR/$operator_path)" >&2
    exit 3
  fi
  if [ "$platform" = "$operator" ]; then
    printf '✓ %-7s both install paths run %s…%s\n' "$name" "${platform:0:15}" "$note"
  else
    printf '✗ %-7s platform %s…, operator %s… (%s)%s\n' \
      "$name" "${platform:0:15}" "${operator:0:15}" "$operator_path" "$note" >&2
    echo "  fix: bump $operator_path in the operator repository" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "check-operator-pins: PASS (the operator's golden values agree with this repository's pins)"
exit 0
