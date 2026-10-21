#!/usr/bin/env bash
# Verify the pg_dump backups of Superset and Airflow end to end: run the CronJob
# now, check the object it wrote into the bucket, then restore *that object* into
# a throwaway database and compare its table count with the live one.
#
#   make verify-pgdump                  # both (PG_DUMP=all)
#   make verify-pgdump PG_DUMP=airflow
#   bash scripts/verify-pgdump.sh
#
# Why this exists (stardelt-platform#366): `superset-postgresql` and
# `airflow-postgresql` are Bitnami StatefulSets, not CloudNative-PG Clusters, so
# `spec.backup` and the WAL guards of verify-backups.sh do not cover them. The
# CronJobs in manifests/pg-dump-backup.yaml do — but "the job exited 0" is not a
# backup: it only says the shell finished. This check compares the *shelf* with
# the *database*, which is the same principle as #59:
#
#   (a) the CronJob exists (otherwise: `make backups`, or `kubectl apply -f
#       manifests/pg-dump-backup.yaml`)
#   (b) a Job created from it completes — the same job template the schedule
#       runs, so this also proves the Service names and Secret keys
#   (c) the newest object under s3://backups/pgdump/<app>/ is younger than
#       MAX_AGE_SECONDS (default 1800) and larger than MIN_SIZE_BYTES (10 KiB)
#   (d) the object restores: `pg_restore --list` reads the archive, a full
#       restore into database `restoretest` succeeds (`--exit-on-error`), and
#       the table count equals the live database's
#
# What it cannot see:
#   - Rows: the comparison is the schema's table count, not a checksum. A dump
#     that lost data but kept tables passes; the restore is still the place a
#     human would look.
#   - Retention: the 14-day prune inside the CronJob only runs there. An object
#     left behind by a changed schedule would still restore.
#   - Anything, when nobody runs it. There is no scheduled wrapper yet.
#
# Everything runs in one scratch pod in $NAMESPACE (the S3 endpoint and the
# database are cluster-internal): an init container lists and downloads the
# newest dump with the CronJob's own aws-cli image, the main container runs a
# throwaway PostgreSQL server of the *same major version* on an emptyDir. The
# pod and the verify Job are deleted at the end; the dump object is not (it is
# the backup, not a scratch artefact).
#
# Environment:
#   NAMESPACE          default stardelt
#   PG_DUMP            superset | airflow | all (default all)
#   MAX_AGE_SECONDS    default 1800 — the object must be this fresh
#   MIN_SIZE_BYTES     default 10240
#   RESTORE_IMAGE      override the scratch server image (default
#                      docker.io/library/postgres:<major of the dump container>)
#   KEEP_SCRATCH=1     keep the verify Job and the restore pod for inspection
#                      (they are deleted otherwise, on success and on failure)
#
# Exit status: 0 only if every target passed.
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"
PG_DUMP="${PG_DUMP:-all}"
MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-1800}"
MIN_SIZE_BYTES="${MIN_SIZE_BYTES:-10240}"
RESTORE_IMAGE="${RESTORE_IMAGE:-}"

ok()   { printf '✓ %s\n' "$*"; }
info() { printf '› %s\n' "$*"; }
err()  { printf '✗ %s\n' "$*" >&2; }

case "$PG_DUMP" in
  superset | airflow | all) ;;
  *)
    echo "usage: PG_DUMP=superset|airflow|all $0" >&2
    exit 2
    ;;
esac

command -v kubectl >/dev/null 2>&1 || { err "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq is required (the CronJob is read as JSON)"; exit 1; }

scratch_pod=""
verify_job=""

cleanup() {
  if [ "${KEEP_SCRATCH:-0}" = 1 ]; then return 0; fi
  if [ -n "$scratch_pod" ]; then
    kubectl -n "$NAMESPACE" delete pod "$scratch_pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    scratch_pod=""
  fi
  if [ -n "$verify_job" ]; then
    kubectl -n "$NAMESPACE" delete job "$verify_job" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    verify_job=""
  fi
}
trap cleanup EXIT

# The log of a failed Job: both containers, bounded. Nothing in these logs is a
# credential (the password is read from a mounted file, the S3 keys are env
# references the process never prints).
job_logs() {
  local job="$1" pod
  pod="$(kubectl -n "$NAMESPACE" get pods -l "job-name=$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || { err "no pod for job/$job (check 'kubectl -n $NAMESPACE describe job/$job')"; return 0; }
  printf -- '-- init pg-dump --\n' >&2
  kubectl -n "$NAMESPACE" logs "$pod" -c pg-dump --tail=40 >&2 2>&1 || true
  printf -- '-- upload --\n' >&2
  kubectl -n "$NAMESPACE" logs "$pod" -c upload --tail=40 >&2 2>&1 || true
}

