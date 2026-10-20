#!/usr/bin/env bash
# Create the versioned `notebooks` bucket for published notebooks (platform#290,
# design/scheduling-and-notebooks.md §3). Called by `make install` through the
# `notebooks-bucket` target; safe to re-run, and its output is the same on every
# run — the bucket and the versioning state, never a credential.
#
#   NAMESPACE=stardelt bash scripts/create-notebooks-bucket.sh
#
# Why it exists: "Schedule this notebook" pins the object *version* a person
# published, so the bucket must keep every version (spike platform#268, B1: a
# pinned version is byte-stable across later uploads, deletes and a gateway
# restart). The SeaweedFS chart's bucket hook only creates buckets; it does not
# turn versioning on, so the S3 API is called here with the platform identity
# every other consumer already uses (Secret `stardelt-s3-creds`).
#
# The S3 gateway is cluster-internal, so a local aws CLI cannot reach it: the
# calls run in a one-shot `amazon/aws-cli` pod whose credentials come from the
# Secret through `secretKeyRef` — no value ever reaches this process's argv or
# stdout.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
BUCKET="notebooks"
S3_CHECK_IMAGE="${S3_CHECK_IMAGE:-amazon/aws-cli:2.17.0}"

command -v kubectl >/dev/null 2>&1 || { echo "create-notebooks-bucket: kubectl not found" >&2; exit 1; }

umask 077
tmp="$(mktemp -d)"
pod="notebooks-bucket-$$"

cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" get secret stardelt-s3-creds >/dev/null 2>&1 \
  || { echo "create-notebooks-bucket: Secret stardelt-s3-creds is missing — run 'make install' or scripts/s3-secrets.sh first" >&2; exit 1; }

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
          # The gateway can still be starting when this runs right after an
          # install: wait for it before deciding the bucket is absent.
          s3() { aws --endpoint-url "\$AWS_ENDPOINT_URL" "\$@"; }
          n=0
          until s3 s3api list-buckets >/dev/null 2>&1; do
            n=\$((n + 1))
            if [ "\$n" -ge 30 ]; then echo "object store at \$AWS_ENDPOINT_URL is not reachable" >&2; exit 1; fi
            sleep 2
          done
          if ! s3 s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
            s3 s3api create-bucket --bucket "$BUCKET" >/dev/null
          fi
          s3 s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
          state="\$(s3 s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text)"
          [ "\$state" = Enabled ] || { echo "versioning on $BUCKET is \$state" >&2; exit 1; }
          echo "› bucket $BUCKET: versioning \$state"
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
if ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s "pod/$pod" >/dev/null; then
  echo "create-notebooks-bucket: the S3 pod did not succeed — its output follows" >&2
  kubectl -n "$NAMESPACE" logs "$pod" >&2 || true
  exit 1
fi
kubectl -n "$NAMESPACE" logs "$pod"
