#!/usr/bin/env bash
# A throwaway single-node cluster on Hetzner Cloud, for a fresh-node run.
#
#   bash dev/hetzner-k3s/fresh-node.sh up     # create, wait for the node, print the kubeconfig
#   bash dev/hetzner-k3s/fresh-node.sh down   # delete it again
#
# The dev cluster's config (dev/hetzner-k3s/cluster.yaml) is the only record `make dev-down`
# has of what to delete, and the dev DNS belongs to whoever runs alpha.dev: this wrapper
# therefore renders its own config (.fresh-<name>.yaml), never updates DNS, and refuses any
# cluster name that is not `stardelt-fresh-*`. It never reads or writes cluster.yaml
# (platform#1018).
#
# Environment: FRESH_NAME, FRESH_CONFIG, FRESH_KUBECONFIG, FRESH_NODE_TYPE,
# FRESH_WAIT_SECONDS, KEEP_ON_FAILURE, NO_WAIT, DRY_RUN (passed through to provision.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only a throwaway cluster may reach provision.sh/destroy.sh from here.
FRESH_PATTERN='^stardelt-fresh-[a-z0-9-]+$'

FRESH_NAME="${FRESH_NAME:-stardelt-fresh-$(date -u +%Y%m%d%H%M%S)}"
FRESH_CONFIG="${FRESH_CONFIG:-$HERE/.fresh-${FRESH_NAME}.yaml}"
FRESH_KUBECONFIG="${FRESH_KUBECONFIG:-$HOME/.kube/${FRESH_NAME}.yaml}"
# 16 GB: the `demo` profile (Airflow + Superset) does not fit a 8 GB cx33.
FRESH_NODE_TYPE="${FRESH_NODE_TYPE:-cx43}"
FRESH_WAIT_SECONDS="${FRESH_WAIT_SECONDS:-600}"
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
NO_WAIT="${NO_WAIT:-0}"
DRY_RUN="${DRY_RUN:-0}"
IN_CLEANUP=0

usage() {
  echo "usage: fresh-node.sh up|down" >&2
  echo "  up    create a throwaway cluster (DRY_RUN=1 prints the plan only)" >&2
  echo "  down  delete it, together with its config and kubeconfig" >&2
}

# A name that is not ours is never touched: this keeps `stardelt-dev` out of this path even
# when the caller passes it explicitly.
refuse_foreign_name() {
  local name="$1"
  if [[ ! "$name" =~ $FRESH_PATTERN ]]; then
    echo "refusing: '${name}' is not a throwaway cluster name (${FRESH_PATTERN})" >&2
    return 1
  fi
}

do_down() {
  refuse_foreign_name "$FRESH_NAME" || exit 1
  if [ ! -f "$FRESH_CONFIG" ]; then
    echo "nothing to delete: ${FRESH_CONFIG} does not exist"
    return 0
  fi
  local name
  name="$(awk -F': *' '/^cluster_name:/ { print $2; exit }' "$FRESH_CONFIG")"
  if ! refuse_foreign_name "$name"; then
    echo "  ${FRESH_CONFIG} describes cluster '${name}' — not deleting it." >&2
    exit 1
  fi
  CLUSTER_NAME="$name" CLUSTER_CONFIG="$FRESH_CONFIG" FORCE=1 REMOVE_DNS=0 DRY_RUN="$DRY_RUN" \
    bash "$HERE/destroy.sh"
  if [ "$DRY_RUN" != 1 ]; then
    rm -f "$FRESH_CONFIG" "$FRESH_KUBECONFIG"
  fi
}

# Any failure after the cluster starts being created deletes it again: a half-built throwaway
# node bills by the hour and nobody knows its name. KEEP_ON_FAILURE=1 keeps it for a look.
on_error() {
  local status="$1"
  if [ "$IN_CLEANUP" = 0 ] && [ "$KEEP_ON_FAILURE" = 0 ]; then
    IN_CLEANUP=1
    echo "✗ up failed (status ${status}) — deleting the throwaway node" >&2
    if ! do_down; then
      echo "  delete failed — run 'bash dev/hetzner-k3s/fresh-node.sh down'" >&2
    fi
  fi
  exit "$status"
}

do_up() {
  refuse_foreign_name "$FRESH_NAME" || exit 1
  if [ -e "$FRESH_CONFIG" ]; then
    echo "refusing: ${FRESH_CONFIG} exists — run 'fresh-node.sh down' first" >&2
    exit 1
  fi

  trap 'on_error $?' ERR
  CLUSTER_NAME="$FRESH_NAME" \
    CLUSTER_CONFIG="$FRESH_CONFIG" \
    KUBECONFIG_PATH="$FRESH_KUBECONFIG" \
    NODE_TYPE="$FRESH_NODE_TYPE" \
    DNS_UPDATE=0 \
    DRY_RUN="$DRY_RUN" \
    bash "$HERE/provision.sh"

  # A dry run only prints: there is no node to wait for and no kubeconfig to export.
  if [ "$DRY_RUN" = 1 ]; then exit 0; fi

  if [ "$NO_WAIT" != 1 ]; then
    echo "› waiting up to ${FRESH_WAIT_SECONDS}s for the node to become Ready"
    kubectl --kubeconfig "$FRESH_KUBECONFIG" wait --for=condition=Ready nodes --all \
      --timeout="${FRESH_WAIT_SECONDS}s"
  fi

  echo
  echo "✓ fresh node ${FRESH_NAME}"
  echo "  export KUBECONFIG=\"${FRESH_KUBECONFIG}\""
  echo "  operator: helm upgrade --install stardelt-operator <operator repo>/chart -n stardelt --create-namespace"
  echo "  delete:   bash dev/hetzner-k3s/fresh-node.sh down"
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  *)
    usage
    exit 2
    ;;
esac
