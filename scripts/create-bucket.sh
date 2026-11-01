#!/usr/bin/env bash
# Create a bucket in the platform's object store, once (idempotent).
#
#   NAMESPACE=stardelt bash scripts/create-bucket.sh lakehouse-backup
#   NAMESPACE=stardelt VERSIONING=1 bash scripts/create-bucket.sh notebooks
#
# Why this exists: the manifests reference buckets the chart's hook does not
# create (the S3 gateway only creates the ones it is told about), and a missing
# bucket fails late — a backup CronJob that errors every night, or an upload that
# 404s at the end of a pipeline. Creating it during the install turns that into a
# step that either works or says why.
#
# The S3 gateway is cluster-internal, so a local aws CLI cannot reach it: the
# calls run in a one-shot `amazon/aws-cli` pod whose credentials come from Secret
# `stardelt-s3-creds` through `secretKeyRef` — no value ever reaches this
# process's argv or stdout.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-${1:-stardelt}}"
BUCKET="${1:-${BUCKET:-}}"
VERSIONING="${VERSIONING:-0}"
S3_CHECK_IMAGE="${S3_CHECK_IMAGE:-amazon/aws-cli:2.17.0}"

[ -n "$BUCKET" ] || { echo "create-bucket: name the bucket: scripts/create-bucket.sh <bucket>" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "create-bucket: kubectl not found" >&2; exit 1; }

umask 077
tmp="$(mktemp -d)"
pod="create-bucket-$(printf '%s' "$BUCKET" | tr -c 'a-z0-9-' '-' | cut -c1-40)-$$"

cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" get secret stardelt-s3-creds >/dev/null 2>&1 \
  || { echo "create-bucket: Secret stardelt-s3-creds is missing — run 'make install' or scripts/s3-secrets.sh first" >&2; exit 1; }

cat > "$tmp/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $NAMESPACE
  labels: { app.kubernetes.io/part-of: stardelt }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: s3
      image: $S3_CHECK_IMAGE
      command: ["sh", "-ec"]
      args:
        - |
          s3() { aws --endpoint-url "\$AWS_ENDPOINT_URL" "\$@"; }
          # The gateway can still be starting when this runs right after an install.
          n=0
          until s3 s3api list-buckets >/dev/null 2>&1; do
            n=\$((n + 1))
            if [ "\$n" -ge 30 ]; then echo "object store at \$AWS_ENDPOINT_URL is not reachable" >&2; exit 1; fi
            sleep 2
          done
          if s3 s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
            echo "› bucket $BUCKET: exists"
          else
            s3 s3api create-bucket --bucket "$BUCKET" >/dev/null
            echo "› bucket $BUCKET: created"
          fi
          if [ "$VERSIONING" = "1" ]; then
            s3 s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
            state="\$(s3 s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text)"
            [ "\$state" = Enabled ] || { echo "versioning on $BUCKET is \$state" >&2; exit 1; }
            echo "› bucket $BUCKET: versioning \$state"
          fi
      env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: stardelt-s3-creds, key: access-key } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: stardelt-s3-creds, key: secret-key } }
        - name: AWS_ENDPOINT_URL
          valueFrom: { secretKeyRef: { name: stardelt-s3-creds, key: endpoint } }
        - name: AWS_DEFAULT_REGION
          valueFrom: { secretKeyRef: { name: stardelt-s3-creds, key: region } }
YAML

kubectl -n "$NAMESPACE" apply -f "$tmp/pod.yaml" >/dev/null
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=180s >/dev/null 2>&1 || {
  echo "create-bucket: the one-shot pod did not finish — its log:" >&2
  kubectl -n "$NAMESPACE" logs "$pod" >&2 2>&1 || true
  exit 1
}
kubectl -n "$NAMESPACE" logs "$pod"
