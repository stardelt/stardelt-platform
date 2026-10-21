#!/usr/bin/env bash
# Verify that every PVC in the namespace has a backup mechanism, and that its
# newest backup is recent — or that the gap is an accepted, written-down
# exception. One command, one pass/fail (stardelt-platform#367).
#
#   make verify-backups-all
#   bash scripts/verify-backups-all.sh
#
# Why this exists: the platform keeps state in four different mechanisms —
# CloudNative-PG WAL + base backups (lakekeeper-pg, nova-pg, keycloak-pg,
# openfga-pg), pg_dump CronJobs (superset, airflow), the object-store sync
# (lakehouse-backup) and the volumes behind them. Before this target, answering
# "is every stateful component covered, and was it backed up recently?" meant
# knowing which of five guards to run, and a new PVC silently had no backup at
# all. This script:
#
#   1. enumerates the PVCs that exist right now (`kubectl get pvc`),
#   2. maps each to its mechanism from the table below (first pattern wins) and
#      reads the age of its newest backup:
#        CloudNative-PG  status.lastSuccessfulBackup on the Cluster
#        CronJob         status.lastSuccessfulTime (an incremental mirror's
#                        newest object ages while the source is idle, so the
#                        completed run — not an object — is the signal)
#        pg_dump         the newest object under s3://<bucket>/pgdump/<app>/,
#                        listed by ONE scratch aws-cli pod for all prefixes
#   3. prints `PVC | mechanism | last backup age | verdict` and exits 1 when any
#      PVC is FAIL: no mechanism mapped and not in the ACCEPTED list, a mapped
#      mechanism that is missing (no spec.backup, no ScheduledBackup, no
#      CronJob), or a last backup older than MAX_AGE_HOURS (default 36).
#
# The table is the contract: a new PVC makes the target fail until someone adds
# a mechanism or an accepted reason with a ticket. That is the point — silence
# is how a stateful component ends up without a backup.
#
# What it does not do:
#   - restore anything. `make verify-pgdump` restores the newest dump and
#     compares table counts; `make verify-backups*` compares the WAL bucket with
#     the database's own archiver. This target is coverage and recency only.
#   - check WAL freshness. That guard runs at 15 minutes
#     (`make verify-backups[-nova|-identity|-openfga]`); 36 h here only says the
#     daily base backup still exists.
#   - run on a schedule. It is a manual target (#367): run it after the nightly
#     window (02:30 base backups, 02:30/02:45 pg_dump, 03:15 object sync) or a
#     fresh install fails until each mechanism has completed one run.
#
# Environment:
#   NAMESPACE          default stardelt
#   MAX_AGE_HOURS      default 36
#   BACKUP_BUCKET      default backups — the bucket the pg_dump CronJobs write to
#   S3_CHECK_IMAGE     image for the listing pod (default amazon/aws-cli:2.17.0,
#                      the same image the platform's own S3 jobs run)
#   S3_SOURCE_OVERRIDE testing/repair hook: comma-separated `label=s3://bucket/prefix/`
#                      pairs replacing an object source. The #367 failure proof
#                      points one source at a prefix with no recent object:
#                        S3_SOURCE_OVERRIDE='pgdump/superset=s3://backups/pgdump/zz-test/'
#                      The label is the `pgdump/<app>` prefix shown in the table.
#
# The listing pod reads the endpoint and keys the platform's own S3 jobs use
# (`stardelt-s3-creds`) through secretKeyRef; no credential is ever printed, and
# the pod is deleted on exit. Its output is the pod's own clock (`NOW`) and, per
# source, the newest object's epoch and key — never a bucket listing.
#
# Exit status: 0 only if every PVC is PASS or ACCEPTED.
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"
BACKUP_BUCKET="${BACKUP_BUCKET:-backups}"
S3_CHECK_IMAGE="${S3_CHECK_IMAGE:-amazon/aws-cli:2.17.0}"
S3_SOURCE_OVERRIDE="${S3_SOURCE_OVERRIDE:-}"

case "$MAX_AGE_HOURS" in
  '' | *[!0-9]*)
    echo "MAX_AGE_HOURS must be a whole number of hours (got '$MAX_AGE_HOURS')" >&2
    exit 2
    ;;
