#!/usr/bin/env bash
# The notebook image's stardelt library pin must be the pin the Makefile states.
#
#   bash scripts/check-stardelt-pin.sh
#
# The notebook helper (stardelt/stardelt-python) has its own repository, its own
# releases and its own tests; the platform consumes one pinned release of it
# (platform#417). Two places carry that pin:
#
#   - the Makefile: STARDELT_LIB_REF, the source of truth (STARDELT_LIB_TAG
#     names the release the commit belongs to, for humans);
#   - the Dockerfile: the default of the STARDELT_LIB_REF build arg, so a plain
#     `docker build` installs the same commit.
#
# They must be the same commit, the commit must be a full SHA — a moving tag is
# not an upgrade path, the same rule the image pins follow (scripts/pin-image.sh)
# — and the Dockerfile must install *that* ref rather than a second, hardcoded
# copy of it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

makefile="Makefile"
dockerfile="images/jupyter/Dockerfile"

# The Makefile's variables: `STARDELT_LIB_REF := <sha>`.
makefile_ref=$(sed -n 's/^STARDELT_LIB_REF[[:space:]]*:*=[[:space:]]*//p' "$makefile" | head -1)
makefile_tag=$(sed -n 's/^STARDELT_LIB_TAG[[:space:]]*:*=[[:space:]]*//p' "$makefile" | head -1)

# The Dockerfile's pin: the build arg's default, `ARG STARDELT_LIB_REF=<sha>`.
dockerfile_ref=$(sed -n 's/^ARG[[:space:]]\{1,\}STARDELT_LIB_REF=//p' "$dockerfile" | head -1)

# The comment block right above the pin: it names the release the commit is.
dockerfile_comment=$(awk '
  /^#/ { block = block $0 "\n"; next }
  { if (index($0, "ARG STARDELT_LIB_REF=")) { printf "%s", block; exit } block = "" }
' "$dockerfile")

if [ -z "$makefile_ref" ]; then
  echo "check-stardelt-pin: no STARDELT_LIB_REF in $makefile" >&2
  exit 1
fi
if [ -z "$makefile_tag" ]; then
  echo "check-stardelt-pin: no STARDELT_LIB_TAG in $makefile" >&2
  exit 1
fi
if [ -z "$dockerfile_ref" ]; then
  echo "check-stardelt-pin: no STARDELT_LIB_REF build arg in $dockerfile" >&2
  exit 1
fi

for pin in "$makefile_ref" "$dockerfile_ref"; do
  if [[ ! "$pin" =~ ^[0-9a-f]{40}$ ]]; then
    echo "check-stardelt-pin: the pin is not a full commit SHA: ${pin}" >&2
    echo "  A moving tag is not an upgrade path: pin the commit (scripts/pin-image.sh says" >&2
    echo "  the same about image tags)." >&2
    exit 1
  fi
done

if [ "$makefile_ref" != "$dockerfile_ref" ]; then
  echo "check-stardelt-pin: the Makefile pins the library at ${makefile_ref}" >&2
  echo "check-stardelt-pin: but $dockerfile installs ${dockerfile_ref}." >&2
  echo "  They must be the same commit: bump STARDELT_LIB_REF in the Makefile and the" >&2
  echo "  ARG default in the Dockerfile together." >&2
  exit 1
fi

# The install must use the build arg. A commit written into the pip line would
# outlive the Makefile's pin silently — the ARG would still look right.
# The literal `${STARDELT_LIB_REF}` is what the Dockerfile must contain.
# shellcheck disable=SC2016
if ! grep -q 'stardelt @ git+https://github.com/stardelt/stardelt-python@${STARDELT_LIB_REF}' "$dockerfile"; then
  echo "check-stardelt-pin: $dockerfile does not install the library at \${STARDELT_LIB_REF}" >&2
  exit 1
fi

# One commit in the Dockerfile: the ARG default and nothing else.
sha_count=$(grep -c -oE '[0-9a-f]{40}' "$dockerfile" || true)
if [ "$sha_count" != "1" ]; then
  echo "check-stardelt-pin: $dockerfile names ${sha_count} commit SHAs — exactly one (the ARG default) is expected." >&2
  exit 1
fi

# The release the commit belongs to is named next to the pin, so a reader knows
# which version the image ships without counting commits.
case "$dockerfile_comment" in
  *"$makefile_tag"*) ;;
  *)
    echo "check-stardelt-pin: the comment above the pin in $dockerfile does not name the" >&2
    echo "  release ${makefile_tag} (STARDELT_LIB_TAG in $makefile)." >&2
    exit 1
    ;;
esac

echo "check-stardelt-pin: OK (${makefile_tag} @ ${makefile_ref})"
