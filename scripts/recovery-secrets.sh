#!/usr/bin/env bash
# The keys that make the backups restorable (platform#396, design platform#368).
#
#   make export-recovery-secrets FILE=/media/usb/stardelt-recovery.enc
#   make import-recovery-secrets FILE=/media/usb/stardelt-recovery.enc CHECK=1
#   bash scripts/recovery-secrets.sh names
#
# Why this exists: every other backup target copies data. The data is only
# readable with keys that exist solely as Secrets in the cluster's own
# datastore — the OpenBao seal key without which its pebbledb directory cannot
# be opened at all, Lakekeeper's warehouse-secret key, Airflow's fernet key, the
# object store's credentials and the identity provider's administrator
# passwords. Lose the node and the databases restore; without these keys their
# contents do not. One encrypted file, kept outside the cluster and outside the
# backup buckets, is the difference between a backup and a copy.
#
#   export <file>   read the Secrets listed in RECOVERY_SECRETS, reduce each to
#                   apiVersion/kind/metadata.name/metadata.namespace/type/data,
#                   and encrypt the list into <file> (mode 0600)
#   import <file>   decrypt in memory and `kubectl apply` into $NAMESPACE
#                   (default stardelt); --check decrypts and lists the names
#                   without applying; prints names, never a value
#   names           print the Secret names this file exports
#
# The passphrase comes from $RECOVERY_PASSPHRASE only (16 characters or more)
# and is never written anywhere: not into the file, not onto a command line
# (`-pass env:`), not into a log. The decrypted list never touches the disk.
# The export refuses a <file> inside the repository work tree — a key backup
# does not belong in git, and a file this repository can see is a file that can
# be committed by accident.
#
# A missing Secret is reported and dropped, never invented: a cluster without
# Keycloak (or without OpenBao) exports the subset it has and says which names
# are absent, so a restore of a partial install does not silently look complete.
#
# The document is a JSON `kind: List`, which is also YAML: kubectl reads it as
# is, and `jq` can list the names without a YAML parser in `make deps`.
set -euo pipefail

# The Secrets whose loss makes a backup unreadable. Seven, checked against the
# live namespace when this was written (platform#396): the seal key and the
# init material of the secret store, the two application encryption keys, the
# object store's credentials, and the two administrator passwords of the IdP.
# Secrets that a script regenerates (stardelt-oidc-clients, stardelt-nova-session,
# TLS, *-pg-*) are deliberately not here.
RECOVERY_SECRETS=(
  openbao-seal-key
  openbao-init
  lakekeeper-postgres-encryption
  airflow-fernet-key
  stardelt-s3-creds
  keycloak-admin
  stardelt-realm-admin
)

NAMESPACE="${NAMESPACE:-stardelt}"
PASSPHRASE_VAR=RECOVERY_PASSPHRASE
MIN_PASSPHRASE_CHARS=16

# AES-256-CBC with PBKDF2 (600k iterations) and a random salt. Both parameters
# are recorded in the file header, so `import` needs nothing but the passphrase;
# they are fixed here so export and import cannot drift apart.
CIPHER=(-aes-256-cbc -pbkdf2 -iter 600000 -salt)

TMP_FILE=
cleanup() {
  [ -z "$TMP_FILE" ] || rm -f -- "$TMP_FILE"
}

die() {
  echo "recovery-secrets: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF' >&2
usage: recovery-secrets.sh export <file>
       recovery-secrets.sh import [--check] <file>
       recovery-secrets.sh names

environment:
  RECOVERY_PASSPHRASE   the passphrase that encrypts <file>; required, 16+ chars
  NAMESPACE             namespace the Secrets are read from / applied to
                        (default stardelt)
  FORCE=1               overwrite an existing <file> (export)
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found (run 'make deps')"
}

require_passphrase() {
  local value="${RECOVERY_PASSPHRASE-}"
  [ -n "$value" ] \
    || die "$PASSPHRASE_VAR is not set — export a passphrase of at least $MIN_PASSPHRASE_CHARS characters (and never store it with the file)"
  [ "${#value}" -ge "$MIN_PASSPHRASE_CHARS" ] \
    || die "$PASSPHRASE_VAR is shorter than $MIN_PASSPHRASE_CHARS characters"
}

