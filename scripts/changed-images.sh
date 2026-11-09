#!/usr/bin/env bash
# Print, one per line, which of the platform-built images changed between two commits:
# superset, jupyter, spark.
#
# Usage: bash scripts/changed-images.sh <base-sha> [<head-sha>]
#
# An empty or all-zero base (a new branch, a tag push) and a base git cannot diff
# (a force push) both mean "all three": a missing build is worse than a redundant one.
# A change to the workflow itself also means all three. See stardelt-platform#756.
set -euo pipefail

base="${1:-}"
head="${2:-HEAD}"
all="superset
jupyter
spark"

if [ -z "$base" ] || [ "$base" = "0000000000000000000000000000000000000000" ]; then
  printf '%s\n' "$all"
  exit 0
fi

if ! changed="$(git diff --name-only "$base" "$head" 2>/dev/null)"; then
  printf '%s\n' "$all"
  exit 0
fi

if printf '%s\n' "$changed" | grep -qx '.github/workflows/image.yml'; then
  printf '%s\n' "$all"
  exit 0
fi

for name in $all; do
  if printf '%s\n' "$changed" | grep -q "^images/$name/"; then
    printf '%s\n' "$name"
  fi
done
