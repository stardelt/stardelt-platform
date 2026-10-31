#!/usr/bin/env bash
# The one-command install and the one-command upgrade (platform#422).
#
#   scripts/platform.sh install [--check]   # the platform flow
#   scripts/platform.sh upgrade [--check]   # the upgrade flow
#   scripts/platform.sh check install       # the idempotence gate
#   scripts/platform.sh check upgrade       # the idempotence gate for the upgrade
#
# Why this exists: the platform's promise to an operator is "one command
# installs it, one command upgrades it, and nothing in between is your job".
# The Makefile grew one target per component, each with its own prerequisites
# and its own failure modes; this script is the sequence that ties them
# together, and it adds the three things the sequence alone did not have:
#
#   * every step has a name, and a failure prints the step, what that step
#     does, the command to look at and the next action — never a bare exit
#     code, never a silent retry;
#   * the flow waits for every workload and then prints what is running;
#   * the idempotence gate: run the flow again on a converged cluster and
#     prove that no resource version moved.
#
# The steps themselves are the step-* targets of the Makefile: one
# implementation per step, and `make install` / `make install-core` call the
# same targets in the same order.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
# IDENTITY=1 asks for the platform IdP on a cluster that has none yet (a fresh
# cluster needs a domain for it: BASE_DOMAIN=…). Without it the flow keeps the
# development shape (no realm, an unauthenticated Trino) and says so.
IDENTITY="${IDENTITY:-0}"

FLOW="install"
GATE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
usage: scripts/platform.sh install [--check]
       scripts/platform.sh upgrade [--check]
       scripts/platform.sh check [install|upgrade]

  install   the platform flow: storage, databases, identity, catalog, the
            access-sync, the query engine, the apps, the pins — then it waits
            for every workload and prints what is running.
  upgrade   the same convergence plus the schema migrations, the pins and the
            verify targets at the end. Safe to run twice.
  check     the idempotence gate: run the flow on a converged cluster and
            prove that no resource version moved. Exits 1 when one did.
  --check   a dry run: print what every step would do, write nothing.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|upgrade) FLOW="$1"; shift ;;
    check) GATE=1; shift ;;
    --check) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "platform.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$GATE" = 1 ] && [ $# -gt 0 ]; then
  case "$1" in
    install|upgrade) FLOW="$1"; shift ;;
    *) echo "platform.sh: unknown flow '$1'" >&2; exit 2 ;;
  esac
fi