# Absolute path of <file>, refusing anything inside the repository's work tree.
# The path is resolved against the caller's cwd before anything else, so a
# relative FILE means what it means on the command line.
resolve_file() {
  local arg="${1-}" abs repo
  [ -n "$arg" ] || die "missing <file>"
  abs="$(realpath -m -- "$arg")"
  [ -n "$abs" ] || die "cannot resolve $arg"
  repo="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo" ]; then
    case "$abs" in
      "$repo" | "$repo"/*)
        die "refusing $abs: it is inside the repository work tree ($repo) — a key backup must not be committed"
        ;;
    esac
  fi
  printf '%s\n' "$abs"
}

cmd_names() {
  [ "$#" -eq 0 ] || { usage; exit 2; }
  printf '%s\n' "${RECOVERY_SECRETS[@]}"
}

cmd_export() {
  [ "$#" -eq 1 ] || { usage; exit 2; }
  local file name
  file="$(resolve_file "$1")"
  require_tool kubectl
  require_tool jq
  require_tool openssl
  require_passphrase

  if [ -e "$file" ]; then
    [ "${FORCE:-}" = 1 ] \
      || die "$file exists — move it away, or re-run with FORCE=1 to overwrite"
    # Close the window in which an older, wider mode survives the rewrite.
    chmod 600 -- "$file"
  fi

  local -a present=() missing=()
  for name in "${RECOVERY_SECRETS[@]}"; do
    if kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
      present+=("$name")
    else
      missing+=("$name")
    fi
  done
  for name in "${missing[@]}"; do
    echo "› skipped $name: Secret not found in namespace $NAMESPACE" >&2
  done
  [ "${#present[@]}" -gt 0 ] \
    || die "none of the recovery Secrets exist in namespace $NAMESPACE — nothing to export"

  # Reduce and assemble in one pass: kubectl emits the full object (uid,
  # resourceVersion, ownerReferences, annotations, managed fields), jq keeps
  # only what `kubectl apply` needs and sorts the keys for a stable file.
  local doc
  if ! doc="$(
    for name in "${present[@]}"; do
      kubectl -n "$NAMESPACE" get secret "$name" -o json
    done | jq -s -S '{
      apiVersion: "v1",
      kind: "List",
      items: [ .[] | {
        apiVersion: .apiVersion,
        kind: .kind,
        metadata: { name: .metadata.name, namespace: .metadata.namespace },
        type: .type,
        data: .data
      } ]
    }'
  )"; then
    die "reading or reducing the Secrets failed"
  fi

  # mktemp in the destination directory, then `mv`: a failed encryption never
  # leaves a half-written file at the path the operator will later trust.
  umask 077
  TMP_FILE="$(mktemp -- "${file}.XXXXXX")"
  chmod 600 -- "$TMP_FILE"
  printf '%s\n' "$doc" \
    | openssl enc "${CIPHER[@]}" -pass "env:$PASSPHRASE_VAR" -out "$TMP_FILE" \
    || die "encryption failed"
  chmod 600 -- "$TMP_FILE"
  mv -f -- "$TMP_FILE" "$file"
  TMP_FILE=
  chmod 600 -- "$file"

  echo "exported ${#present[@]} secrets to $file (names: ${present[*]})"
}

cmd_import() {
  local check=0 file="" arg
  for arg in "$@"; do
    case "$arg" in
      --check) check=1 ;;
      -*) usage; exit 2 ;;
      *)
        [ -z "$file" ] || { usage; exit 2; }
        file="$arg"
        ;;
    esac
  done
  [ -n "$file" ] || { usage; exit 2; }
  file="$(resolve_file "$file")"
  [ -f "$file" ] || die "no such file: $file"
  require_tool kubectl
  require_tool jq
  require_tool openssl
  require_passphrase

  # Decrypt into a shell variable, never a file: the names must be inspected
  # (and a wrong passphrase must fail) *before* anything reaches `kubectl apply`.
  local plaintext
  if ! plaintext="$(openssl enc -d "${CIPHER[@]}" -pass "env:$PASSPHRASE_VAR" -in "$file" 2>/dev/null)"; then
    die "cannot decrypt $file — wrong passphrase, or not a file written by 'export'"
  fi

  local names_raw
  if ! names_raw="$(printf '%s\n' "$plaintext" | jq -r '.items[].metadata.name' 2>/dev/null)"; then
    die "cannot decrypt $file — wrong passphrase, or not a file written by 'export'"
  fi
  local -a names=()
  if [ -n "$names_raw" ]; then
    mapfile -t names <<<"$names_raw"
  fi
  [ "${#names[@]}" -gt 0 ] \
    || die "$file contains no Secrets — wrong passphrase, or not a file written by 'export'"

  if [ "$check" = 1 ]; then
    echo "checked ${#names[@]} secrets in $file (names: ${names[*]})"
    return 0
  fi

  # The namespace flag is authoritative: a file exported from another namespace
  # lands in this one, and kubectl does not reject a mismatch inside a List.
  if ! printf '%s\n' "$plaintext" \
    | jq --arg ns "$NAMESPACE" '.items[].metadata.namespace = $ns' \
    | kubectl apply -f - >/dev/null; then
    die "applying the Secrets to namespace $NAMESPACE failed"
  fi
  echo "applied ${#names[@]} secrets to namespace $NAMESPACE (names: ${names[*]})"
}

trap cleanup EXIT

case "${1-}" in
  export) shift; cmd_export "$@" ;;
  import) shift; cmd_import "$@" ;;
  names) shift; cmd_names "$@" ;;
  -h | --help | help) usage ;;
  *) usage; exit 2 ;;
esac