# Wait for a Job to finish without blocking for the whole timeout on a failure
# (`kubectl wait --for=condition=complete` would).
wait_job() {
  local job="$1" deadline=$(( $(date -u +%s) + 960 )) state succeeded failed
  while [ "$(date -u +%s)" -lt "$deadline" ]; do
    state="$(kubectl -n "$NAMESPACE" get job "$job" \
      -o jsonpath='{.status.succeeded}{"|"}{.status.failed}' 2>/dev/null || true)"
    IFS='|' read -r succeeded failed <<<"$state"
    if [ "${succeeded:-0}" -ge 1 ]; then return 0; fi
    if [ "${failed:-0}" -ge 1 ]; then return 1; fi
    sleep 5
  done
  return 1
}

# Same for the restore pod: a Failed phase must end the wait, not sit out the
# timeout.
wait_pod() {
  local pod="$1" deadline=$(( $(date -u +%s) + 600 )) phase
  while [ "$(date -u +%s)" -lt "$deadline" ]; do
    phase="$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded) return 0 ;;
      Failed) return 1 ;;
    esac
    sleep 5
  done
  return 1
}

# One target: run its CronJob, then restore the newest object it wrote.
check_one() {
  local app="$1" cronjob="${1}-pg-dump" cronjob_json
  local host port db user secret key bucket image_dump image_upload major
  local endpoint='{"secretKeyRef":{"name":"stardelt-s3-creds","key":"endpoint"}}'
  local access='{"secretKeyRef":{"name":"stardelt-s3-creds","key":"access-key"}}'
  local secretkey='{"secretKeyRef":{"name":"stardelt-s3-creds","key":"secret-key"}}'
  local region='{"secretKeyRef":{"name":"stardelt-s3-creds","key":"region"}}'
  local pod_spec fetch_script restore_script
  local fetch_out restore_out object_key object_size object_age restored live

  # A previous target's scratch objects (a failed one included) go before this
  # target starts, so a run never leaves more than its own scratch behind.
  cleanup

  info "[$app] CronJob $NAMESPACE/$cronjob"
  if ! cronjob_json="$(kubectl -n "$NAMESPACE" get cronjob "$cronjob" -o json 2>/dev/null)"; then
    err "[$app] no CronJob $NAMESPACE/$cronjob — apply it with 'make backups' (or 'kubectl apply -f manifests/pg-dump-backup.yaml')"
    return 1
  fi

  # Everything below comes from the *live* CronJob, so this check verifies what
  # is deployed, not a copy of the manifest kept in this script.
  IFS=$'\t' read -r host port db user secret key bucket image_dump image_upload <<<"$(
    jq -r '
      (.spec.jobTemplate.spec.template.spec.initContainers[0].env) as $env
      | (.spec.jobTemplate.spec.template.spec.volumes | map(select(.name == "pg-secret"))[0].secret) as $sec
      | (.spec.jobTemplate.spec.template.spec.containers | map(select(.name == "upload"))[0]) as $up
      | [
          ($env | map(select(.name == "PGHOST"))[0].value),
          ($env | map(select(.name == "PGPORT"))[0].value),
          ($env | map(select(.name == "PGDATABASE"))[0].value),
          ($env | map(select(.name == "PGUSER"))[0].value),
          $sec.secretName,
          $sec.items[0].key,
          ($up.env | map(select(.name == "BACKUP_BUCKET"))[0].value),
          (.spec.jobTemplate.spec.template.spec.initContainers[0].image),
          $up.image
        ] | @tsv' <<<"$cronjob_json")"
  major="${image_dump%%@*}"       # drop a digest, if the image is pinned
  major="${major##*/}"             # postgresql:14.17.0-debian-12-r3
  major="${major##*:}"             # 14.17.0-debian-12-r3
  major="${major%%.*}"             # 14
  case "$major" in
    '' | *[!0-9]*)
      err "[$app] cannot derive the server major version from the dump image '$image_dump' — set RESTORE_IMAGE"
      return 1
      ;;
  esac
  restore_image="${RESTORE_IMAGE:-docker.io/library/postgres:${major}}"

  info "[$app] running it once (job template of the schedule)"
  verify_job="${cronjob}-verify-$(date -u +%s)"
  if ! kubectl -n "$NAMESPACE" create job --from="cronjob/$cronjob" "$verify_job" >/dev/null; then
    err "[$app] could not create a Job from cronjob/$cronjob"
    return 1
  fi
  if ! wait_job "$verify_job"; then
    err "[$app] the Job did not complete — the dump is not being written:"
    job_logs "$verify_job"
    return 1
  fi
  kubectl -n "$NAMESPACE" logs "job/$verify_job" -c upload --tail=10 2>/dev/null || true
  ok "[$app] Job $verify_job completed"

  fetch_script="$(cat <<'FETCH'