esac
MAX_AGE_SECONDS=$(( MAX_AGE_HOURS * 3600 ))

ok()   { printf '✓ %s\n' "$*"; }
info() { printf '› %s\n' "$*"; }
err()  { printf '✗ %s\n' "$*" >&2; }

command -v kubectl >/dev/null 2>&1 || { err "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq is required (resources are read as JSON)"; exit 1; }

# ---------------------------------------------------------------------------
# The mapping. One row per PVC pattern, first match wins; a PVC that matches no
# row FAILs. Fields: pattern|mechanism|target|accepted reason
#   cnpg      target = Cluster name        — spec.backup + ScheduledBackup <target>-daily
#   pgdump    target = app name            — CronJob <target>-pg-dump, object under pgdump/<target>/
#   cronjob   target = CronJob name        — status.lastSuccessfulTime
#   accepted  target = ticket              — no mechanism by design; reason is printed
#
# The accepted rows are the gaps the design names today (platform#3, the backup
# audit). Each has a reason and the ticket that closes it; removing one means
# building the mechanism first. A new PVC belongs in this table only with both.
# ---------------------------------------------------------------------------
RULES=(
  'data-airflow-postgresql-0|pgdump|airflow|-'
  'data-superset-postgresql-0|pgdump|superset|-'
  'data-seaweedfs-volume-*|cronjob|lakehouse-backup|-'
  'data-openbao-0|accepted|platform#368|secret store: copying it is not a pg_dump and the seal key needs a sealed transfer'
  'data-filer-seaweedfs-filer-*|accepted|platform#3|filer metadata (the S3 namespace index); the object bytes are what lakehouse-backup copies'
  'data-stardelt-seaweedfs-master-*|accepted|platform#3|volume-assignment metadata, not object data'
  'hub-db-dir|accepted|platform#3|JupyterHub session store (users, tokens); losing it means signing in again, notebooks are bucket objects'
  'keycloak-pg-*|cnpg|keycloak-pg|-'
  'lakekeeper-pg-*|cnpg|lakekeeper-pg|-'
  'nova-pg-*|cnpg|nova-pg|-'
  'openfga-pg-*|cnpg|openfga-pg|-'
)

scratch_pod=""
cleanup() {
  [ -n "$scratch_pod" ] || return 0
  kubectl -n "$NAMESPACE" delete pod "$scratch_pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  scratch_pod=""
}
trap cleanup EXIT

# RFC3339 (or the S3 listing's `+00:00` form) -> whole seconds since $now.
# Empty input means "never" (empty output, status 0); an unparseable value is
# an error (status 1), so a malformed timestamp cannot pass as fresh.
ts_age() {
  local ts="$1" epoch age
  [ -n "$ts" ] || return 0
  if ! epoch="$(date -u -d "$ts" +%s 2>/dev/null)"; then
    return 1
  fi
  age=$(( now - epoch ))
  [ "$age" -ge 0 ] || age=0
  printf '%s' "$age"
}

fmt_age() {
  local s="$1"
  if [ "$s" -lt 3600 ]; then
    printf '%dm' "$(( s / 60 ))"
  elif [ "$s" -lt 172800 ]; then
    printf '%dh%02dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
  else
    printf '%dd%02dh' "$(( s / 86400 ))" "$(( (s % 86400) / 3600 ))"
  fi
}

if ! pvc_json="$(kubectl -n "$NAMESPACE" get pvc -o json)"; then
  err "cannot list PVCs in namespace $NAMESPACE (kube-context: $(kubectl config current-context 2>/dev/null || echo none))"
  exit 1
fi
mapfile -t pvcs < <(jq -r '.items[].metadata.name' <<<"$pvc_json" | sort)
if [ "${#pvcs[@]}" -eq 0 ]; then
  err "no PVCs in namespace $NAMESPACE — wrong namespace or cluster?"
  exit 1
fi

