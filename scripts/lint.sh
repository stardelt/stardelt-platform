#!/usr/bin/env bash
# Lint the repository's shell scripts.
#
#   make lint
#
# Step 1 — `bash -n`: parse-only syntax check of every shell script under scripts/ and dev/.
# Step 2 — `shellcheck`: same file set, only when ShellCheck is installed, so the target also
#          works on a bare checkout. CI installs ShellCheck, so there it always runs.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Discover shell scripts by .sh suffix or by a bash/sh shebang on the first line, so a script
# added without a suffix is still checked and a README code block is not. Sorted for stable
# output across machines.
mapfile -t scripts < <(
  find scripts dev -type f -print0 | while IFS= read -r -d '' file; do
    case "$file" in
      *.sh) printf '%s\n' "$file" ;;
      *)
        if head -n 1 -- "$file" | grep -qE '^#!.*\b(bash|sh|dash|ksh|zsh)\b'; then
          printf '%s\n' "$file"
        fi
        ;;
    esac
  done | sort -u
)

if [ "${#scripts[@]}" -eq 0 ]; then
  echo "lint: no shell scripts found under scripts/ or dev/" >&2
  exit 1
fi

echo "› bash -n: ${#scripts[@]} script(s)"
for script in "${scripts[@]}"; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "› shellcheck $(shellcheck --version | awk '/^version:/ {print $2}')"
  shellcheck "${scripts[@]}"
else
  echo "› shellcheck not installed — skipping (install ShellCheck for the full check)"
fi

# Cross-file pins that a single file cannot check: the notebook image the task pods run must be
# the image the single-user pods run (platform#316).
echo "› script: check-notebook-image-pin"
bash scripts/check-notebook-image-pin.sh

# The extra Trino catalogs are rendered from helm-values/catalog.properties.tmpl, which must stay
# the identity overlay's `warehouse` block (platform#308): drift only shows up as a property
# missing in one catalog at query time.
echo "› script: check-catalog-template"
bash scripts/check-catalog-template.sh

# The policy paths the scripts ask and the paths Trino is configured with are one value
# (platform#359): a replay that asks /v1/data/trino/batch while the engine asks
# /v1/data/stardelt/batch would pass for the wrong reason.
echo "› script: check-bridge-uri"
bash scripts/check-bridge-uri.sh

# The notebook's Spark Connect client and the platform's Spark server are one Spark
# line (platform#399): a newer client mis-parses the server's settings and every
# createDataFrame in every notebook dies with an opaque int() error.
echo "› script: check-spark-parity"
bash scripts/check-spark-parity.sh

# The notebook image installs the stardelt library from a pinned release
# (platform#417): the Dockerfile's pin and the Makefile's must be the same
# commit, and a commit — a moving tag is not an upgrade path.
echo "› script: check-stardelt-pin"
bash scripts/check-stardelt-pin.sh

echo "lint: OK"
