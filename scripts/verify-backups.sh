#!/usr/bin/env bash
# Verify that the catalog's Postgres is actually streaming WAL into the object store.
#
#   make verify-backups                 # full check
#   make verify-backup-config           # config only — the post-apply guard
#   bash scripts/verify-backups.sh --config-only
#
# Why this exists (stardelt-platform#59): `kubectl apply` is client-side apply, so
# applying a manifest whose `backup:` block is missing *removes* spec.backup from the
# live Cluster. CloudNativePG then turns archive_command into a successful no-op:
# pg_stat_archiver keeps counting successes, `kubectl get backups` says `completed`,
# `ContinuousArchiving` stays `True` — and the bucket silently stops growing. Each of
# those signals is individually reassuring, which is why this check compares the
# *bucket* against the *database* instead of trusting either:
#
#   (a) the live Cluster declares spec.backup.barmanObjectStore.destinationPath
#   (b) the newest object under <destinationPath>/<cluster>/wals/ is younger than
#       MAX_AGE_SECONDS (default 900 = 3 missed 5 min archive_timeout windows)
#   (c) pg_stat_archiver.last_archived_wal — read *before* the listing — appears as an
#       object under wals/. A no-op archiver advances last_archived_wal while the
#       bucket stays behind; that disagreement is what the incident produced.
#
# What it cannot see:
#   - A *closed* gap. If archiving was dead for hours and then resumed (the #59
#     repair), the newest object is fresh and last_archived_wal is present; the
#     segments that never made it are a hole between the last base backup and the
#     resumed stream. The repair for that is a fresh base backup, not a check.
#   - Anything, when nobody runs it. (b) is only as good as its cadence; an alerting
#     wrapper is future work on #59.
#
# The bucket is listed by a one-shot amazon/aws-cli pod in $NAMESPACE, using the
# endpoint and credentials the live Cluster declares (the S3 endpoint is
# cluster-internal, so a local aws-cli cannot reach it).
#
# Environment:
#   NAMESPACE         default stardelt
#   CLUSTER           default lakekeeper-pg
#   MAX_AGE_SECONDS   default 900
#   SKIP_OBJECTS=1    skip (b)+(c) — for environments without S3 credentials or
#                     access; (a) still runs. Deliberate escape, not a way to make
#                     a red check green.
#   S3_CHECK_IMAGE    image for the listing pod (default amazon/aws-cli:2.17.0,
#                     same as the platform's own S3 jobs)
#
# Exit status: 0 only if every check that ran passed.
set -euo pipefail

NAMESPACE="${NAMESPACE:-stardelt}"
CLUSTER="${CLUSTER:-lakekeeper-pg}"
MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-900}"
S3_CHECK_IMAGE="${S3_CHECK_IMAGE:-amazon/aws-cli:2.17.0}"
SKIP_OBJECTS="${SKIP_OBJECTS:-}"

CONFIG_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --config-only) CONFIG_ONLY=1 ;;
    *)
      echo "usage: $0 [--config-only]" >&2
      exit 2
      ;;
  esac
done

ok()   { printf '✓ %s\n' "$*"; }
info() { printf '› %s\n' "$*"; }
err()  { printf '✗ %s\n' "$*" >&2; }

cluster_jsonpath() {
  kubectl -n "$NAMESPACE" get cluster "$CLUSTER" -o jsonpath="$1"
}

if ! kubectl -n "$NAMESPACE" get cluster "$CLUSTER" >/dev/null 2>&1; then
  err "cannot read Cluster $NAMESPACE/$CLUSTER (kube-context: $(kubectl config current-context 2>/dev/null || echo none))"
  exit 1
fi

# ---------------------------------------------------------------------------
# (a) The live object still declares its backup config. This is the check the
#     install targets run right after `kubectl apply -f manifests/cnpg-postgres.yaml`.
# ---------------------------------------------------------------------------
backup="$(cluster_jsonpath '{.spec.backup}')"
barman="$(cluster_jsonpath '{.spec.backup.barmanObjectStore}')"
destination="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.destinationPath}')"

missing=""
if [ -z "$backup" ]; then
  missing="spec.backup"
elif [ -z "$barman" ]; then
  missing="spec.backup.barmanObjectStore"
elif [ -z "$destination" ]; then
  missing="spec.backup.barmanObjectStore.destinationPath"
fi