# One read per resource kind; the CNPG CRDs may be absent on a bare cluster.
clusters_json="$(kubectl -n "$NAMESPACE" get clusters.postgresql.cnpg.io -o json 2>/dev/null || echo '{"items":[]}')"
cronjobs_json="$(kubectl -n "$NAMESPACE" get cronjob -o json 2>/dev/null || echo '{"items":[]}')"
scheduledbackups_json="$(kubectl -n "$NAMESPACE" get scheduledbackup -o json 2>/dev/null || echo '{"items":[]}')"
now="$(date -u +%s)"

declare -A pvc_mech=() pvc_target=() pvc_reason=() s3_uri=()
s3_requests=()
for pvc in "${pvcs[@]}"; do
  pvc_mech[$pvc]="none"
  pvc_target[$pvc]=""
  pvc_reason[$pvc]=""
  for rule in "${RULES[@]}"; do
    IFS='|' read -r pattern mechanism target reason <<<"$rule"
    # Unquoted on purpose: a rule pattern may be a glob (`data-seaweedfs-volume-*`).
    # shellcheck disable=SC2053
    if [[ "$pvc" == $pattern ]]; then
      pvc_mech[$pvc]="$mechanism"
      pvc_target[$pvc]="$target"
      pvc_reason[$pvc]="$reason"
      break
    fi
  done
  if [ "${pvc_mech[$pvc]}" = pgdump ]; then
    label="pgdump/${pvc_target[$pvc]}"
    s3_requests+=("$label|$BACKUP_BUCKET|pgdump/${pvc_target[$pvc]}/")
    s3_uri[$label]="s3://$BACKUP_BUCKET/pgdump/${pvc_target[$pvc]}/"
  fi
done

# `label=s3://bucket/prefix/` — replace the location of one object source.
# Unknown labels are ignored with a note (a typo must not silently pass as a
# check of the real prefix).
if [ -n "$S3_SOURCE_OVERRIDE" ]; then
  IFS=',' read -ra overrides <<<"$S3_SOURCE_OVERRIDE"
  for override in "${overrides[@]}"; do
    label="${override%%=*}"
    uri="${override#*=}"
    case "$uri" in
      s3://*) ;;
      *)
        err "S3_SOURCE_OVERRIDE entry '$override' is not label=s3://bucket/prefix/"
        exit 2
        ;;
    esac
    rest="${uri#s3://}"
    bucket="${rest%%/*}"
    prefix="${rest#*/}"
    if [ "$prefix" = "$rest" ]; then
      prefix=""
    fi
    if [ -z "$bucket" ]; then
      err "S3_SOURCE_OVERRIDE entry '$override' has no bucket"
      exit 2
    fi
    replaced=0
    for i in "${!s3_requests[@]}"; do
      IFS='|' read -r request_label _ _ <<<"${s3_requests[$i]}"
      if [ "$request_label" = "$label" ]; then
        s3_requests[i]="$label|$bucket|$prefix"
        s3_uri[$label]="s3://$bucket/$prefix"
        replaced=1
      fi
    done
    if [ "$replaced" -eq 0 ]; then
      info "S3_SOURCE_OVERRIDE: no source labelled '$label' (ignored)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# One pod lists every object source: the same endpoint and keys the platform's
# own jobs use, never on the command line. The pod prints its own clock and,
# per source, `SOURCE <label> <epoch> <key>` (or `none` / `error`), so the age
# does not depend on the caller's clock.
# ---------------------------------------------------------------------------
declare -A s3_state=() s3_epoch=() s3_key=()
pod_now=""
if [ "${#s3_requests[@]}" -gt 0 ]; then
  s3_sources="$(printf '%s\n' "${s3_requests[@]}")"
  pod_script="$(cat <<'POD'
