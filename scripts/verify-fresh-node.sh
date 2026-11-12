#!/usr/bin/env bash
# Prove the operator path on the current cluster is actually up (fresh-node work package,
# stardelt-platform#293; platform#1017), and optionally walk it through its lifecycle
# (platform#1019): the PlatformInstance and Lakehouse reach Ready, every Deployment is
# available, no pod is waiting to start, and Nova, Trino and the identity provider answer on
# their real ports.
#
#   scripts/verify-fresh-node.sh            # the readiness checks
#   scripts/verify-fresh-node.sh upgrade    # …then upgrade the operator image and check it converges
#   scripts/verify-fresh-node.sh delete     # …then delete the PlatformInstance and check D18
#
# `upgrade` and `delete` run the readiness checks first and stop when one of them fails: a
# lifecycle phase proves nothing about a platform that is not up.
#
# The lab installed with `make install` has no PlatformInstance, so there every phase answers
# `? instance` and UNVERIFIED (exit 3) — that is the correct negative case, not a FAIL.
#
# Exit codes: 0 everything is up (and the phase passed), 1 one check failed, 3 nothing can be
# proved. A phase that refuses to run (nothing to upgrade) also exits 3.
# Needs: kubectl, curl, helm (upgrade only); no python3, no jq, no repository checkout at run
# time.
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"
PLATFORM_INSTANCE="${PLATFORM_INSTANCE:-cluster}"
LAKEHOUSE="${LAKEHOUSE:-main}"
WAIT="${WAIT:-30m}"
PORT_WAIT_SECONDS="${PORT_WAIT_SECONDS:-15}"

# phase `upgrade`
OPERATOR_RELEASE="${OPERATOR_RELEASE:-stardelt-operator}"
OPERATOR_DEPLOY="${OPERATOR_DEPLOY:-stardelt-operator}"
OPERATOR_CHART="${OPERATOR_CHART:-}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-}"
UPGRADE_WAIT="${UPGRADE_WAIT:-10m}"

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

# --- readiness() --------------------------------------------------------------------------
# The checks of platform#1017. Prints one line per check and returns 0 (all good), 1 (a check
# failed) or 3 (a check could not be made). `upgrade` and `delete` call this again after their
# step, so there is one definition of "the platform is up".
readiness() {
  status=0

  # 1. tools and context
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

  # 2. the PlatformInstance is Ready
  if kubectl -n "$NAMESPACE" wait --for=condition=Ready "$instance_ref" --timeout="$WAIT" >/dev/null 2>&1; then
    ok instance "${instance_ref} is Ready"
  else
    bad instance "\"not Ready within ${WAIT}\""
  fi

  # 3. every operator component reports ready
  local components component_total component_names component_closed name ready
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

  # 4. the Lakehouse is Ready when the profile installs one
  if ! kubectl -n "$NAMESPACE" get lakehouse "$LAKEHOUSE" >/dev/null 2>&1; then
    note lakehouse '"not installed"'
  elif kubectl -n "$NAMESPACE" wait --for=condition=Ready "lakehouse/${LAKEHOUSE}" --timeout="$WAIT" >/dev/null 2>&1; then
    ok lakehouse "lakehouse/${LAKEHOUSE} is Ready"
  else
    bad lakehouse "\"not Ready within ${WAIT}\""
  fi

  # 5. every Deployment is available
  local deploys line rest have want deploy_total deploy_up
  local -a deploy_short=()
  deploys="$(kubectl -n "$NAMESPACE" get deploy \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.availableReplicas}{"\t"}{.spec.replicas}{"\n"}{end}' \
    2>/dev/null || true)"
  deploy_total=0
  deploy_up=0
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
    local entry
    for entry in "${deploy_short[@]}"; do
      bad deploy "$entry"
    done
  fi

  # 6. no pod is waiting to start
  local pods reasons reason
  local -a pod_waiting=()
  pods="$(kubectl -n "$NAMESPACE" get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].state.waiting.reason}{"\t"}{.status.initContainerStatuses[*].state.waiting.reason}{"\n"}{end}' \
    2>/dev/null || true)"
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
    local waiting
    for waiting in "${pod_waiting[@]}"; do
      bad pods "$waiting"
    done
  fi

  # 7. Nova answers
  local nova_url rc body
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

  # 8. Trino answers
  local trino_url
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

  # 9. the identity provider answers
  local oidc_url
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

  return "$status"
}

# --- what a person still has to do (never part of the exit code) ---------------------------
person_notes() {
  local domain
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
}

# --- phase `upgrade` ----------------------------------------------------------------------
# repo_without_tag <ref>: the registry/repository half of an image reference, tag and digest
# dropped, so it can be handed to `--set image.repository`.
repo_without_tag() {
  local ref="$1" head tail
  case "$ref" in
    */*)
      head="${ref%/*}"
      tail="${ref##*/}"
      case "$tail" in
        *:*) printf '%s/%s' "$head" "${tail%%:*}" ;;
        *) printf '%s' "$ref" ;;
      esac
      ;;
    *:*) printf '%s' "${ref%%:*}" ;;
    *) printf '%s' "$ref" ;;
  esac
}

