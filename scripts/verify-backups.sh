#!/usr/bin/env bash
# Verify that the catalog's Postgres is actually streaming WAL into the object store.
#
#   make verify-backups                 # full check
#   make verify-backup-config           # config only — the post-apply guard
#   bash scripts/verify-backups.sh --config-only
#   bash scripts/verify-backups.sh --self-test   # exercise the archive_covers() rule, no cluster
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
#   (b) the bucket has everything Postgres *asked* to archive: the current WAL
#       segment is archived, or the segment before it is and pg_wal/archive_status
#       holds no .ready file. A segment that holds no records is never switched by
#       archive_timeout, so an idle cluster passes at any age; a queued segment
#       that is missing from the bucket is a gap. (The old wall-clock freshness
#       test could not tell a quiet store from a dead archiver: both look old.)
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
#   CLUSTER           default lakekeeper-pg — the CloudNative-PG Cluster name.
#                     Invoked through make, PG_CLUSTER wins and is passed as
#                     CLUSTER here, because stardelt-demos exports CLUSTER for
#                     the *kind* cluster and that would otherwise be read as this
#                     Cluster (#76).
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
S3_CHECK_IMAGE="${S3_CHECK_IMAGE:-amazon/aws-cli:2.17.0}"
SKIP_OBJECTS="${SKIP_OBJECTS:-}"
SELF_TEST=0

CONFIG_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --config-only) CONFIG_ONLY=1 ;;
    --self-test) SELF_TEST=1 ;;
    *)
      echo "usage: $0 [--config-only|--self-test]" >&2
      exit 2
      ;;
  esac
done

ok()   { printf '✓ %s\n' "$*"; }
info() { printf '› %s\n' "$*"; }
err()  { printf '✗ %s\n' "$*" >&2; }

segment_of() {
  # The WAL segment a bucket key names: `<prefix>/<segment>[.<lsn>.backup].gz` → `<segment>`.
  local base="${1##*/}"
  base="${base%.gz}"
  printf '%s' "${base%%.*}"
}

previous_segment() {
  # The 24-character segment name one before $1 (the last 8 hex digits carry the number).
  local head="${1:0:16}" tail="${1:16:8}"
  printf '%s%08X' "$head" $(( (16#$tail - 1) & 0xFFFFFFFF ))
}

archive_covers() {
  # 0 when the bucket has everything PostgreSQL *asked* to archive: the current segment is
  # archived (quiet store), or the segment before it is archived and nothing is queued for
  # archiving (`ready` = number of `.ready` files in pg_wal/archive_status). A segment that
  # holds no records is never switched, so `previous` + ready=0 is healthy at any age.
  local current="$1" newest="$2" ready="$3"
  [ "$newest" = "$current" ] && return 0
  [ "$newest" = "$(previous_segment "$current")" ] && [ "$ready" = 0 ] && return 0
  return 1
}

if [ "$SELF_TEST" = 1 ]; then
  failures=0
  expect() { # expect <0|1> <label> <current> <newest> <ready>
    local want="$1" label="$2"; shift 2
    if archive_covers "$@"; then got=0; else got=1; fi
    if [ "$got" = "$want" ]; then ok "self-test: $label"; else err "self-test: $label (wanted $want, got $got)"; failures=$((failures + 1)); fi
  }
  check_eq() { # check_eq <label> <actual> <expected>
    if [ "$2" = "$3" ]; then ok "self-test: $1"; else err "self-test: $1 (got '$2')"; failures=$((failures + 1)); fi
  }
  check_eq 'plain key' "$(segment_of 'openfga-pg/wals/0000000100000000/0000000100000000000000C9.gz')" '0000000100000000000000C9'
  check_eq 'label key' "$(segment_of 'openfga-pg/wals/0000000100000000/0000000100000000000000C9.00000028.backup.gz')" '0000000100000000000000C9'
  check_eq 'previous segment' "$(previous_segment '0000000100000000000000CA')" '0000000100000000000000C9'
  expect 0 'quiet store: current segment archived' '0000000100000000000000C9' '0000000100000000000000C9' 0
  expect 0 'open, empty segment: previous archived, nothing queued' '0000000100000000000000CA' '0000000100000000000000C9' 0
  expect 1 'dead archiver: a segment is queued' '0000000100000000000000CA' '0000000100000000000000C9' 1
  expect 1 'dead archiver: two segments behind' '0000000100000000000000CB' '0000000100000000000000C9' 0
  exit "$failures"
fi

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
          coalesce(to_char(last_archived_time at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS'), ''), \
          coalesce(pg_walfile_name(pg_current_wal_lsn()), ''), \
          (select count(*) from pg_ls_archive_statusdir() where name like '%.ready') \
   from pg_stat_archiver;" 2>&1)"; then
  err "cannot read pg_stat_archiver from $NAMESPACE/$primary:"
  printf '%s\n' "$stats" >&2
  exit 1
fi

IFS='|' read -r archived_count failed_count last_wal last_time current_seg ready_count <<<"$stats"

if [ -z "$current_seg" ]; then
  err "cannot read the current WAL segment from $NAMESPACE/$CLUSTER."
  exit 1
fi

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

# Runs inside the listing pod: the recursive listing of the WAL prefix.
pod_command="$(cat <<'POD_SCRIPT'
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

listing="$(printf '%s\n' "$probe_out" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' || true)"

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

newest_seg="$(segment_of "$newest_key")"
if archive_covers "$current_seg" "$newest_seg" "$ready_count"; then
  ok "the archive has everything PostgreSQL queued: current WAL segment $current_seg, newest archived $newest_seg, $ready_count .ready file(s) (newest object $newest_key @ ${newest_stamp}Z)"
else
  err "the archive is behind PostgreSQL: current WAL segment $current_seg, newest archived segment $newest_seg, $ready_count .ready file(s) waiting (newest object $newest_key @ ${newest_stamp}Z)."
  err "  A segment is queued for archiving but is not in the bucket — investigate before trusting a restore (#59)."
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
