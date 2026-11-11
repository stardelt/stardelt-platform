#!/usr/bin/env bash
# Prove the operator path on the current cluster is actually up (fresh-node work package,
# stardelt-platform#293; platform#1017): the PlatformInstance and Lakehouse reach Ready, every
# Deployment is available, no pod is waiting to start, and Nova, Trino and the identity provider
# answer on their real ports.
#
#   scripts/verify-fresh-node.sh
#
# The lab installed with `make install` has no PlatformInstance, so there this script answers
# `? instance` and UNVERIFIED (exit 3) — that is the correct negative case, not a FAIL.
#
# Exit codes: 0 everything is up, 1 one check failed, 3 nothing can be proved.
# Needs: kubectl, curl (no python3, no jq, no repository checkout at run time).
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"
PLATFORM_INSTANCE="${PLATFORM_INSTANCE:-cluster}"
LAKEHOUSE="${LAKEHOUSE:-main}"
WAIT="${WAIT:-30m}"
PORT_WAIT_SECONDS="${PORT_WAIT_SECONDS:-15}"

status=0
ok() { printf '✓ %s %s\n' "$1" "$2"; }
bad() { printf '✗ %s %s\n' "$1" "$2" >&2; status=1; }
# `?` means "cannot be checked": it only turns a clean run into UNVERIFIED, never hides a FAIL.
unknown() {
  printf '? %s %s\n' "$1" "$2" >&2
  if [ "$status" -eq 0 ]; then
    status=3
  fi
}
# `?` that is not a doubt about the platform: an optional component that is simply not installed.
note() { printf '? %s %s\n' "$1" "$2"; }

instance_ref="platforminstance/${PLATFORM_INSTANCE}"

# --- 1. tools and context ----------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  unknown instance '"kubectl is not installed"'
  echo "verify-fresh-node: UNVERIFIED (needs kubectl and curl)" >&2
  exit 3
fi
if ! command -v curl >/dev/null 2>&1; then
  unknown instance '"curl is not installed"'
  echo "verify-fresh-node: UNVERIFIED (needs kubectl and curl)" >&2
  exit 3
fi
if ! kubectl -n "$NAMESPACE" get platforminstance "$PLATFORM_INSTANCE" >/dev/null 2>&1; then
  unknown instance "\"${instance_ref} is not readable in ${NAMESPACE}\""
  echo "verify-fresh-node: UNVERIFIED (no PlatformInstance on this cluster)" >&2
  exit 3
fi

# --- 2. the PlatformInstance is Ready -----------------------------------------------------
if kubectl -n "$NAMESPACE" wait --for=condition=Ready "$instance_ref" --timeout="$WAIT" >/dev/null 2>&1; then
  ok instance "${instance_ref} is Ready"
else
  bad instance "\"not Ready within ${WAIT}\""
fi

# --- 3. every operator component reports ready --------------------------------------------
components="$(kubectl -n "$NAMESPACE" get platforminstance "$PLATFORM_INSTANCE" \
  -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.ready}{"\n"}{end}' 2>/dev/null || true)"
component_total=0
component_names=""
component_closed=""
while IFS=$'\t' read -r name ready; do
  [ -n "$name" ] || continue
  component_total=$((component_total + 1))
  if [ -z "$component_names" ]; then
    component_names="$name"
  else
    component_names="$component_names, $name"
  fi
  if [ "$ready" != "true" ]; then
    component_closed="$component_closed $name"
  fi
done <<<"$components"
if [ "$component_total" -eq 0 ]; then
  unknown components "\"${instance_ref} reports no component\""
elif [ -z "$component_closed" ]; then
  ok components "${component_total}/${component_total} (${component_names})"
else
  bad components "\"not ready:${component_closed}\""
fi

# --- 4. the Lakehouse is Ready when the profile installs one ------------------------------
if ! kubectl -n "$NAMESPACE" get lakehouse "$LAKEHOUSE" >/dev/null 2>&1; then
  note lakehouse '"not installed"'
elif kubectl -n "$NAMESPACE" wait --for=condition=Ready "lakehouse/${LAKEHOUSE}" --timeout="$WAIT" >/dev/null 2>&1; then
  ok lakehouse "lakehouse/${LAKEHOUSE} is Ready"
else
  bad lakehouse "\"not Ready within ${WAIT}\""
fi

# --- 5. every Deployment is available -----------------------------------------------------
deploys="$(kubectl -n "$NAMESPACE" get deploy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.availableReplicas}{"\t"}{.spec.replicas}{"\n"}{end}' \
  2>/dev/null || true)"
deploy_total=0
deploy_up=0
deploy_short=()
# Fields are split by hand: `read` with a tab IFS collapses runs of tabs, which would swallow an
# empty availableReplicas (`name\t\t1`) and silently skip a Deployment that is down.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  name="${line%%$'\t'*}"
  rest="${line#*$'\t'}"
  have="${rest%%$'\t'*}"
  want="${rest#*$'\t'}"
  case "$want" in
    '' | *[!0-9]*) want=0 ;;
  esac
  # A Deployment scaled to zero on purpose is not a failure.
  if [ "$want" -eq 0 ]; then
    continue
  fi
  case "$have" in
    '' | *[!0-9]*) have=0 ;;
  esac
  deploy_total=$((deploy_total + 1))
  if [ "$have" -eq "$want" ]; then
    deploy_up=$((deploy_up + 1))
  else
    deploy_short+=("$name $have/$want")
  fi
done <<<"$deploys"
if [ "$deploy_total" -eq 0 ]; then
  unknown deploy "\"no Deployment in ${NAMESPACE}\""