command -v kubectl >/dev/null 2>&1 || { echo "platform.sh: kubectl not found (run 'make deps')" >&2; exit 1; }
command -v make >/dev/null 2>&1 || { echo "platform.sh: make not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The steps
# ---------------------------------------------------------------------------
STEP_ORDER=()
declare -A STEP_TARGET STEP_WHAT STEP_UNDO STEP_LOOK

add_step() {
  # id | make target | what it does | how to undo it | what to look at
  STEP_ORDER+=("$1")
  STEP_TARGET["$1"]="$2"
  STEP_WHAT["$1"]="$3"
  STEP_UNDO["$1"]="$4"
  STEP_LOOK["$1"]="$5"
}

add_step preflight step-preflight \
  "checks the tools (kubectl, helm), prints the kube-context it will act on and adds the Helm repos" \
  "nothing to undo — this step only reads" \
  "kubectl config current-context"

add_step storage step-storage \
  "installs the object store (SeaweedFS, the S3 API) and the S3 key pair that reaches it" \
  "helm uninstall seaweedfs -n $NAMESPACE (the PVC and the objects stay)" \
  "kubectl -n $NAMESPACE logs deploy/seaweedfs-s3 --tail=100"

add_step databases step-cnpg-cluster \
  "installs the CloudNative-PG operator and the Postgres cluster of the catalog" \
  "kubectl delete -f manifests/cnpg-postgres.yaml (the PVC and the data stay)" \
  "kubectl -n $NAMESPACE get cluster lakekeeper-pg -o yaml"

add_step openfga step-openfga \
  "installs the catalog's permission store (OpenFGA) with its own Postgres and the NetworkPolicy that admits only the catalog" \
  "kubectl delete -f manifests/openfga-pg.yaml (the PVC and the permission tuples stay)" \
  "kubectl -n $NAMESPACE logs deploy/openfga --tail=100"

add_step identity install-identity \
  "installs the platform IdP (Keycloak): the realm, the client secrets, the audiences and the query engine behind them" \
  "kubectl delete -f manifests/keycloak.yaml (the realm's data stays in its Postgres)" \
  "kubectl -n $NAMESPACE logs deploy/keycloak --tail=100"

add_step catalog step-lakekeeper \
  "installs the Iceberg REST catalog (Lakekeeper), bootstraps it and applies the ingress NetworkPolicy" \
  "helm uninstall lakekeeper -n $NAMESPACE (the PVC and the metadata stay)" \
  "kubectl -n $NAMESPACE logs deploy/lakekeeper --tail=100"

add_step access-sync step-access-sync \
  "installs the CronJob that turns every Catalog object into a Lakekeeper warehouse with its grants, and publishes the decision table" \
  "kubectl delete -f manifests/access-sync.yaml (the warehouses and the grants stay)" \
  "kubectl -n $NAMESPACE logs job/access-sync-now --tail=100"

add_step query step-trino \
  "installs the query engine (Trino) — with OAuth2 and the in-cluster TLS listener when the platform has an IdP" \
  "helm uninstall trino -n $NAMESPACE (the PVC stays)" \
  "kubectl -n $NAMESPACE logs deploy/trino-coordinator --tail=100"

add_step apps step-apps \
  "installs the apps: the orchestrator (Airflow), the BI tool (Superset) and Nova (the UI and the API)" \
  "helm uninstall airflow superset -n $NAMESPACE (the PVCs stay)" \
  "kubectl -n $NAMESPACE get pods -o wide"

add_step notebooks step-notebooks \
  "installs the notebooks (JupyterHub) and the versioned bucket they publish into" \
  "helm uninstall jupyterhub -n $NAMESPACE (the PVC stays)" \
  "kubectl -n $NAMESPACE logs deploy/hub --tail=100"

add_step spark step-spark \
  "installs the Spark Connect endpoint (heavy compute on the same Iceberg tables)" \
  "kubectl delete -f manifests/spark.yaml (the data stays in the object store)" \
  "kubectl -n $NAMESPACE logs deploy/spark-connect --tail=100"

add_step pins step-pins \
  "pins every stardelt image this cluster runs to the digest CI published" \
  "kubectl -n $NAMESPACE set image deploy/<app> <app>=<image>:<tag>" \
  "kubectl -n $NAMESPACE get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image"

add_step verify step-verify \
  "proves the platform works end to end: Trino's authentication, the catalog grants against the OPA bridge and the backups" \
  "nothing to undo — this step only reads" \
  "make verify-trino-auth verify-catalog-permissions verify-backups-all"

# The two plans. The install converges the cluster and stops; the upgrade adds
# the verify targets at the end. Both end with the wait and the report, which
# the runner does itself (they are not Makefile targets: they read the cluster
# and print).
PLAN_INSTALL="preflight storage databases openfga identity catalog access-sync query apps notebooks spark pins"
PLAN_UPGRADE="preflight storage databases openfga identity catalog query apps notebooks spark pins access-sync"

plan_for() {
  case "$1" in
    upgrade) echo "$PLAN_UPGRADE" ;;
    *)       echo "$PLAN_INSTALL" ;;
  esac
}

# ---------------------------------------------------------------------------
# Running a step
# ---------------------------------------------------------------------------
fail_step() {
  local id="$1" rc="$2"
  {
    printf '\n\033[1;31m✗ step %s failed (exit %s)\033[0m\n\n' "$id" "$rc"
    printf '  what this step does : %s\n' "${STEP_WHAT[$id]}"
    printf '  how to undo it      : %s\n' "${STEP_UNDO[$id]}"
    printf '  look at             : %s\n' "${STEP_LOOK[$id]}"
    printf '  next                : fix the cause the command above shows, then run the\n'
    printf '                        command again. Every step is idempotent, so the run\n'
    printf '                        continues where it stopped and changes nothing else.\n'
  } >&2
  exit "$rc"
}

