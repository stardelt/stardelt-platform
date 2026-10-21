#!/usr/bin/env bash
# Render Trino catalogs and the OPA bridge's mapping from the `Catalog` objects.
#
#   bash scripts/render-catalogs.sh list        # Ready Catalogs, except `warehouse`, sorted
#   bash scripts/render-catalogs.sh trino-args  # one `--set-file` per Catalog (Trino chart)
#   bash scripts/render-catalogs.sh bridge-arg  # one `--set-json` for the OPA bridge (Lakekeeper)
#   bash scripts/render-catalogs.sh admin-arg   # one `--set-json` for the bridge's adminUsers (Lakekeeper)
#
# `make catalogs` and `make trino` call this; `make lint` never does (it needs a
# cluster). The Catalog objects are the single source of truth for what a catalog
# is (design/multitenant-catalogs.md §7.2 P2a): a `Catalog` whose `status.phase`
# is `Ready` gets a Trino catalog of the same name, pointing at the Lakekeeper
# warehouse of the same name, and an entry in the bridge's catalog map. Nothing
# here holds a list of names — the platform catalog `warehouse` is the one the
# values files carry (the identity overlay repeats its properties), and it is
# always mapped in the bridge.
#
# Why `--set-file` and not another `-f` values file: the set of catalogs is
# dynamic, so any values file would have to be generated for a release anyway.
# `--set-file` adds exactly one key on top of the two tracked values files and
# touches neither; the identity overlay stays the only place `warehouse` is
# written. (Verified with `helm template`, README "More catalogs": the `catalogs`
# map is merged key by key — a second `-f` that repeats `catalogs.warehouse`
# replaces that catalog's whole properties block, which is exactly why the
# identity overlay repeats it verbatim.) The property body comes from
# helm-values/catalog.properties.tmpl, which is the identity overlay's `warehouse`
# block with the name templated: every extra catalog also signs in to the catalog
# as `svc-catalog-trino`, because Lakekeeper refuses an anonymous caller
# (platform#285).
#
# Why the bridge needs every name too: the OPA bridge maps a *Trino* catalog name
# to a Lakekeeper warehouse before it answers an authorization question. An
# unmapped catalog falls to `allowUnmanagedCatalogs: true`, which the chart sets —
# that permits it without asking Lakekeeper, so its grants would not be enforced at
# all. `--set-json` REPLACES the array, so the argument carries `warehouse` as
# well; with nothing new the script prints nothing at all and the values file's
# static mapping stays. Only names, no ids: the bridge resolves the warehouse by
# name (the chart writes `lakekeeper_id: default`).
#
# `admin-arg` is the bridge's other list (platform#311): the Trino principals
# that are full-access administrators there — every system schema and table of
# every catalog, and `FilterViewQueryOwnedBy` for *other* people. Without it the
# bridge vetoes `stardelt-admins`, which the file rules grant, so an
# administrator's `system.runtime.queries` would only show their own queries.
# The list is the `stardelt-admins` line of ConfigMap `trino-group-file` — the
# same membership Trino itself uses, one source, no second list to drift. Its
# strings are the engine's principals: Keycloak user ids while
# `principal-field=sub` (the switch), usernames before it. `--set-json` replaces
# the array, so an empty group renders `[]` (the chart then emits no
# `TRINO_ADMIN_USERS` at all, i.e. no administrator — which is correct and must
# not be silently papered over).
#
# Files are rendered into .build/catalogs/ (git-ignored) and passed to Helm by
# relative path, so the checkout is the only state — a stale file for a deleted
# Catalog is never referenced.
#
# A name that the operator's CatalogDomainSpec::validate would reject
# (`^[a-z][a-z0-9]{0,39}$`, also the rule access-sync applies) is skipped with a
# warning on stderr, never rendered. Such a Catalog cannot be Ready, so this is a
# belt-and-braces guard against a name that would break a properties file.
#
# On a cluster without the Catalog CRD (a bare `make install-core`, no operator)
# every mode reports an empty list: `make trino` must keep working there. Only a
# missing resource type is tolerated; any other kubectl failure is fatal, so a
# broken kubeconfig does not silently render a Trino with one catalog fewer.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
TEMPLATE="helm-values/catalog.properties.tmpl"
OUT_DIR=".build/catalogs"
# Same rule as the operator (crates/stardelt-operator/src/crd.rs) and access-sync.
NAME_RE='^[a-z][a-z0-9]{0,39}$'
# The platform's first catalog: in the values files, never rendered from a Catalog.
PLATFORM_CATALOG="warehouse"
# The group whose members are the bridge's `adminUsers` (admin-arg).
ADMIN_GROUP="${ADMIN_GROUP:-stardelt-admins}"
# The group file `make trino` writes (CronJob access-sync, platform#312).
GROUP_CONFIGMAP="${GROUP_CONFIGMAP:-trino-group-file}"

