#!/usr/bin/env bash
# One External Secrets store per owner group in the sandbox secret store (OpenBao, decisions D23 and
# D27, platform#220). Idempotent: it only adds or updates auth roles, roles, policies, ServiceAccounts
# and SecretStores, never deletes one. Run it after `make external-secrets` and `make openbao`.
#
#   NAMESPACE=stardelt bash scripts/eso-openbao-store.sh managed analytics finance
#
# Every name is an owner group, or the word `managed`. For each one it writes a policy and a
# Kubernetes sign-in role that may read exactly `secret/<prefix>*` (prefix `connections/group/<n>/`,
# or `connections/managed/` for `managed`), a ServiceAccount and a SecretStore that signs in as that
# role. The isolation is the role: the store of one group cannot read another group's path, even if
# an ExternalSecret names it. A SecretStore is namespaced, so the stores live in the workload
# namespace. Personal paths (`connections/user/`) never reach a Kubernetes Secret and get no role.
#
# Tokens reach the store only through stdin of `kubectl exec`, never through argv or a log line.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
POD="${POD:-openbao-0}"
CONTAINER="${CONTAINER:-openbao}"
INIT_SECRET=openbao-init

for tool in kubectl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "eso-openbao-store: $tool not found" >&2; exit 1; }
done

fail() { echo "eso-openbao-store: $*" >&2; exit 1; }
K=(kubectl -n "$NAMESPACE")

# 1. Validate every name before any kubectl call — a name with `/` or `..` would otherwise move a
# group's role to another group's path.
[ "$#" -gt 0 ] || fail "usage: NAMESPACE=<ns> $0 <owner-group|managed> [<owner-group|managed> ...]"
name_re='^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$'
for n in "$@"; do
  [[ "$n" =~ $name_re ]] \
    || fail "refusing name '$n' (lower-case letters, digits and dashes; at most 40)"
done

# bao <args...>: no token. bao_root <args...>: the root token is sent as the first line of stdin and
# exported inside the pod; anything the caller pipes in follows it.
bao() { "${K[@]}" exec -i "$POD" -c "$CONTAINER" -- env BAO_ADDR=http://127.0.0.1:8200 bao "$@"; }
bao_root() {
  { printf '%s\n' "$ROOT_TOKEN"; cat; } | "${K[@]}" exec -i "$POD" -c "$CONTAINER" -- \
    sh -c 'IFS= read -r BAO_TOKEN; export BAO_TOKEN BAO_ADDR=http://127.0.0.1:8200; exec bao "$@"' sh "$@"
}
json_get() { python3 -c 'import sys,json;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "$1"; }

ROOT_TOKEN="$("${K[@]}" get secret "$INIT_SECRET" -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)" \
  || true
[ -n "${ROOT_TOKEN:-}" ] || fail "Secret $INIT_SECRET has no root token: the store is initialised but its token is gone"

# 2. The Kubernetes sign-in method, enabled once. The chart binds the store's ServiceAccount to
# `system:auth-delegator` by default, so the method needs no reviewer token.
if bao_root auth list -format=json < /dev/null \
     | python3 -c 'import sys,json;sys.exit(0 if "kubernetes/" in json.load(sys.stdin) else 1)'; then
  :
else
  bao_root auth enable kubernetes < /dev/null >/dev/null
fi
bao_root write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc < /dev/null >/dev/null
echo "› kubernetes auth: ready"

# 3. Per name: a policy that reads only that group's prefix, the ServiceAccount bound to it, and the
# sign-in role plus SecretStore that use it.
for n in "$@"; do
  if [ "$n" = managed ]; then
    prefix="connections/managed/"
  else
    prefix="connections/group/$n/"
  fi
  printf 'path "secret/data/%s*" { capabilities = ["read"] }\n' "$prefix" \
    | bao_root policy write "eso-$NAMESPACE-$n" - >/dev/null
  bao_root write "auth/kubernetes/role/eso-$NAMESPACE-$n" \
    bound_service_account_names="eso-$n" bound_service_account_namespaces="$NAMESPACE" \
    token_policies="eso-$NAMESPACE-$n" token_ttl=15m < /dev/null >/dev/null

  "${K[@]}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-$n
  namespace: $NAMESPACE
  labels: { app.kubernetes.io/part-of: stardelt }
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: openbao-$n
  namespace: $NAMESPACE
  labels: { app.kubernetes.io/part-of: stardelt }
spec:
  provider:
    vault:
      server: http://openbao.$NAMESPACE.svc.cluster.local:8200
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso-$NAMESPACE-$n
          serviceAccountRef: { name: eso-$n }
EOF
  echo "› store openbao-$n: role eso-$NAMESPACE-$n reads only secret/$prefix"
done

echo "eso-openbao-store: OK — $*"