set -eu
prefix="pgdump/${APP}/"
s3() { aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }
now="$(date -u +%s)"
# `Contents` is null when nothing has been uploaded yet: --output text then
# prints the literal `None`, which the awk below drops.
listing="$(s3 s3api list-objects-v2 --bucket "$BACKUP_BUCKET" --prefix "$prefix" \
  --query 'Contents[].[Key,LastModified,Size]' --output text)"
newest="$(printf '%s\n' "$listing" \
  | awk 'NF == 3 && $2 ~ /^[0-9]{4}-/ { printf "%s\t%s\t%s\n", $2, $1, $3 }' \
  | sort | tail -n 1)"
if [ -z "$newest" ]; then
  echo "FAIL no object under s3://$BACKUP_BUCKET/$prefix/" >&2
  exit 1
fi
modified="$(printf '%s' "$newest" | cut -f1)"
key="$(printf '%s' "$newest" | cut -f2)"
size="$(printf '%s' "$newest" | cut -f3)"
age=$(( now - $(date -u -d "$modified" +%s) ))
echo "OBJECT key=$key size=$size age=$age modified=$modified"
s3 s3 cp "s3://$BACKUP_BUCKET/$key" /scratch/dump --no-progress --only-show-errors
FETCH
)"

  # The restore half: a throwaway server of the same major version on an
  # emptyDir, the dump restored into `restoretest` with --exit-on-error, then the
  # same table count query against the live database. --no-privileges on top of
  # the dump's --no-owner: the source cluster's roles and grants are identity,
  # not data, and the proof here is the schema and what fills it.
  restore_script="$(cat <<'RESTORE'
set -eu
export PATH="$PATH:/usr/lib/postgresql/${PG_MAJOR}/bin"
pgdata=/scratch/pgdata
run=/scratch/run
mkdir -p "$run"
initdb -D "$pgdata" -U postgres --auth=trust >/dev/null
pg_ctl -D "$pgdata" -o "-p 5433 -k $run" -l /scratch/pg.log -w start >/dev/null
createdb -h "$run" -p 5433 -U postgres restoretest
entries="$(pg_restore --list /scratch/dump | grep -c '^[0-9]' || true)"
echo "TOC=${entries:-0}"
pg_restore -h "$run" -p 5433 -U postgres -d restoretest \
  --no-owner --no-privileges --exit-on-error /scratch/dump
restored="$(psql -h "$run" -p 5433 -U postgres -d restoretest -Atc \
  "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")"
live="$(PGPASSWORD="$(cat "$PGPASSWORD_FILE")" psql -h "$LIVE_HOST" -p "$LIVE_PORT" -U "$LIVE_USER" -d "$LIVE_DB" -Atc \
  "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")"
