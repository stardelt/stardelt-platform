#!/usr/bin/env bash
# Generate the bearer token that Trino's event listener presents to Nova's internal
# collector port (stardelt-nova#116), once, against the current kube-context. Called by
# `make trino` before it installs the chart; safe to re-run.
#
#   NAMESPACE=stardelt bash scripts/nova-events-token.sh
#
# Secret `nova-events`, key `token`, is read by two pods: Trino (env NOVA_EVENTS_TOKEN,
# substituted into the event-listener header, helm-values/trino-query-log.yaml) and Nova
# (env NOVA_EVENTS_TOKEN, compared on every request to POST /internal/trino-events).
# The value is generated only when the Secret does not exist, so a re-run never rotates it.
# To rotate: delete the Secret, run this script, then restart Trino and Nova.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
NAME=nova-events

command -v openssl >/dev/null 2>&1 || { echo "nova-events-token: openssl not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "nova-events-token: kubectl not found" >&2; exit 1; }

if kubectl -n "$NAMESPACE" get secret "$NAME" >/dev/null 2>&1; then
  echo "› Secret $NAME exists — kept"
  exit 0
fi

# Hex keeps the value free of characters that need escaping in a header. The value goes
# through stdin so it never appears in a process list.
umask 077
printf '%s' "$(openssl rand -hex 32)" \
  | kubectl -n "$NAMESPACE" create secret generic "$NAME" --from-file=token=/dev/stdin >/dev/null
kubectl -n "$NAMESPACE" label secret "$NAME" app.kubernetes.io/part-of=stardelt >/dev/null
echo "› Secret $NAME created (generated)"
