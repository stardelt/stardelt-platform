#!/usr/bin/env bash
# Generate the data-plane credentials once, against the current kube-context.
# Called by `make install` and `make install-core` before SeaweedFS is installed;
# safe to re-run.
#
#   NAMESPACE=stardelt bash scripts/s3-secrets.sh
#
# A credential is generated only when its Secret does not exist, so a re-run never
# rotates anything. To rotate, delete the Secrets named below and install again
# (docs: operations/rotating-secrets). Values go through mode-0600 temp files and
# are never put on a command line or printed. Read one back deliberately with e.g.
#   kubectl -n stardelt get secret stardelt-s3-creds -o jsonpath='{.data.access-key}' | base64 -d
#
# Secrets (all labelled app.kubernetes.io/part-of=stardelt):
#   stardelt-s3-creds     access-key secret-key endpoint bucket region
#                         read by Trino, Lakekeeper bootstrap, Airflow, CNPG backups
#   seaweedfs-s3-config   seaweedfs_s3_config (S3 identities JSON)
#                         read by the SeaweedFS S3 gateway (helm-values/seaweedfs.yaml,
#                         s3.existingConfigSecret)
#   seaweedfs-admin-ui   user password   read by the SeaweedFS admin UI (helm-values/seaweedfs.yaml, admin.secret)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"

command -v openssl >/dev/null 2>&1 || { echo "s3-secrets: openssl not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "s3-secrets: kubectl not found" >&2; exit 1; }

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# rand BYTES -> 2*BYTES hex characters. Hex needs no escaping in JSON or YAML.
rand() { openssl rand -hex "$1"; }

secret_exists() { kubectl -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1; }

secret_field() {
  kubectl -n "$NAMESPACE" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d
}

label_secret() {
  kubectl -n "$NAMESPACE" label secret "$1" app.kubernetes.io/part-of=stardelt >/dev/null
}

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null

# --- S3 credentials -------------------------------------------------------------
fresh_s3=0
if secret_exists stardelt-s3-creds; then
  echo "› Secret stardelt-s3-creds exists — kept"
  access_key="$(secret_field stardelt-s3-creds access-key)"
  secret_key="$(secret_field stardelt-s3-creds secret-key)"
else
  access_key="$(rand 10)"   # 20 characters, like an AWS access key id
  secret_key="$(rand 20)"   # 40 characters
  {
    printf 'access-key=%s\n' "$access_key"
    printf 'secret-key=%s\n' "$secret_key"
    printf 'endpoint=http://seaweedfs-s3.%s.svc.cluster.local:8333\n' "$NAMESPACE"
    printf 'bucket=lakehouse\n'
    printf 'region=us-east-1\n'
  } > "$tmp/s3.env"
  kubectl -n "$NAMESPACE" create secret generic stardelt-s3-creds --from-env-file="$tmp/s3.env" >/dev/null
  label_secret stardelt-s3-creds
  echo "› Secret stardelt-s3-creds created (generated)"
  fresh_s3=1
fi

# The SeaweedFS S3 gateway reads its identities from a JSON document. It must carry
# exactly the key pair above, so it is derived from stardelt-s3-creds, never generated
# separately. New credentials replace a stale config; an existing config is kept.
if [ "$fresh_s3" = 1 ] || ! secret_exists seaweedfs-s3-config; then
  printf '{"identities":[{"name":"stardelt","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write"]}]}\n' \
    "$access_key" "$secret_key" > "$tmp/seaweedfs_s3_config"
  kubectl -n "$NAMESPACE" delete secret seaweedfs-s3-config --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" create secret generic seaweedfs-s3-config \
    --from-file=seaweedfs_s3_config="$tmp/seaweedfs_s3_config" >/dev/null
  label_secret seaweedfs-s3-config
  echo "› Secret seaweedfs-s3-config written (derived from stardelt-s3-creds)"
else
  echo "› Secret seaweedfs-s3-config exists — kept"
fi

# --- SeaweedFS admin UI login -----------------------------------------------------------
# The object store's web UI for administrators (helm-values/seaweedfs.yaml, `admin`). Generated once,
# never rotated by a re-run, never printed.
if secret_exists seaweedfs-admin-ui; then
  echo "› Secret seaweedfs-admin-ui exists — kept"
else
  printf 'user=admin\npassword=%s\n' "$(rand 16)" > "$tmp/admin.env"
  kubectl -n "$NAMESPACE" create secret generic seaweedfs-admin-ui --from-env-file="$tmp/admin.env" >/dev/null
  label_secret seaweedfs-admin-ui
  echo "› Secret seaweedfs-admin-ui created (generated)"
fi