mode="${1:-}"
case "$mode" in
  list|trino-args|bridge-arg|admin-arg) ;;
  *) echo "usage: render-catalogs.sh list|trino-args|bridge-arg|admin-arg" >&2; exit 2 ;;
esac

for tool in kubectl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "render-catalogs: $tool not found" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One `kubectl get` per run: the three modes only differ in what they print.
if kubectl -n "$NAMESPACE" get catalogs.stardelt.io -o json >"$tmp/catalogs.json" 2>"$tmp/err"; then
  :
elif grep -qiE "doesn't have a resource type|no matches for kind|could not find the requested resource" "$tmp/err"; then
  # No Catalog CRD (operator not installed): an empty list, not a failure.
  echo "render-catalogs: no Catalog CRD in namespace $NAMESPACE — nothing to add" >&2
  printf '{"items":[]}\n' >"$tmp/catalogs.json"
else
  cat "$tmp/err" >&2
  echo "render-catalogs: cannot list Catalogs in namespace $NAMESPACE" >&2
  exit 1
fi

# Ready Catalogs other than the platform one, sorted; names the operator would
# reject are dropped here with a warning so every mode sees one list.
names() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [[ "$name" =~ $NAME_RE ]]; then
      printf '%s\n' "$name"
    else
      echo "render-catalogs: skipping Catalog '$name' — not a catalog name ($NAME_RE)" >&2
    fi
  done < <(jq -r --arg keep "$PLATFORM_CATALOG" \
             '.items[]? | select(.status.phase == "Ready") | .metadata.name | select(. != $keep)' \
             "$tmp/catalogs.json" | sort)
}

case "$mode" in
  list)
    names
    ;;

  trino-args)
    # One line per Catalog; the Makefile's `$$(…)` word-splits each line into the
    # two arguments Helm wants (`--set-file` and `catalogs.<name>=<path>`).
    [ -f "$TEMPLATE" ] || { echo "render-catalogs: $TEMPLATE is missing" >&2; exit 1; }
    mkdir -p "$OUT_DIR"
    while IFS= read -r name; do
      sed "s/@NAME@/${name}/g" "$TEMPLATE" >"$OUT_DIR/$name.properties"
      printf -- '--set-file catalogs.%s=%s/%s.properties\n' "$name" "$OUT_DIR" "$name"
    done < <(names)
    ;;

  bridge-arg)
    # Nothing to add: print nothing, so the values file's `warehouse` mapping stays
    # and a second `make catalogs` renders the same ConfigMap (no pod restart).
    extra="$(names)"
    [ -n "$extra" ] || exit 0
    catalogs="$(printf '%s\n%s\n' "$PLATFORM_CATALOG" "$extra" \
      | jq -Rsc 'split("\n") | map(select(length > 0))
                 | map({trinoCatalog: ., lakekeeperWarehouse: .})')"
    printf -- '--set-json OPABridge.catalogs=%s\n' "$catalogs"
    ;;

  admin-arg)
    # The administrators, from the one place Trino's own group membership lives.
    # A missing ConfigMap is a cluster without the identity install (no realm, no
    # bridge): an empty list, not a failure — `make trino` has to keep working
    # there; any other kubectl error is fatal.
    if kubectl -n "$NAMESPACE" get configmap "$GROUP_CONFIGMAP" -o jsonpath='{.data.groups\.txt}' >"$tmp/groups.txt" 2>"$tmp/cm-err"; then
      :
    elif grep -qi "not found" "$tmp/cm-err"; then
      echo "render-catalogs: no ConfigMap $NAMESPACE/$GROUP_CONFIGMAP — rendering no bridge administrators" >&2
      : >"$tmp/groups.txt"
    else
      cat "$tmp/cm-err" >&2
      echo "render-catalogs: cannot read ConfigMap $NAMESPACE/$GROUP_CONFIGMAP" >&2
      exit 1
    fi
    admins="$(python3 - "$tmp/groups.txt" "$ADMIN_GROUP" <<'PY'
import json, sys
path, group = sys.argv[1:]
members = []
with open(path) as handle:
    for line in handle:
        name, _, rest = line.strip().partition(":")
        if name != group:
            continue
        members = [member for member in rest.split(",") if member]
        break
print(json.dumps(sorted(set(members))))
PY
)"
    printf -- '--set-json OPABridge.adminUsers=%s\n' "$admins"
    ;;
esac