elif [ "${#deploy_short[@]}" -eq 0 ]; then
  ok deploy "${deploy_up}/${deploy_total} available"
else
  for entry in "${deploy_short[@]}"; do
    bad deploy "$entry"
  done
fi

# --- 6. no pod is waiting to start --------------------------------------------------------
pods="$(kubectl -n "$NAMESPACE" get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].state.waiting.reason}{"\t"}{.status.initContainerStatuses[*].state.waiting.reason}{"\n"}{end}' \
  2>/dev/null || true)"
pod_waiting=()
while IFS=$'\t' read -r name reasons; do
  [ -n "$name" ] || continue
  for reason in CrashLoopBackOff ImagePullBackOff ErrImagePull CreateContainerConfigError; do
    case "$reasons" in
      *"$reason"*)
        pod_waiting+=("$name ($reason)")
        break
        ;;
    esac
  done
done <<<"$pods"
if [ "${#pod_waiting[@]}" -eq 0 ]; then
  ok pods "none waiting"
else
  for entry in "${pod_waiting[@]}"; do
    bad pods "$entry"
  done
fi

# --- port-forwards: one helper, one trap that kills everything the script started ----------
forward_pids=()
trap 'if [ "${#forward_pids[@]}" -gt 0 ]; then kill "${forward_pids[@]}" 2>/dev/null || true; fi' EXIT

# forward <service> <local-port> <remote-port> <probe: curl and its arguments>
# 0 the probe answered, 1 the forward stayed up but nothing answered in time, 2 it exited at once.
forward() {
  local service="$1" local_port="$2" remote_port="$3"
  shift 3
  kubectl -n "$NAMESPACE" port-forward "svc/${service}" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  local pid=$!
  forward_pids+=("$pid")
  local attempts=$((PORT_WAIT_SECONDS * 2)) tick=0
  while [ "$tick" -lt "$attempts" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 2
    fi
    if curl "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    tick=$((tick + 1))
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    return 2
  fi
  return 1
}

# says whether a forward failure is a doubt (tool half) or a failure (the Service is there).
forward_result() { # <label> <service> <rc>
  case "$3" in
    2) bad "$1" "\"port-forward to svc/$2 exited immediately\"" ;;
    *) unknown "$1" "\"no answer on svc/$2 within ${PORT_WAIT_SECONDS}s\"" ;;
  esac
}

# --- 7. Nova answers ----------------------------------------------------------------------
nova_url="http://127.0.0.1:18080/api/health"
rc=0
forward nova 18080 8080 -fsS --max-time 5 "$nova_url" || rc=$?
if [ "$rc" -ne 0 ]; then
  forward_result nova nova "$rc"
else
  body="$(curl -fsS --max-time 5 "$nova_url" 2>/dev/null || true)"
  case "$body" in
    *'"status":"ok"'*) ok nova "answers (${body})" ;;
    *) bad nova "\"health answers ${body:-nothing}\"" ;;
  esac
fi

# --- 8. Trino answers ---------------------------------------------------------------------
trino_url="https://127.0.0.1:18443/v1/info"
rc=0
forward trino 18443 8443 -ksf --max-time 5 "$trino_url" || rc=$?
if [ "$rc" -ne 0 ]; then
  forward_result trino trino "$rc"
else
  body="$(curl -ksf --max-time 5 "$trino_url" 2>/dev/null || true)"
  if printf '%s' "$body" | grep -q '"starting":false' && printf '%s' "$body" | grep -q '"coordinator":true'; then
    ok trino "answers and is a coordinator (${body})"
  else
    bad trino "\"is not an active coordinator: ${body:-nothing}\""
  fi
fi

# --- 9. the identity provider answers -----------------------------------------------------
oidc_url="http://127.0.0.1:18081/realms/stardelt/.well-known/openid-configuration"
rc=0
forward keycloak 18081 8080 -fsS --max-time 5 "$oidc_url" || rc=$?
if [ "$rc" -ne 0 ]; then
  forward_result keycloak keycloak "$rc"
else
  body="$(curl -fsS --max-time 5 "$oidc_url" 2>/dev/null || true)"
  if printf '%s' "$body" | grep -q '"issuer"' && printf '%s' "$body" | grep -q '/realms/stardelt'; then
    ok keycloak "answers on realm stardelt"
  else
    bad keycloak "\"realm stardelt does not answer: ${body:-nothing}\""
  fi
fi

# --- 10. what a person still has to do (never part of the exit code) -----------------------
domain="${BASE_DOMAIN:-}"
if [ -z "$domain" ]; then
  domain="$(kubectl -n "$NAMESPACE" get platforminstance "$PLATFORM_INSTANCE" \
    -o jsonpath='{.spec.baseDomain}' 2>/dev/null || true)"
fi
if [ -z "$domain" ]; then
  domain="<base domain>"
fi
cat <<EOF

the fresh-node run still needs a person (not checked here):
  1. sign in at https://nova.${domain} as the realm admin (Secret stardelt-realm-admin)
  2. a Trino query answers in Nova's SQL editor
  3. a second group is refused a table it has no grant for
  4. a scheduled pipeline runs and its log shows in Nova; a notebook publishes
EOF

case "$status" in
  0) echo "verify-fresh-node: PASS (the operator path is up in ${NAMESPACE})" ;;
  1) echo "verify-fresh-node: FAIL (a check above is short)" >&2 ;;
  *) echo "verify-fresh-node: UNVERIFIED (a check could not be made)" >&2 ;;
esac
exit "$status"
