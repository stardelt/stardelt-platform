#!/usr/bin/env bash
# Generate the PKCS12 keystore password for the Trino coordinator certificate,
# once, against the current kube-context. Called by `make trino` before it
# applies manifests/trino-tls.yaml; safe to re-run.
#
#   NAMESPACE=stardelt bash scripts/trino-tls-secret.sh
#
# Why this Secret is not left to cert-manager: a Certificate whose
# `keystores.pkcs12.passwordSecretRef` points at a Secret that does not exist is
# never issued (cert-manager emits KeystorePasswordSecretNotFound and stops), so
# the password has to exist before the Certificate is applied. Generating it
# here keeps that ordering explicit and keeps the value out of the repo, like
# the other install-time credentials.
#
# The value is generated only when the Secret does not exist, so a re-run never
# rotates a password the issued keystore is encrypted with. To rotate it, delete
# Secret trino-tls-keystore *and* Certificate trino-coordinator-tls, then run
# `make trino` again (cert-manager re-issues with the new password and the
# coordinator restarts to load it). Read it back deliberately with
#   kubectl -n stardelt get secret trino-tls-keystore -o jsonpath='{.data.password}' | base64 -d
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
NAME=trino-tls-keystore

command -v openssl >/dev/null 2>&1 || { echo "trino-tls-secret: openssl not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "trino-tls-secret: kubectl not found" >&2; exit 1; }

if kubectl -n "$NAMESPACE" get secret "$NAME" >/dev/null 2>&1; then
  echo "› Secret $NAME exists — kept"
  exit 0
fi

# Hex keeps the value free of characters that need escaping in a property file.
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'password=%s\n' "$(openssl rand -hex 24)" > "$tmp/$NAME.env"

kubectl -n "$NAMESPACE" create secret generic "$NAME" --from-env-file="$tmp/$NAME.env" >/dev/null
kubectl -n "$NAMESPACE" label secret "$NAME" app.kubernetes.io/part-of=stardelt >/dev/null
echo "› Secret $NAME created (generated)"