if [ -n "$missing" ]; then
  {
    echo "✗ $NAMESPACE/$CLUSTER: $missing is missing (or empty) after the apply."
    echo "✗"
    echo "✗   Without it, CloudNativePG's archive_command exits 0 without uploading:"
    echo "✗   pg_stat_archiver counts successful archives, every condition and every"
    echo "✗   'kubectl get backups' stays green, and nothing reaches the object store —"
    echo "✗   a restore silently stops at the last object that made it (#59)."
    echo "✗   Likely cause: the applied manifest came from an out-of-date checkout."
    echo "✗"
    echo "✗ Repair (this check never edits anything itself):"
    echo "✗   1. apply the declaration from an up-to-date main checkout:"
    echo "✗        git fetch origin && git switch main && git pull --ff-only"
    echo "✗        kubectl -n $NAMESPACE apply -f manifests/cnpg-postgres.yaml"
    echo "✗   2. if the config was absent for any length of time, start a fresh chain —"
    echo "✗      WAL archived during the gap is not recoverable:"
    echo "✗        kubectl -n $NAMESPACE delete scheduledbackup lakekeeper-pg-daily"
    echo "✗        kubectl -n $NAMESPACE apply -f manifests/cnpg-backup-schedule.yaml"
    echo "✗   3. re-check with: make verify-backups"
  } >&2
  exit 1
fi

ok "spec.backup is declared (barmanObjectStore → $destination)"

if [ "$CONFIG_ONLY" = 1 ]; then
  info "S3 checks skipped (--config-only): the declared config is intact"
  exit 0
fi

if [ -n "$SKIP_OBJECTS" ] && [ "$SKIP_OBJECTS" != 0 ]; then
  info "SKIP_OBJECTS=$SKIP_OBJECTS: checks (b)+(c) skipped on request; only (a) ran"
  exit 0
fi

case "$destination" in
  s3://*) ;;
  *)
    err "destinationPath '$destination' is not s3:// — this check only speaks S3 (SKIP_OBJECTS=1 skips it deliberately)."
    exit 1
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required for the bucket checks (SKIP_OBJECTS=1 skips them deliberately)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Read the database *before* listing the bucket: everything Postgres reports as
# archived is then guaranteed to be older than the listing, so (c) can demand
# that last_archived_wal is present — no race.
# ---------------------------------------------------------------------------
primary="$(kubectl -n "$NAMESPACE" get pods \
  -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$primary" ]; then
  primary="$CLUSTER-1"
fi

if ! stats="$(kubectl -n "$NAMESPACE" exec "$primary" -c postgres -- \
  psql -U postgres -d postgres -At -F'|' -c \
  "select archived_count, failed_count, coalesce(last_archived_wal, ''), \
          coalesce(to_char(last_archived_time at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS'), '') \
   from pg_stat_archiver;" 2>&1)"; then
  err "cannot read pg_stat_archiver from $NAMESPACE/$primary:"
  printf '%s\n' "$stats" >&2
  exit 1
fi

IFS='|' read -r archived_count failed_count last_wal last_time <<<"$stats"

if [ -z "$last_wal" ]; then
  err "pg_stat_archiver has no last_archived_wal on $NAMESPACE/$CLUSTER ($archived_count archived, $failed_count failed)."
  err "  Postgres has not archived a WAL yet. A freshly created cluster uploads the first"
  err "  segment within archive_timeout (5 min); if this persists, archiving never started."
  exit 1
fi

info "archiver: $archived_count archived, $failed_count failed; last_archived_wal=$last_wal @ ${last_time}Z"

# ---------------------------------------------------------------------------
# (b)+(c) List the WAL tree with a one-shot pod that uses the Cluster's own
# endpoint/credentials — prepared via --overrides so no secret value ever lands
# in this process's argv or the local shell history.
# ---------------------------------------------------------------------------
pod_name="verify-backups-s3-$$"
wal_uri="${destination%/}/$CLUSTER/wals/"

access_name="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.s3Credentials.accessKeyId.name}')"
access_key="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.s3Credentials.accessKeyId.key}')"
secret_name="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.s3Credentials.secretAccessKey.name}')"
secret_key="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.s3Credentials.secretAccessKey.key}')"
region_name="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.s3Credentials.region.name}')"
region_key="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.s3Credentials.region.key}')"
endpoint="$(cluster_jsonpath '{.spec.backup.barmanObjectStore.endpointURL}')"

if [ -z "$access_name" ] || [ -z "$access_key" ] || [ -z "$secret_name" ] || [ -z "$secret_key" ]; then
  err "the Cluster declares no complete s3Credentials — cannot list the bucket (SKIP_OBJECTS=1 skips this deliberately)."
  exit 1
fi

# Runs inside the listing pod: print the pod's own idea of "now" (so the
# freshness comparison does not depend on the caller's clock), then the listing.
pod_command="$(cat <<'POD_SCRIPT'
now="$(date -u +%s)"
printf "NOW %s\n" "$now"
printf "DEADLINE %s\n" "$(date -u -d "@$(( now - MAX_AGE_SECONDS ))" "+%Y-%m-%d %H:%M:%S")"
if [ -n "${AWS_ENDPOINT_URL:-}" ]; then set -- --endpoint-url "$AWS_ENDPOINT_URL"; else set --; fi
aws s3 ls --recursive "$S3_WAL_URI" "$@"
POD_SCRIPT
)"

pod_spec="$(jq -n \
  --arg name "$pod_name" \
  --arg ns "$NAMESPACE" \
  --arg image "$S3_CHECK_IMAGE" \
  --arg cmd "$pod_command" \
  --arg wal_uri "$wal_uri" \
  --arg max_age "$MAX_AGE_SECONDS" \
  --arg endpoint "$endpoint" \
  --arg a_name "$access_name" --arg a_key "$access_key" \
  --arg s_name "$secret_name" --arg s_key "$secret_key" \
  --arg r_name "$region_name" --arg r_key "$region_key" \
  '{
    apiVersion: "v1", kind: "Pod",
    metadata: { name: $name, namespace: $ns },
    spec: {
      restartPolicy: "Never",
      containers: [{
        name: "s3ls",
        image: $image,
        command: ["sh", "-ec", $cmd],
        env: (
          [
            { name: "S3_WAL_URI", value: $wal_uri },
            { name: "MAX_AGE_SECONDS", value: $max_age },
            { name: "AWS_ACCESS_KEY_ID", valueFrom: { secretKeyRef: { name: $a_name, key: $a_key } } },
            { name: "AWS_SECRET_ACCESS_KEY", valueFrom: { secretKeyRef: { name: $s_name, key: $s_key } } }
          ]
          + (if $endpoint != "" then
               [{ name: "AWS_ENDPOINT_URL", value: $endpoint }]
             else [] end)
          + (if $r_name != "" then
               [{ name: "AWS_DEFAULT_REGION", valueFrom: { secretKeyRef: { name: $r_name, key: $r_key } } }]
             else
               [{ name: "AWS_DEFAULT_REGION", value: "us-east-1" }]
             end)
        )
      }]
    }
  }')"