echo "TABLES=$restored"
echo "LIVE_TABLES=$live"
RESTORE
)"

  scratch_pod="pgdump-restore-${app}-$$"
  pod_spec="$(jq -n \
    --arg name "$scratch_pod" --arg ns "$NAMESPACE" \
    --arg app "$app" --arg bucket "$bucket" \
    --arg fetch_image "$image_upload" --arg fetch_script "$fetch_script" \
    --arg restore_image "$restore_image" --arg restore_script "$restore_script" \
    --arg major "$major" \
    --arg host "$host" --arg port "$port" --arg db "$db" --arg user "$user" \
    --arg secret "$secret" --arg key "$key" \
    --argjson endpoint "$endpoint" --argjson access "$access" \
    --argjson secretkey "$secretkey" --argjson region "$region" \
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
        initContainers: [{
          name: "fetch",
          image: $fetch_image,
          command: ["/bin/sh", "-ec"],
          args: [$fetch_script],
          env: [
            { name: "APP", value: $app },
            { name: "BACKUP_BUCKET", value: $bucket },
            { name: "HOME", value: "/scratch" },
            { name: "AWS_ENDPOINT_URL", valueFrom: $endpoint },
            { name: "AWS_ACCESS_KEY_ID", valueFrom: $access },
            { name: "AWS_SECRET_ACCESS_KEY", valueFrom: $secretkey },
            { name: "AWS_DEFAULT_REGION", valueFrom: $region }
          ],
          securityContext: {
            allowPrivilegeEscalation: false, readOnlyRootFilesystem: true,
            capabilities: { drop: ["ALL"] }
          },
          resources: { requests: { cpu: "50m", memory: "64Mi" }, limits: { cpu: "500m", memory: "512Mi" } },
          volumeMounts: [{ name: "scratch", mountPath: "/scratch" }]
        }],
        containers: [{
          name: "restore",
          image: $restore_image,
          command: ["/bin/bash", "-ec"],
          args: [$restore_script],
          env: [
            { name: "PG_MAJOR", value: $major },
            { name: "LIVE_HOST", value: $host },
            { name: "LIVE_PORT", value: $port },
            { name: "LIVE_DB", value: $db },
            { name: "LIVE_USER", value: $user },
            { name: "PGPASSWORD_FILE", value: "/run/pg-secret/password" }
          ],
          securityContext: {
            allowPrivilegeEscalation: false, readOnlyRootFilesystem: true,
            capabilities: { drop: ["ALL"] }
          },
          resources: { requests: { cpu: "100m", memory: "128Mi" }, limits: { cpu: "500m", memory: "512Mi" } },
          volumeMounts: [
            { name: "scratch", mountPath: "/scratch" },
            { name: "pg-secret", mountPath: "/run/pg-secret", readOnly: true }
          ]
        }],
        volumes: [
          { name: "scratch", emptyDir: {} },
          { name: "pg-secret", secret: { secretName: $secret, items: [{ key: $key, path: "password" }] } }
        ]
      }
    }')"

  info "[$app] restoring the newest dump with $restore_image"
  if ! printf '%s' "$pod_spec" | kubectl -n "$NAMESPACE" apply -f - >/dev/null; then
    err "[$app] could not create the restore pod"
    return 1
  fi
  if ! wait_pod "$scratch_pod"; then
    err "[$app] the restore pod did not succeed:"
    kubectl -n "$NAMESPACE" logs "$scratch_pod" -c fetch --tail=20 >&2 2>&1 || true
    kubectl -n "$NAMESPACE" logs "$scratch_pod" -c restore --tail=20 >&2 2>&1 || true
    return 1
  fi

  fetch_out="$(kubectl -n "$NAMESPACE" logs "$scratch_pod" -c fetch)"
  restore_out="$(kubectl -n "$NAMESPACE" logs "$scratch_pod" -c restore)"
  read -r object_key object_size object_age <<<"$(
    printf '%s\n' "$fetch_out" | awk '
      $1 == "OBJECT" {
        for (i = 2; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
      }
      END { printf "%s %s %s\n", f["key"], f["size"], f["age"] }')"
  restored="$(printf '%s\n' "$restore_out" | awk -F= '$1 == "TABLES" { print $2 }')"
  live="$(printf '%s\n' "$restore_out" | awk -F= '$1 == "LIVE_TABLES" { print $2 }')"

  if [ -z "$object_key" ]; then
    err "[$app] the fetch container produced no OBJECT line:"
    printf '%s\n' "$fetch_out" >&2
    return 1
  fi
  if [ "${object_size:-0}" -le "$MIN_SIZE_BYTES" ]; then
    err "[$app] newest dump ${object_key} is ${object_size} bytes — not larger than MIN_SIZE_BYTES=$MIN_SIZE_BYTES"
    return 1
  fi
  if [ "${object_age:-$(( MAX_AGE_SECONDS + 1 ))}" -gt "$MAX_AGE_SECONDS" ]; then
    err "[$app] newest dump ${object_key} is ${object_age}s old — older than MAX_AGE_SECONDS=$MAX_AGE_SECONDS (did the CronJob run?)"
    return 1
  fi
  if [ -z "$restored" ] || [ -z "$live" ]; then
    err "[$app] the restore produced no table count:"
    printf '%s\n' "$restore_out" >&2
    return 1
  fi
  if [ "$restored" != "$live" ]; then
    err "[$app] restored $restored table(s), live database has $live — the dump is not a copy of it"
    return 1
  fi

  ok "[$app] ${object_key} (${object_size} bytes, ${object_age}s old) restored into restoretest: ${restored} tables == live ${live}"
  cleanup
  return 0
}

failed=0
apps=(superset airflow)
[ "$PG_DUMP" = all ] || apps=("$PG_DUMP")
for app in "${apps[@]}"; do
  if ! check_one "$app"; then
    failed=$(( failed + 1 ))
  fi
done

if [ "$failed" -gt 0 ]; then
  echo "verify-pgdump: FAILED ($failed target(s))" >&2
  exit 1
fi
echo "verify-pgdump: OK"
