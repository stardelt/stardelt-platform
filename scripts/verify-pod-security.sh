#!/usr/bin/env bash
# Every running pod is admitted by a `restricted` Pod Security namespace (#1096 question 5).
#
#   NS=stardelt bash scripts/verify-pod-security.sh --allow '^seaweedfs-' --allow '^lakekeeper-'
#
# Read-only for the platform: each live pod's spec is re-admitted with a server-side dry run into a
# scratch namespace labelled `pod-security.kubernetes.io/enforce=restricted`, which is deleted
# again. `--allow <regex>` names a pod that is a known exception; the reason belongs in the comment
# beside the flag in the Makefile. A pattern that matches no refusal is reported (drop it), and a
# refusal outside the list fails the run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS="${NS:-${NAMESPACE:-stardelt}}"
PROBE="${POD_SECURITY_PROBE_NS:-stardelt-pss-probe}"
allow=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allow) allow+=("${2:?--allow needs a regular expression}"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v kubectl >/dev/null 2>&1 || { echo "UNVERIFIED (kubectl not found)"; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "UNVERIFIED (jq not found)"; exit 3; }
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
  kubectl delete namespace "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT
# A previous run killed before its trap: remove what it left, then wait until it is really gone.
kubectl delete namespace "$PROBE" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl create namespace "$PROBE" >/dev/null
kubectl label namespace "$PROBE" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest >/dev/null

total=0 passed=0 failed=0 allowed=0
: > "$tmp/allowed"
: > "$tmp/refused"

for pod in $(kubectl -n "$NS" get pods -o json \
    | jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | sort); do
  total=$((total + 1))
  # The pod spec as the API server sees it, with only what a scratch namespace cannot carry
  # removed: its identity, the node it is pinned to, and a priority class it may not have.
  kubectl -n "$NS" get pod "$pod" -o json \
    | jq --arg name "probe-$total" --arg ns "$PROBE" '
        .metadata = {name: $name, namespace: $ns}
        | .spec.serviceAccountName = "default"
        | del(.status, .spec.nodeName, .spec.priorityClassName)
      ' > "$tmp/pod.json"
  if kubectl -n "$PROBE" create --dry-run=server -f "$tmp/pod.json" >/dev/null 2>"$tmp/err"; then
    passed=$((passed + 1))
    continue
  fi
  reason="$(grep -o 'violates PodSecurity "restricted:latest": .*' "$tmp/err" | head -1 | cut -c1-200)"
  [ -n "$reason" ] || reason="$(head -1 "$tmp/err")"
  matched=""
  for pattern in ${allow[@]+"${allow[@]}"}; do
    if printf '%s\n' "$pod" | grep -Eq "$pattern"; then matched="$pattern"; break; fi
  done
  if [ -n "$matched" ]; then
    allowed=$((allowed + 1))
    printf '%s\t%s\n' "$pod" "$matched" >> "$tmp/allowed"
    echo "– $pod: known exception ($matched)"
  else
    failed=$((failed + 1))
    printf '%s\t%s\n' "$pod" "$reason" >> "$tmp/refused"
    echo "✗ $pod: $reason"
  fi
done

for pattern in ${allow[@]+"${allow[@]}"}; do
  if ! grep -Fq "$pattern" "$tmp/allowed"; then
    echo "note: --allow '$pattern' matched no refusal; drop it from the Makefile"
  fi
done

if [ "$failed" -gt 0 ]; then
  echo "FAIL ($passed of $total pods admitted, $failed refused, $allowed known exceptions)"
  exit 1
fi
if [ "$passed" -lt 5 ]; then
  echo "UNVERIFIED ($passed of $total pods admitted; install the platform first)"
  exit 3
fi
echo "PASS ($passed of $total pods admitted by restricted, $allowed known exceptions)"