set -eu
s3() { aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }
printf 'NOW %s\n' "$(date -u +%s)"
printf '%s\n' "$S3_SOURCES" | while IFS='|' read -r label bucket prefix; do
  [ -n "$label" ] || continue
  if [ -n "$prefix" ]; then
    listing="$(s3 s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" \
      --query 'Contents[].[LastModified,Key,Size]' --output text 2>/dev/null)" \
      || { printf 'SOURCE %s error\n' "$label"; continue; }
  else
    listing="$(s3 s3api list-objects-v2 --bucket "$bucket" \
      --query 'Contents[].[LastModified,Key,Size]' --output text 2>/dev/null)" \
      || { printf 'SOURCE %s error\n' "$label"; continue; }
  fi
  # An empty listing prints the literal `None` with --output text; the awk
  # keeps only the three-column rows whose first field is a timestamp.
  newest="$(printf '%s\n' "$listing" \
    | awk 'NF == 3 && $1 ~ /^[0-9]{4}-/ { print }' \
    | sort | tail -n 1)"
  if [ -z "$newest" ]; then
    printf 'SOURCE %s none\n' "$label"
    continue
  fi
  modified="$(printf '%s' "$newest" | cut -f1)"
  key="$(printf '%s' "$newest" | cut -f2)"
  printf 'SOURCE %s %s %s\n' "$label" "$(date -u -d "$modified" +%s)" "$key"
done
POD
)"

  scratch_pod="verify-backups-all-s3-$$"
  pod_spec="$(jq -n \
    --arg name "$scratch_pod" --arg ns "$NAMESPACE" \
    --arg image "$S3_CHECK_IMAGE" --arg cmd "$pod_script" --arg sources "$s3_sources" \
    '{
      apiVersion: "v1", kind: "Pod",
      metadata: { name: $name, namespace: $ns, labels: { "app.kubernetes.io/part-of": "stardelt" } },
      spec: {
        restartPolicy: "Never",
        automountServiceAccountToken: false,
        securityContext: {
          runAsNonRoot: true, runAsUser: 999, runAsGroup: 999, fsGroup: 999,
          seccompProfile: { type: "RuntimeDefault" }
        },
        containers: [{
          name: "s3ls",
          image: $image,
          command: ["sh", "-ec", $cmd],
          env: [
            { name: "S3_SOURCES", value: $sources },
            { name: "HOME", value: "/scratch" },
            { name: "AWS_ENDPOINT_URL", valueFrom: { secretKeyRef: { name: "stardelt-s3-creds", key: "endpoint" } } },
            { name: "AWS_ACCESS_KEY_ID", valueFrom: { secretKeyRef: { name: "stardelt-s3-creds", key: "access-key" } } },
            { name: "AWS_SECRET_ACCESS_KEY", valueFrom: { secretKeyRef: { name: "stardelt-s3-creds", key: "secret-key" } } },
            { name: "AWS_DEFAULT_REGION", valueFrom: { secretKeyRef: { name: "stardelt-s3-creds", key: "region" } } }
          ],
          securityContext: {
            allowPrivilegeEscalation: false, readOnlyRootFilesystem: true,
            capabilities: { drop: ["ALL"] }
          },
          resources: { requests: { cpu: "50m", memory: "64Mi" }, limits: { cpu: "500m", memory: "256Mi" } },
          volumeMounts: [{ name: "scratch", mountPath: "/scratch" }]
        }],
        volumes: [{ name: "scratch", emptyDir: {} }]
      }
    }')"

  info "listing ${#s3_requests[@]} object source(s) from one $S3_CHECK_IMAGE pod"
  if ! pod_out="$(kubectl -n "$NAMESPACE" run "$scratch_pod" \
        --rm --attach --quiet --restart=Never \
        --image "$S3_CHECK_IMAGE" \
        --pod-running-timeout=3m \
        --overrides "$pod_spec" 2>&1)"; then
    err "the listing pod failed — object ages are unknown:"
    printf '%s\n' "$pod_out" | tail -n 20 >&2
    pod_out=""
  fi

  while read -r tag field_a field_b field_rest; do
    case "$tag" in
      NOW) pod_now="$field_a" ;;
      SOURCE)
        case "$field_b" in
          error)
            s3_state[$field_a]="error"
            ;;
          none)
            s3_state[$field_a]="none"
            ;;
          *)
            s3_state[$field_a]="ok"
            s3_epoch[$field_a]="$field_b"
            s3_key[$field_a]="$field_rest"
            ;;
        esac
        ;;
    esac
  done <<<"$pod_out"
fi