info "listing $wal_uri from a one-shot $S3_CHECK_IMAGE pod"
if ! probe_out="$(kubectl -n "$NAMESPACE" run "$pod_name" \
  --rm --attach --quiet --restart=Never \
  --image "$S3_CHECK_IMAGE" \
  --pod-running-timeout=3m \
  --overrides "$pod_spec" 2>&1)"; then
  err "the in-cluster listing pod failed — bucket state unknown:"
  printf '%s\n' "$probe_out" >&2
  err "  (SKIP_OBJECTS=1 skips the bucket checks deliberately; fix the pod error if it is not expected.)"
  exit 1
fi

deadline="$(printf '%s\n' "$probe_out" | sed -n 's/^DEADLINE //p' | head -n 1)"
listing="$(printf '%s\n' "$probe_out" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' || true)"

if [ -z "$deadline" ]; then
  err "the listing pod produced no deadline — unexpected output:"
  printf '%s\n' "$probe_out" >&2
  exit 1
fi

count="$(printf '%s\n' "$listing" | grep -c . || true)"
if [ "$count" = 0 ]; then
  err "no objects under $wal_uri — nothing has ever been archived there."
  err "  Archiving is configured but has produced no bytes: check 'kubectl -n $NAMESPACE get backups'"
  err "  and the manager log, then take a fresh base backup once new WAL starts landing."
  exit 1
fi

# Lexicographic "YYYY-MM-DD HH:MM:SS" order equals chronological order, so awk can
# pick the newest object without any date arithmetic; note that barman label files
# (<segment>.<lsn>.backup.gz) sort *before* their plain segment, which is why the
# winner is chosen by timestamp and not by `tail -1` of the listing.
newest="$(printf '%s\n' "$listing" | awk '
  {
    stamp = $1 " " $2
    if (stamp > best) { best = stamp; key = $NF }
  }
  END { if (best != "") printf "%s|%s", best, key }')"
newest_stamp="${newest%%|*}"
newest_key="${newest##*|}"

if [[ "$newest_stamp" > "$deadline" ]]; then
  ok "newest WAL object $newest_key @ ${newest_stamp}Z is fresh (deadline ${deadline}Z, MAX_AGE_SECONDS=$MAX_AGE_SECONDS)"
else
  err "newest object under $wal_uri is $newest_key @ ${newest_stamp}Z — older than MAX_AGE_SECONDS=$MAX_AGE_SECONDS (deadline ${deadline}Z)."
  err "  The bucket is not receiving WAL. pg_stat_archiver and the operator's conditions"
  err "  can still look healthy while this is true (#59); investigate before trusting a restore."
  exit 1
fi

matching_key="$(printf '%s\n' "$listing" | awk -v wal="$last_wal" '
  {
    n = split($NF, parts, "/")
    if (index(parts[n], wal) == 1) { print parts[n]; exit }
  }')"

if [ -z "$matching_key" ]; then
  err "pg_stat_archiver.last_archived_wal ($last_wal @ ${last_time}Z) is NOT present under $wal_uri"
  err "  (newest object there: $newest_key @ ${newest_stamp}Z). The database and the bucket"
  err "  disagree about what was archived — exactly the no-op failure mode from #59."
  exit 1
fi

ok "last_archived_wal $last_wal matches object $matching_key"
echo "verify-backups: OK"
