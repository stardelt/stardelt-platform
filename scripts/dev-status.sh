#!/usr/bin/env bash
# Show, per stardelt image, what the cluster runs against what the manifests pin.
#
#   scripts/dev-status.sh             # namespace stardelt
#   NS=lab scripts/dev-status.sh
#
# Why: with two channels (make dev-refresh moves the cluster, make pin-images moves
# the repository) the interesting question is no longer "which version is this" but
# "is the cluster ahead of the pin, or behind it". Without this you find out by
# accident, when an install rolls the images back.
#
# Read-only: it never patches, never writes. Exit code is 0 whatever the state, so it
# can be run from a prompt or a CI step without special-casing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NS="${NS:-${NAMESPACE:-stardelt}}"
TAG="${TAG:-dev}"

command -v kubectl >/dev/null 2>&1 || { echo "dev-status: kubectl not found" >&2; exit 1; }

short() { sed -n 's/.*@sha256:\([0-9a-f]\{12\}\).*/\1/p'; }

# app | deployment | manifest | the repository the manifest names
apps=(
  "nova|nova|manifests/nova-deployment.yaml|ghcr.io/stardelt/nova"
  "spark|spark-connect|manifests/spark.yaml|ghcr.io/stardelt/spark"
  "stardelt-operator|stardelt-operator||"
)

printf '\n\033[1m› the dev cluster against the pinned manifests\033[0m  (namespace %s, tag %s)\n\n' "$NS" "$TAG"
printf '  %-20s %-14s %-14s %s\n' "app" "cluster" "pinned" "state"

ahead=0
for row in "${apps[@]}"; do
  IFS='|' read -r app deploy manifest repo <<<"$row"

  if ! kubectl -n "$NS" get deploy "$deploy" >/dev/null 2>&1; then
    printf '  %-20s %-14s %-14s %s\n' "$app" "-" "-" "not deployed"
    continue
  fi

  live="$(kubectl -n "$NS" get deploy "$deploy" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | short)"
  live="${live:-?}"

  if [ -z "$manifest" ]; then
    printf '  %-20s %-14s %-14s %s\n' "$app" "$live" "(chart)" "pinned by the chart"
    continue
  fi

  pinned="$(grep -o "$repo:$TAG@sha256:[0-9a-f]*" "$manifest" 2>/dev/null | head -1 | short)"
  pinned="${pinned:-none}"

  case "$pinned" in
    none)   state="\033[33mno pin in the manifest\033[0m" ;;
    "$live") state="in sync" ;;
    *)      state="\033[36mcluster ahead of the pin\033[0m"; ahead=$((ahead + 1)) ;;
  esac

  printf '  %-20s %-14s %-14s %b\n' "$app" "$live" "$pinned" "$state"
done

printf '\n'
if [ "$ahead" -gt 0 ]; then
  printf "  %s image(s) run newer than the pin — that is the fast channel working.\n" "$ahead"
  printf "  'make pin-images' freezes them; 'make install' would roll them back.\n"
else
  printf "  the cluster matches the manifests.\n"
fi
printf "  'make dev-refresh' moves the cluster, 'make pin-images' writes the pin.\n\n"