run_step() {
  local id="$1" n="$2" total="$3" rc=0
  printf '\n\033[1m› step %s/%s · %s\033[0m\n' "$n" "$total" "$id"
  printf '  what : %s\n' "${STEP_WHAT[$id]}"
  printf '  undo : %s\n' "${STEP_UNDO[$id]}"

  if [ "$DRY_RUN" = 1 ]; then
    printf '  dry run — the commands below would run, nothing is written:\n'
    make --no-print-directory -n "${STEP_TARGET[$id]}" 2>&1 | sed 's/^/    /' || true
    return 0
  fi

  # A moving image tag is not convergent: `pin-images` resolves whatever CI last
  # published under `dev`, so a gate run would re-pin every deployment and the
  # comparison below could never pass while CI keeps publishing. Moving the pins
  # is the upgrade's job, so the gate runs the flow with them held still.
  if [ "$GATE" = 1 ]; then
    SKIP_PINS=1 make --no-print-directory "${STEP_TARGET[$id]}" || rc=$?
  else
    make --no-print-directory "${STEP_TARGET[$id]}" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    fail_step "$id" "$rc"
  fi
}

# ---------------------------------------------------------------------------
# Waiting for the workloads
# ---------------------------------------------------------------------------
wait_for_workloads() {
  printf '\n\033[1m› waiting for every workload to become ready\033[0m\n'
  local obj rc=0
  for obj in $(kubectl -n "$NAMESPACE" get deploy,sts -o name 2>/dev/null); do
    printf '  %s\n' "$obj"
    kubectl -n "$NAMESPACE" rollout status "$obj" --timeout=5m >/dev/null 2>&1 || rc=1
  done
  for obj in $(kubectl -n "$NAMESPACE" get cluster -o name 2>/dev/null); do
    printf '  %s\n' "$obj"
    kubectl -n "$NAMESPACE" wait --for=condition=Ready --timeout=5m "$obj" >/dev/null 2>&1 || rc=1
  done
  if [ "$rc" -ne 0 ]; then
    {
      printf '\n\033[1;31m✗ not every workload became ready\033[0m\n\n'
      printf '  what this step does : waits for every Deployment, StatefulSet and Postgres cluster\n'
      printf '                        in the namespace to report Ready.\n'
      printf '  look at             : kubectl -n %s get pods -o wide\n' "$NAMESPACE"
      printf '  next                : read the pod that is not Ready (kubectl -n %s describe pod <pod>),\n' "$NAMESPACE"
      printf '                        fix it, then run the command again.\n'
    } >&2
    exit 1
  fi
  printf '  every workload is ready\n'
}

# ---------------------------------------------------------------------------
# What is running
# ---------------------------------------------------------------------------
report() {
  printf '\n\033[1m› what is running in namespace %s\033[0m\n' "$NAMESPACE"
  kubectl -n "$NAMESPACE" get deploy,sts -o custom-columns=\
'NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image' 2>/dev/null || true

  local domain="$BASE_DOMAIN"
  if [ -z "$domain" ]; then
    domain="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath='{.data.baseDomain}' 2>/dev/null || true)"
  fi
  if [ -z "$domain" ]; then
    domain="$(kubectl -n "$NAMESPACE" get configmap stardelt-identity -o jsonpath='{.data.publicUrl}' 2>/dev/null | sed 's#https://##' || true)"
  fi

  printf '\n  where to reach it\n'
  if [ -n "$domain" ]; then
    printf '    Nova        https://%s\n' "$domain"
    printf '    Trino       https://trino.%s\n' "$domain"
    printf '    Superset    https://superset.%s\n' "$domain"
    printf '    Airflow     https://airflow.%s\n' "$domain"
    printf '    Notebooks   https://jupyter.%s\n' "$domain"
    printf '    Keycloak    https://id.%s/realms/stardelt\n' "$domain"
  else
    printf '    no platform IdP in this namespace — no public URLs.\n'
  fi
  printf "    'make pf' opens port-forwards to Nova, Trino, Lakekeeper and Superset.\n"

  if ! kubectl -n "$NAMESPACE" get configmap stardelt-identity >/dev/null 2>&1; then
    printf '\n  \033[1;33m!\033[0m this cluster has no platform IdP: Trino accepts every statement\n'
    printf '    without a token. Install one with\n'
    printf "    'IDENTITY=1 BASE_DOMAIN=<your-domain> make platform'\n"
  fi
}

