#!/usr/bin/env bash
# Fail when a known default or demo credential is committed to the repository.
#
# The platform generates every credential at install time (scripts/s3-secrets.sh,
# scripts/identity-bootstrap.sh, the chart's `lookup` + `randAlphaNum`). A value in this
# list showing up in a tracked file means a default crept back in. Markdown is not
# scanned, so docs may still explain what used to be there.
#
#   bash scripts/check-no-default-secrets.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Fixed strings, one per line. Add the value, not a regex.
patterns=(
  'stardelt-access-key'
  'stardelt-secret-key'
  '5oYDV8KzcRrChx4tWN5gP1NQXMRr9CkBaVYU6jLDB2I='
  'do-not-use-in-prod'
  'stardelt-mvp-'
  'authenticator_class: dummy'
  'DummyAuthenticator'
  'password: admin'
)

found=0
for p in "${patterns[@]}"; do
  if git grep -n -F -e "$p" -- . ':!scripts/check-no-default-secrets.sh' ':!*.md'; then
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  echo "check-no-default-secrets: committed default credentials found (see above)." >&2
  echo "Generate the value at install time instead; see docs: operations/rotating-secrets." >&2
  exit 1
fi
echo "check-no-default-secrets: OK"
