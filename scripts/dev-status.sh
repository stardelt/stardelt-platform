#!/usr/bin/env bash
# Show, per stardelt image, what the cluster runs against what the manifests pin.
#
#   scripts/dev-status.sh             # namespace stardelt
#   NS=lab scripts/dev-status.sh
#   NO_REGISTRY=1 scripts/dev-status.sh   # do not ask the registry (offline)
#
# Why: with two channels (make dev-refresh moves the cluster, make pin-images moves
# the repository) the interesting question is no longer "which version is this" but
# "does what runs belong to a channel at all". "Different from the pin" alone cannot
# answer that: it is the same output for a cluster that is ahead (the fast channel
# working) and for one that runs a build nobody pinned (a rollback, or a sha- tag
# someone left behind). So the registry's current digest of the tag is the third
# point, and only "cluster == tag != pin" counts as ahead.
#
# Read-only: it never patches, never writes. Exit code is 0 whatever the state, so it
# can be run from a prompt or a CI step without special-casing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NS="${NS:-${NAMESPACE:-stardelt}}"
TAG="${TAG:-dev}"

command -v kubectl >/dev/null 2>&1 || { echo "dev-status: kubectl not found" >&2; exit 1; }

short() { sed -n 's/.*sha256:\([0-9a-f]\{12\}\).*/\1/p'; }

# app | deployment | manifest | the repository the manifest names
apps=(
  "nova|nova|manifests/nova-deployment.yaml|ghcr.io/stardelt/nova"
  "spark|spark-connect|manifests/spark.yaml|ghcr.io/stardelt/spark"
  "stardelt-operator|stardelt-operator||"
)

printf '\n\033[1m› the dev cluster against the pinned manifests\033[0m  (namespace %s, tag %s)\n\n' "$NS" "$TAG"
printf '  %-20s %-14s %-14s %s\n' "app" "cluster" "pinned" "state"

ahead=0 other=0
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

  # What the channel resolves to right now. Skipped with NO_REGISTRY=1, and harmless
  # when the registry is unreachable: the state then says it does not know.
  latest=""
  if [ "${NO_REGISTRY:-0}" != "1" ] && [ "$pinned" != "none" ]; then
    latest="$(PRINT_DIGEST=1 APP="$app" NS="$NS" TAG="$TAG" bash scripts/pin-image.sh 2>/dev/null | short || true)"
  fi

  if [ "$pinned" = "none" ]; then
    state="\033[33mno pin in the manifest\033[0m"
  elif [ "$live" = "$pinned" ]; then
    state="in sync"
  elif [ -n "$latest" ] && [ "$live" = "$latest" ]; then
    state="\033[36mahead of the pin (fast channel)\033[0m"; ahead=$((ahead + 1))
  elif [ -n "$latest" ]; then
    state="\033[31mdiffers from the pin AND from $TAG\033[0m"; other=$((other + 1))
  else
    state="differs from the pin (registry not asked)"; ahead=$((ahead + 1))
  fi

  printf '  %-20s %-14s %-14s %b\n' "$app" "$live" "$pinned" "$state"
done

printf '\n'
if [ "$other" -gt 0 ]; then
  printf "  \033[31m%s image(s) match neither the pin nor %s.\033[0m That is not the fast\n" "$other" "$TAG"
  printf "  channel: it is a rollback, or a sha- tag someone left on the Deployment.\n"
  printf "  'make dev-refresh' puts it back on %s, 'make pin-images' pins what runs.\n" "$TAG"
elif [ "$ahead" -gt 0 ]; then
  printf "  %s image(s) run newer than the pin — that is the fast channel working.\n" "$ahead"
  printf "  'make pin-images' freezes them; 'make install' would roll them back.\n"
else
  printf "  the cluster matches the manifests.\n"
fi
printf "  'make dev-refresh' moves the cluster, 'make pin-images' writes the pin.\n\n"
