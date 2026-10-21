#!/usr/bin/env bash
# Fail when helm-values/catalog.properties.tmpl has drifted from the `warehouse`
# catalog in helm-values/trino-identity.yaml.
#
#   bash scripts/check-catalog-template.sh
#
# `make trino` renders every extra Catalog from the template (scripts/render-catalogs.sh)
# and keeps `warehouse` from the identity overlay, so the two must be the same
# properties — with the name templated. Drift is silent where it matters: a
# property added to `warehouse` (a throttle, a cache setting, the OAuth2 lines
# platform#283 needed) never reaches a second catalog, and the difference shows up
# as a slower or failing query in one catalog only. The template is the identity
# overlay's block verbatim, so the block is the file to edit first.
#
# The block is the lines after `  warehouse: |` (indent 2, the `catalogs` map)
# until the next key at indent 2 or the next top-level key; the block's own lines
# carry the 4-space YAML indent, which is removed. Trailing blank lines fall
# outside the block (YAML's clip keeps one newline, not the empty line before the
# next key).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

template="helm-values/catalog.properties.tmpl"
values="helm-values/trino-identity.yaml"

for file in "$template" "$values"; do
  [ -f "$file" ] || { echo "check-catalog-template: $file is missing" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The `warehouse` block, de-indented, without the trailing empty line.
awk '
  /^  warehouse: \|$/ && !inside { inside = 1; next }
  inside && (/^[^ ]/ || /^  [^ ]/) { exit }
  inside { print }
' "$values" | sed 's/^    //' >"$tmp/raw"
awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] == "") last--; for (i = 1; i <= last; i++) print lines[i] }' \
  "$tmp/raw" >"$tmp/warehouse.properties"

# The template as `warehouse` would be rendered.
sed 's/@NAME@/warehouse/g' "$template" >"$tmp/template.properties"

if ! diff -u "$tmp/warehouse.properties" "$tmp/template.properties"; then
  echo "check-catalog-template: $template does not match the \`warehouse\` catalog in $values" >&2
  echo "  The diff above is values (-) vs template (+). Update the template to the block, with" >&2
  echo "  \`iceberg.rest-catalog.warehouse=@NAME@\` for the name — or fix the block, if the template is right." >&2
  exit 1
fi

echo "check-catalog-template: OK ($(wc -l <"$tmp/template.properties" | tr -d ' ') lines, \`warehouse\`)"
