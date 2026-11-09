#!/usr/bin/env bash
# Prove external secret store mode on a live cluster: External Secrets Operator is installed,
# a Fake-provider ClusterSecretStore is Ready, an ExternalSecret in a scratch namespace syncs,
# and the Kubernetes Secret it owns carries the value — then both scratch objects are deleted.
#
# What it proves: the mechanism of `spec.secrets.mode: external` (decision D23) — the customer's
# store is reached through External Secrets Operator and an ExternalSecret produces a Secret.
# What it does NOT prove: the Connection -> ExternalSecret translation (that is the operator's
# Connection controller, `make verify-connections` plus `make eso-stores`), the sandbox store
# (`scripts/eso-openbao-store.sh`, `make check-openbao-groups`), or any real customer store.
#
# It creates and deletes `namespace eso-verify` and `ClusterSecretStore eso-verify-fake`; the
# names are fixed so a second run converges and a leaked run is obvious. Nothing else is touched.
#
#   scripts/verify-external-secrets.sh
#
# Exit codes: 0 proved, 1 wired but broken, 3 nothing could be proved (no cluster, no ESO).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NAMESPACE="${NAMESPACE:-stardelt}"
VERIFY_NS="${VERIFY_NS:-eso-verify}"
STORE="${STORE:-eso-verify-fake}"
SECRET="${SECRET:-conn-verify}"

status=0
ok() { printf '✓ %-8s %s\n' "$1" "$2"; }
bad() { printf '✗ %-8s %s\n' "$1" "$2" >&2; status=1; }
unknown() { printf '? %-8s %s\n' "$1" "$2" >&2; status=3; }

command -v kubectl >/dev/null || {
  unknown tools "kubectl is not installed"
  echo "verify-external-secrets: UNVERIFIED (kubectl not found)" >&2
  exit 3
}

# Preconditions: do not create anything without the two CRDs the check needs.
missing=""
kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1 || missing="externalsecrets.external-secrets.io"
kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1 || missing="${missing:+$missing, }clustersecretstores.external-secrets.io"
if [ -n "$missing" ]; then
  unknown eso "External Secrets is not installed: run 'make external-secrets'"
  echo "verify-external-secrets: UNVERIFIED ($missing is not served)" >&2
  exit 3
fi
ok eso "External Secrets CRDs are served"

# Setup: converge from a leaked earlier run, then register the cleanup before creating anything.
kubectl delete ns "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl delete clustersecretstore "$STORE" --ignore-not-found >/dev/null 2>&1 || true
# --wait=false only marks the namespace: one that is still Terminating cannot be created again,
# so wait for it to be gone (a second run of this script must converge, not fail).
for _ in $(seq 1 60); do
  kubectl get ns "$VERIFY_NS" >/dev/null 2>&1 || break
  sleep 2
done
trap 'kubectl delete ns "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1; kubectl delete clustersecretstore "$STORE" --ignore-not-found >/dev/null 2>&1' EXIT

kubectl create ns "$VERIFY_NS" >/dev/null
kubectl label ns "$VERIFY_NS" stardelt.io/verify=external-secrets --overwrite >/dev/null

kubectl apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${STORE}
  labels: { stardelt.io/verify: external-secrets }
spec:
  provider:
    fake:
      data:
        - key: ${SECRET}
          value: verified
          version: v1
EOF

kubectl apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SECRET}
  namespace: ${VERIFY_NS}
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: ${STORE}
    kind: ClusterSecretStore
  target:
    name: ${SECRET}
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: ${SECRET}
        # The Fake provider keys its data by key+version and returns NoSecretErr unless the
        # requested version matches the store's, so the version is explicit on both sides.
        version: v1
EOF

# 1. The store is Ready.
store_ready=""
for _ in $(seq 1 20); do
  store_ready="$(kubectl get clustersecretstore "$STORE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
  if [ "$store_ready" = "True" ]; then break; fi
  sleep 3
done
if [ "$store_ready" = "True" ]; then
  ok store "ClusterSecretStore $STORE is Ready"
else
  why="$(kubectl get clustersecretstore "$STORE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.reason}: {.message}{end}' 2>/dev/null || true)"
  bad store "ClusterSecretStore $STORE is not Ready after 60s (${why:-no Ready condition})"
fi

# 2. The ExternalSecret synced.
sync_ready=""
for _ in $(seq 1 30); do
  sync_ready="$(kubectl -n "$VERIFY_NS" get externalsecret "$SECRET" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"|"}{.status.refreshTime}' 2>/dev/null || true)"
  case "$sync_ready" in True\|*) break ;; esac
  sleep 3
done
if [ "${sync_ready%%|*}" = "True" ] && [ -n "${sync_ready#*|}" ]; then
  ok sync "ExternalSecret $SECRET is SecretSynced"
else
  why="$(kubectl -n "$VERIFY_NS" get externalsecret "$SECRET" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.reason}: {.message}{end}' 2>/dev/null || true)"
  bad sync "ExternalSecret $SECRET did not sync within 90s (${why:-no Ready condition or no refreshTime})"
fi

# 3. The Secret it owns carries the value. (A throwaway fake value, not a credential.)
value_b64="$(kubectl -n "$VERIFY_NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null || true)"
if [ -z "$value_b64" ]; then
  bad secret "Secret $VERIFY_NS/$SECRET has no token key"
else
  value="$(printf '%s' "$value_b64" | base64 -d 2>/dev/null || true)"
  if [ "$value" = "verified" ]; then
    ok secret "Secret $VERIFY_NS/$SECRET carries token=verified"
  else
    bad secret "Secret $VERIFY_NS/$SECRET carries token=${value:-<undecodable>} (want verified)"
  fi
fi

# 4. Cleanup: the same deletions the trap does, then hand over from the trap. Wait for the
# namespace, because the line below claims it is gone and a leftover would hide the next run.
if kubectl delete ns "$VERIFY_NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1; then
  kubectl delete clustersecretstore "$STORE" --ignore-not-found >/dev/null 2>&1 || true
  trap - EXIT
  if kubectl get ns "$VERIFY_NS" >/dev/null 2>&1 || kubectl get clustersecretstore "$STORE" >/dev/null 2>&1; then
    bad cleanup "namespace $VERIFY_NS or store $STORE still exists"
  else
    ok cleanup "namespace $VERIFY_NS and store $STORE deleted"
  fi
else
  bad cleanup "namespace $VERIFY_NS could not be deleted within 120s"
fi

case "$status" in
  0) echo "verify-external-secrets: OK" ;;
  1) echo "verify-external-secrets: FAILED" >&2 ;;
  *) echo "verify-external-secrets: UNVERIFIED (a check could not be read)" >&2 ;;
esac
exit "$status"