# ---------------------------------------------------------------------------
# The idempotence gate
# ---------------------------------------------------------------------------
# Every object of the platform, with its resourceVersion. Three kinds need a
# different measure:
#
#   * Jobs are left out on purpose: the flow creates a Job per run (the
#     access-sync tick, the catalog's bootstrap) and a new Job is not a change
#     of the cluster's state.
#   * The CronJob, the CNPG Clusters and the ScheduledBackups are compared by
#     their *spec*: their controllers write the status on their own (a
#     CronJob's lastScheduleTime, a Cluster's primary) and that is not the
#     flow changing anything.
#   * Helm's own release secrets (sh.helm.release.v1.*) are Helm's history of
#     the release: every `helm upgrade` writes a new one, whatever it changed.
SNAPSHOT_KINDS="deployments statefulsets daemonsets configmaps secrets serviceaccounts
services roles rolebindings networkpolicies persistentvolumeclaims certificates issuers
cronjobs scheduledbackups.postgresql.cnpg.io clusters.postgresql.cnpg.io
catalogs.stardelt.io sqlwarehouses.stardelt.io platforminstances.stardelt.io
serviceprincipals.stardelt.io connections.stardelt.io volumes.stardelt.io
pipelines.stardelt.io ingestionsources.stardelt.io lakephouses.stardelt.io"

snapshot() {
  local kind line out
  for kind in $SNAPSHOT_KINDS; do
    case "$kind" in
      cronjobs|scheduledbackups.postgresql.cnpg.io|clusters.postgresql.cnpg.io)
        out="$(kubectl -n "$NAMESPACE" get "$kind" -o json 2>/dev/null \
          | jq -r '.items[] | "\(.metadata.name)=" + (.spec | tostring | @base64)' 2>/dev/null)" || continue
        ;;
      secrets)
        out="$(kubectl -n "$NAMESPACE" get "$kind" -o json 2>/dev/null \
          | jq -r '.items[] | select(.metadata.name | startswith("sh.helm.release.") | not) | "\(.metadata.name)=\(.metadata.resourceVersion)"' 2>/dev/null)" || continue
        ;;
      *)
        out="$(kubectl -n "$NAMESPACE" get "$kind" \
          -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.resourceVersion}{"\n"}{end}' 2>/dev/null)" || continue
        ;;
    esac
    while IFS= read -r line; do
      [ -n "$line" ] && printf '%s/%s\n' "$kind" "$line"
    done <<EOF
$out
EOF
  done | sort
}

# The Helm releases, with their revision: informational. The revision grows
# with every `helm upgrade` — that is Helm's history, not a change of the
# cluster's state.
helm_revisions() {
  helm list -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.[] | "\(.name)=\(.revision)"' 2>/dev/null | sort || true
}

gate() {
  local flow="$1" before after changed
  local tmp
  tmp="$(mktemp -d)"
  # The cleanup runs at the end of the gate, not from a trap: a trap would
  # fire after the function returned and the local variable would be gone.
  before="$tmp/before"
  after="$tmp/after"

  printf '\n\033[1m› idempotence gate: running the %s flow on a converged cluster\033[0m\n' "$flow"
  snapshot > "$before"
  helm_revisions > "$tmp/helm-before"
  printf '  %s object(s) snapshotted before the run\n' "$(wc -l < "$before" | tr -d ' ')"

  run_flow "$flow"

  snapshot > "$after"
  helm_revisions > "$tmp/helm-after"
  printf '  %s object(s) snapshotted after the run\n' "$(wc -l < "$after" | tr -d ' ')"

  changed="$(diff -u "$before" "$after" || true)"
  if [ -n "$changed" ]; then
    {
      printf '\n\033[1;31m✗ the %s flow changed the cluster\033[0m\n\n' "$flow"
      printf '  A converged cluster must not change: every resourceVersion below moved\n'
      printf '  (or appeared, or disappeared) while the flow ran.\n\n'
      printf '%s\n' "$changed"
      printf '\n  next: the step that wrote the object above is the one to look at — the flow\n'
      printf '        prints its name and the command to run.\n'
    } >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  printf '\n\033[1;32m✓ the %s flow changed nothing\033[0m — every resourceVersion stayed.\n' "$flow"
  return 0
}

