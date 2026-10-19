#!/usr/bin/env bash
# Generate the static auto-unseal key of the sandbox secret store (OpenBao, platform#160), once,
# against the current kube-context. Called by `make openbao` before it installs the chart; safe to
# re-run.
#
#   NAMESPACE=stardelt bash scripts/openbao-seal-key.sh
#
# Secret `openbao-seal-key`, key `key`: 64 hex characters (32 random bytes), mounted into the
# OpenBao pod (helm-values/openbao.yaml). It is generated only when the Secret does not exist.
# LOSING OR CHANGING IT MAKES THE STORE'S DATA UNREADABLE: never delete this Secret while the
# volume of the OpenBao pod exists, and never rotate it by re-running with another value.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
NAME=openbao-seal-key

command -v openssl >/dev/null 2>&1 || { echo "openbao-seal-key: openssl not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "openbao-seal-key: kubectl not found" >&2; exit 1; }

if kubectl -n "$NAMESPACE" get secret "$NAME" >/dev/null 2>&1; then
  echo "› Secret $NAME exists — kept"
  exit 0
fi

# Through stdin, so the value never appears in a process list.
umask 077
printf '%s' "$(openssl rand -hex 32)" \
  | kubectl -n "$NAMESPACE" create secret generic "$NAME" --from-file=key=/dev/stdin >/dev/null
kubectl -n "$NAMESPACE" label secret "$NAME" app.kubernetes.io/part-of=stardelt >/dev/null
echo "› Secret $NAME created (generated)"