declare -A pvc_age=() pvc_verdict=() pvc_disp=()
failures=()
for pvc in "${pvcs[@]}"; do
  mech="${pvc_mech[$pvc]}"
  target="${pvc_target[$pvc]}"
  age_disp="-"
  verdict=""
  mech_disp=""

  case "$mech" in
    accepted)
      mech_disp="accepted ($target)"
      verdict="ACCEPTED"
      ;;
    cnpg)
      mech_disp="CNPG $target: WAL + $target-daily"
      exists="$(jq -r --arg c "$target" 'any(.items[]?; .metadata.name == $c)' <<<"$clusters_json")"
      destination="$(jq -r --arg c "$target" \
        '.items[] | select(.metadata.name == $c) | (.spec.backup.barmanObjectStore.destinationPath // "")' \
        <<<"$clusters_json")"
      scheduled="$(jq -r --arg n "$target-daily" 'any(.items[]?; .metadata.name == $n)' <<<"$scheduledbackups_json")"
      last_backup="$(jq -r --arg c "$target" \
        '.items[] | select(.metadata.name == $c) | (.status.lastSuccessfulBackup // "")' \
        <<<"$clusters_json")"
      if [ "$exists" != true ]; then
        verdict="FAIL"
        mech_disp="CNPG $target (missing)"
        failures+=("$pvc: Cluster $NAMESPACE/$target does not exist — the PVC outlived its Cluster, or the name changed")
      elif [ -z "$destination" ]; then
        verdict="FAIL"
        failures+=("$pvc: Cluster $target declares no spec.backup.barmanObjectStore.destinationPath — without it the archiver is a successful no-op (#59); re-apply the manifests from an up-to-date main")
      elif [ "$scheduled" != true ]; then
        verdict="FAIL"
        failures+=("$pvc: no ScheduledBackup $target-daily — apply manifests/cnpg-backup-schedule.yaml")
      elif ! age="$(ts_age "$last_backup")"; then
        verdict="FAIL"
        failures+=("$pvc: cannot parse status.lastSuccessfulBackup '$last_backup' on Cluster $target")
      elif [ -z "$age" ]; then
        verdict="FAIL"
        age_disp="never"
        failures+=("$pvc: Cluster $target has never completed a base backup (status.lastSuccessfulBackup is empty) — check 'kubectl -n $NAMESPACE get backups'")
      elif [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
        verdict="FAIL"
        age_disp="$(fmt_age "$age")"
        failures+=("$pvc: the last successful base backup of Cluster $target is $(fmt_age "$age") old — older than MAX_AGE_HOURS=$MAX_AGE_HOURS (did $target-daily run?)")
      else
        verdict="PASS"
        age_disp="$(fmt_age "$age")"
      fi
      ;;
    pgdump)
      cronjob="${target}-pg-dump"
      label="pgdump/$target"
      source="${s3_uri[$label]:-s3://$BACKUP_BUCKET/pgdump/$target/}"
      mech_disp="CronJob $cronjob → $source"
      has_cronjob="$(jq -r --arg n "$cronjob" 'any(.items[]?; .metadata.name == $n)' <<<"$cronjobs_json")"
      if [ "$has_cronjob" != true ]; then
        verdict="FAIL"
        failures+=("$pvc: no CronJob $NAMESPACE/$cronjob — apply manifests/pg-dump-backup.yaml (make backups)")
      elif [ -z "$pod_now" ]; then
        verdict="FAIL"
        failures+=("$pvc: cannot list $source — the listing pod failed (see above)")
      else
        case "${s3_state[$label]:-missing}" in
          ok)
            age=$(( pod_now - s3_epoch[$label] ))
            [ "$age" -ge 0 ] || age=0
            if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
              verdict="FAIL"
              age_disp="$(fmt_age "$age")"
              failures+=("$pvc: the newest dump ${s3_key[$label]} is $(fmt_age "$age") old — older than MAX_AGE_HOURS=$MAX_AGE_HOURS (did $cronjob run?)")
            else
              verdict="PASS"
              age_disp="$(fmt_age "$age")"
            fi
            ;;
          none)
            verdict="FAIL"
            failures+=("$pvc: no object under $source — nothing has ever been dumped there")
            ;;
          error)
            verdict="FAIL"
            failures+=("$pvc: the listing pod could not read $source — check the stardelt-s3-creds Secret and the S3 endpoint")
            ;;
          *)
            verdict="FAIL"
            failures+=("$pvc: the listing pod returned no answer for $label")
            ;;
        esac
      fi
      ;;
    cronjob)
      mech_disp="CronJob $target (last successful run)"
      exists="$(jq -r --arg n "$target" 'any(.items[]?; .metadata.name == $n)' <<<"$cronjobs_json")"
      last_run="$(jq -r --arg n "$target" \
        '.items[] | select(.metadata.name == $n) | (.status.lastSuccessfulTime // "")' \
        <<<"$cronjobs_json")"
      if [ "$exists" != true ]; then
        verdict="FAIL"
        failures+=("$pvc: no CronJob $NAMESPACE/$target — apply its manifest")
      elif ! age="$(ts_age "$last_run")"; then
        verdict="FAIL"
        failures+=("$pvc: cannot parse status.lastSuccessfulTime '$last_run' on CronJob $target")
      elif [ -z "$age" ]; then
        verdict="FAIL"
        age_disp="never"
        failures+=("$pvc: CronJob $target has no successful run yet (status.lastSuccessfulTime is empty) — the mechanism exists but has never completed")
      elif [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
        verdict="FAIL"
        age_disp="$(fmt_age "$age")"
        failures+=("$pvc: the last successful run of CronJob $target is $(fmt_age "$age") old — older than MAX_AGE_HOURS=$MAX_AGE_HOURS")
      else
        verdict="PASS"
        age_disp="$(fmt_age "$age")"
      fi
      ;;
    *)
      mech_disp="no mechanism mapped"
      verdict="FAIL"
      failures+=("$pvc: no backup mechanism is mapped for this PVC — add one to RULES, or an ACCEPTED entry with a reason and a ticket (scripts/verify-backups-all.sh, #367)")
      ;;
  esac

  pvc_age[$pvc]="$age_disp"
  pvc_verdict[$pvc]="$verdict"
  pvc_disp[$pvc]="$mech_disp"