tag_without_digest() {
  local ref="$1" tagless
  tagless="${ref%%@*}"
  case "${tagless##*/}" in
    *:*) printf '%s' "${tagless##*:}" ;;
    *) printf '%s' "dev" ;;
  esac
}

phase_upgrade() {
  local current image_repo image_digest image_tag_prefix new_tag helm_err rc=0 second first_flip
  current="$(kubectl -n "$NAMESPACE" get deploy "$OPERATOR_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  current="$(printf '%s' "$current" | tr -d '[:space:]')"

  if [ -z "$OPERATOR_IMAGE" ]; then
    unknown upgrade '"OPERATOR_IMAGE is not set (ghcr.io/stardelt/stardelt-operator@sha256:<digest>)"'
    echo "verify-fresh-node: UNVERIFIED (nothing to upgrade to)" >&2
    exit 3
  fi
  if [ -z "$OPERATOR_CHART" ]; then
    unknown upgrade '"OPERATOR_CHART is not set (the path to stardelt-operator/chart)"'
    echo "verify-fresh-node: UNVERIFIED (no chart to upgrade with)" >&2
    exit 3
  fi
  if [ "$OPERATOR_IMAGE" = "$current" ]; then
    echo "nothing to upgrade (the operator already runs ${current})" >&2
    exit 3
  fi
  if [ -z "$current" ]; then
    bad upgrade "\"deploy/${OPERATOR_DEPLOY} is not readable in ${NAMESPACE}\""
    echo "verify-fresh-node: FAIL (there is no operator to upgrade)" >&2
    exit 1
  fi

  image_digest="${OPERATOR_IMAGE##*@}"
  if [ "$image_digest" = "$OPERATOR_IMAGE" ] || [ -z "$image_digest" ]; then
    bad upgrade "\"OPERATOR_IMAGE is not a digest reference: ${OPERATOR_IMAGE}\""
    echo "verify-fresh-node: FAIL (the new operator image is not pinned by digest)" >&2
    exit 1
  fi
  image_repo="$(repo_without_tag "${OPERATOR_IMAGE%%@*}")"
  # The chart prints `repository:tag`. `dev@sha256:…` is the tag form that keeps the digest in
  # the reference, so `pullPolicy: IfNotPresent` still compares like with like.
  image_tag_prefix="$(tag_without_digest "$current")"
  new_tag="${image_tag_prefix}@${image_digest}"

  if ! helm_err="$(helm -n "$NAMESPACE" upgrade "$OPERATOR_RELEASE" "$OPERATOR_CHART" --reuse-values \
    --set "image.repository=${image_repo}" --set "image.tag=${new_tag}" 2>&1 >/dev/null)"; then
    bad upgrade "\"helm upgrade failed: ${helm_err}\""
    echo "verify-fresh-node: FAIL (the operator upgrade did not apply)" >&2
    exit 1
  fi

  if ! kubectl -n "$NAMESPACE" rollout status "deploy/${OPERATOR_DEPLOY}" --timeout="$UPGRADE_WAIT" >/dev/null 2>&1; then
    bad upgrade "\"rollout of deploy/${OPERATOR_DEPLOY} did not finish within ${UPGRADE_WAIT}\""
    echo "verify-fresh-node: FAIL (the new operator never became ready)" >&2
    exit 1
  fi

  second="$(readiness 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$second" >&2
    first_flip="$(printf '%s\n' "$second" | grep -m1 -E '^([✗?]) ' || true)"
    bad upgrade "\"the platform is not Ready after the upgrade: ${first_flip:-a readiness check failed}\""
    echo "verify-fresh-node: FAIL (the upgrade broke a readiness check)" >&2
    exit "$rc"
  fi

  ok upgrade "${current} → ${OPERATOR_IMAGE}; platform still Ready"

  echo "CRDs owned by the operator (informational):"
  kubectl get crd -l app.kubernetes.io/part-of=stardelt -o name 2>/dev/null || true
  echo "verify-fresh-node: PASS (upgraded the operator and the platform is still up in ${NAMESPACE})"
  exit 0
}