# ---------------------------------------------------------------------------
# The host preflight
# ---------------------------------------------------------------------------
# AppArmor can refuse signals between the processes of one container. PostgreSQL
# wakes its own background workers with SIGURG, so every CNPG instance stays in
# "starting up", the install looks like a database fault, and the cause is on the
# node (stardelt-platform#445). Only checkable when the node is this machine.
host_preflight() {
  command -v journalctl >/dev/null 2>&1 || return 0
  local host denied
  host="$(hostname 2>/dev/null || true)"
  [ -n "$host" ] || return 0
  # A remote cluster is somebody else's host: its kernel log is not ours to read.
  kubectl get node -o name 2>/dev/null | grep -qx "node/$host" || return 0
  denied="$(journalctl -k --since "-10 min" 2>/dev/null | grep -c 'apparmor="DENIED" operation="signal"' || true)"
  [ "${denied:-0}" -gt 0 ] || return 0
  {
    printf '\n\033[1;31m✗ the host denies signals inside containers — Postgres will not start\033[0m\n\n'
    printf '  %s AppArmor denial(s) in the last ten minutes, like:\n' "$denied"
    printf '    apparmor="DENIED" operation="signal" class="signal" profile="cri-containerd.apparmor.d" comm="postgres"\n\n'
    printf '  why it matters : PostgreSQL wakes its background workers with SIGURG. When the\n'
    printf '                   profile refuses that, every CNPG instance stays "starting up"\n'
    printf '                   and the install hangs on the databases.\n'
    printf '  check          : sudo journalctl -k --since "-10 min" | grep -i "apparmor"\n'
    printf '  ways out       : 1. boot the previous kernel and hold the new one\n'
    printf '                   2. disable_apparmor = true in the k3s containerd template, restart k3s\n'
    printf '                   3. securityContext.appArmorProfile: Unconfined per pod (many pods)\n'
    printf '  documented     : getting-started/prerequisites, "Host OS, kernel and AppArmor"\n'
  } >&2
  exit 1
}

# ---------------------------------------------------------------------------
# The flow
# ---------------------------------------------------------------------------
run_flow() {
  local flow="$1"
  local plan id n=0 total
  plan="$(plan_for "$flow")"
  total="$(echo "$plan" | wc -w | tr -d ' ')"

  host_preflight

  for id in $plan; do
    n=$((n + 1))
    # The identity step only runs where the platform has an IdP or where the
    # operator asked for one: a cluster without a realm keeps the development
    # shape (an unauthenticated Trino), and the report says so.
    if [ "$id" = "identity" ] && ! identity_wanted; then
      printf '\n\033[1m› step %s/%s · identity — skipped\033[0m\n' "$n" "$total"
      printf '  no platform IdP in this namespace and IDENTITY is not set.\n'
      printf "  Install one with 'IDENTITY=1 BASE_DOMAIN=<your-domain> make platform'.\n"
      continue
    fi
    run_step "$id" "$n" "$total"
  done

  if [ "$DRY_RUN" = 1 ]; then
    report
    return 0
  fi

  wait_for_workloads
  report
}

identity_wanted() {
  case "$IDENTITY" in
    1|true|yes|on) return 0 ;;
  esac
  kubectl -n "$NAMESPACE" get configmap stardelt-identity >/dev/null 2>&1 && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$GATE" = 1 ]; then
  gate "$FLOW"
  exit $?
fi

printf '\n\033[1mstardelt %s\033[0m — namespace %s, kube-context %s\n' \
  "$FLOW" "$NAMESPACE" "$(kubectl config current-context 2>/dev/null || echo '?')"

run_flow "$FLOW"

if [ "$FLOW" = "upgrade" ]; then
  printf '\n\033[1m› step verify · the platform proves itself\033[0m\n'
  rc=0
  make --no-print-directory step-verify || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_step "verify" "$rc"
  fi
fi

printf '\n\033[1;32m✓ stardelt %s finished\033[0m\n' "$FLOW"