done

failed=0
accepted=0
rows=()
for pvc in "${pvcs[@]}"; do
  case "${pvc_verdict[$pvc]}" in
    PASS) ;;
    ACCEPTED) accepted=$(( accepted + 1 )) ;;
    *)
      failed=$(( failed + 1 ))
      ;;
  esac
  rows+=("$pvc"$'\t'"${pvc_disp[$pvc]}"$'\t'"${pvc_age[$pvc]}"$'\t'"${pvc_verdict[$pvc]}")
done

info "${#pvcs[@]} PVC(s) in namespace $NAMESPACE; a backup counts if it is younger than ${MAX_AGE_HOURS}h"
printf '\n'
{
  printf 'PVC\tMECHANISM\tLAST BACKUP AGE\tVERDICT\n'
  printf '%s\n' "${rows[@]}"
} | awk -F'\t' '
  { line[NR] = $0; for (i = 1; i <= 4; i++) if (length($i) > w[i]) w[i] = length($i) }
  END {
    for (r = 1; r <= NR; r++) {
      split(line[r], f, "\t")
      printf "%-*s | %-*s | %-*s | %s\n", w[1], f[1], w[2], f[2], w[3], f[3], f[4]
    }
  }'

if [ "$accepted" -gt 0 ]; then
  printf '\naccepted gaps (no mechanism by design, each with a ticket):\n'
  for pvc in "${pvcs[@]}"; do
    [ "${pvc_verdict[$pvc]}" = ACCEPTED ] || continue
    printf '  - %s (%s): %s\n' "$pvc" "${pvc_target[$pvc]}" "${pvc_reason[$pvc]}"
  done
fi

if [ "$failed" -gt 0 ]; then
  printf '\n'
  for failure in "${failures[@]}"; do
    err "$failure"
  done
  echo "verify-backups-all: FAIL ($failed of ${#pvcs[@]} PVC(s))" >&2
  exit 1
fi

ok "verify-backups-all: PASS ($(( ${#pvcs[@]} - accepted )) backed up, $accepted accepted, 0 failed)"
