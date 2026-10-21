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

echo "lint: OK"