# --- phase `delete` -----------------------------------------------------------------------
# D18: deleting the platform removes the workloads and keeps the data (`Retain` is the only
# policy in v0.2). The Lakehouse goes first — its own finalizer uninstalls its releases and
# retains the catalog PVC — then the PlatformInstance, whose finalizer uninstalls the platform's
# releases. The two bare Deployments (Nova, Keycloak) carry an ownerReference and are removed by
# the garbage collector, so they need a wait of their own.
phase_delete() {
  local deploys_before pvcs_before name secret ref pvc_name phase
  deploys_before="$(kubectl -n "$NAMESPACE" get deploy -o name 2>/dev/null || true)"
  pvcs_before="$(kubectl -n "$NAMESPACE" get pvc -o name 2>/dev/null || true)"

  # 1. the Lakehouse first: its finalizer uninstalls its releases (trino, lakekeeper, openfga,
  #    seaweedfs) and leaves the catalog PVC and the Secrets alone (D18).
  if ! kubectl -n "$NAMESPACE" delete "lakehouse/${LAKEHOUSE}" --wait=true --timeout="$WAIT" >/dev/null 2>&1; then
    bad delete "\"lakehouse/${LAKEHOUSE} was not deleted\""
    echo "verify-fresh-node: FAIL (the Lakehouse delete did not complete)" >&2
    exit 1
  fi

  # 2. the PlatformInstance
  if ! kubectl -n "$NAMESPACE" delete "$instance_ref" --wait=true --timeout="$WAIT" >/dev/null 2>&1; then
    bad delete "\"${instance_ref} was not deleted\""
    echo "verify-fresh-node: FAIL (the delete did not complete)" >&2
    exit 1
  fi

  # The bare workloads carry an ownerReference to the PlatformInstance; the garbage collector
  # removes them after the finalizer is gone, which `kubectl delete --wait` does not wait for.
  for name in nova keycloak; do
    printf '%s\n' "$deploys_before" | grep -q "/${name}\$" || continue
    kubectl -n "$NAMESPACE" wait --for=delete "deploy/${name}" --timeout=60s >/dev/null 2>&1 || true
  done

  # 3. the workloads the operator owned are gone
  for name in nova keycloak lakekeeper trino-coordinator seaweedfs-s3 openbao; do
    printf '%s\n' "$deploys_before" | grep -q "/${name}\$" || continue
    if kubectl -n "$NAMESPACE" get "deploy/${name}" >/dev/null 2>&1; then
      bad delete "${name} still present"
    fi
  done

  # 4. the data is retained
  for secret in stardelt-realm-admin stardelt-s3-creds; do
    if ! kubectl -n "$NAMESPACE" get "secret/${secret}" >/dev/null 2>&1; then
      bad delete "secret/${secret} was removed"
    fi
  done
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    # `get pvc -o name` prints `persistentvolumeclaim/x`; ask for it as `pvc/x` so the check does
    # not depend on which spelling the cluster reports.
    pvc_name="${ref##*/}"
    phase=""
    if ! phase="$(kubectl -n "$NAMESPACE" get "pvc/${pvc_name}" -o jsonpath='{.status.phase}' 2>/dev/null)"; then
      bad delete "pvc/${pvc_name} was removed"
      continue
    fi
    if [ "$phase" = "Lost" ]; then
      bad delete "pvc/${pvc_name} is Lost"
    fi
  done <<<"$pvcs_before"

  # 5. the custom resources are gone
  if kubectl -n "$NAMESPACE" get "$instance_ref" >/dev/null 2>&1; then
    bad delete "${instance_ref} is still present"
  fi
  if kubectl -n "$NAMESPACE" get "lakehouse/${LAKEHOUSE}" >/dev/null 2>&1; then
    bad delete "lakehouse/${LAKEHOUSE} is still present"
  fi

  if [ "$status" -ne 0 ]; then
    echo "verify-fresh-node: FAIL (the delete left something behind)" >&2
    exit 1
  fi
  ok delete "workloads removed, secrets and PVCs retained"
  echo "verify-fresh-node: PASS (deleted ${instance_ref} and kept the data)"
  exit 0
}

usage() {
  cat <<'EOF'
usage: verify-fresh-node.sh [ready|upgrade|delete]

  ready    the readiness checks of stardelt-platform#1017 (default)
  upgrade  the readiness checks, then upgrade the operator image and check it converges
           needs OPERATOR_CHART (path to stardelt-operator/chart) and OPERATOR_IMAGE
           (ghcr.io/stardelt/stardelt-operator@sha256:<digest>); OPERATOR_RELEASE, UPGRADE_WAIT
  delete   the readiness checks, then delete the PlatformInstance and check D18
EOF
}

main() {
  local phase="${1:-ready}" rc=0
  case "$phase" in
    ready | upgrade | delete) ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      echo "verify-fresh-node: unknown phase '${phase}' (ready, upgrade, delete)" >&2
      usage >&2
      exit 2
      ;;
  esac

  case "$phase" in
    upgrade)
      if ! command -v helm >/dev/null 2>&1; then
        unknown upgrade '"helm is not installed"'
        echo "verify-fresh-node: UNVERIFIED (needs helm for the upgrade phase)" >&2
        exit 3
      fi
      ;;
  esac

  readiness || rc=$?

  if [ "$phase" = "ready" ]; then
    person_notes
    echo
    case "$rc" in
      0) echo "verify-fresh-node: PASS (the operator path is up in ${NAMESPACE})" ;;
      1) echo "verify-fresh-node: FAIL (a check above is short)" >&2 ;;
      *) echo "verify-fresh-node: UNVERIFIED (a check could not be made)" >&2 ;;
    esac
    exit "$rc"
  fi

  if [ "$rc" -ne 0 ]; then
    echo "verify-fresh-node: stopping — the readiness checks did not pass" >&2
    exit "$rc"
  fi

  case "$phase" in
    upgrade) phase_upgrade ;;
    delete) phase_delete ;;
  esac
}

main "$@"
