#!/usr/bin/env bash
# Create the Secrets Airflow and Superset need, against the current kube-context.
# Called by `make install` and `make chart-install` before those charts are
# installed; safe to re-run — a Secret that already exists is left untouched.
#
#   NAMESPACE=stardelt bash scripts/app-secrets.sh
#
# Why: these values used to be committed to this repo (a fernet key, a JWT
# secret, a session key and `admin`/`admin` logins). A public session-signing
# key lets anyone who can reach the UI forge an administrator session, so every
# value here is generated on the cluster and never written to a tracked file or
# printed to stdout. Values go through a mode-0600 temp file, never argv.
# Read one back deliberately with e.g.
#   kubectl -n stardelt get secret airflow-fernet-key -o jsonpath='{.data.fernet-key}' | base64 -d
#
# Kept across installs: the Secrets are labelled app.kubernetes.io/part-of=stardelt
# and belong to no Helm release, so `helm uninstall` / `make uninstall` leave them
# in place (like the PVCs). To rotate, delete a Secret and re-run this script.
# Trade-off: rotating the Airflow fernet key permanently invalidates every
# connection/credential Airflow stored encrypted in its metadata database (they
# cannot be decrypted again); rotating the API/JWT keys only ends sessions.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"

command -v kubectl >/dev/null 2>&1 || { echo "app-secrets: kubectl not found" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "app-secrets: openssl not found" >&2; exit 1; }

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 32 random bytes as hex — 64 characters with no shell/YAML metacharacters.
rand() { openssl rand -hex 32; }
# Fernet wants a urlsafe-base64-encoded 32-byte key (44 characters, trailing '=').
fernet_key() { openssl rand -base64 32 | tr '+/' '-_'; }

# ensure_secret NAME KEY=VALUE|KEY=@rand|KEY=@fernet ...
ensure_secret() {
  local name="$1"; shift
  local pair key value
  if kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    # A Secret that exists but lacks a key a chart reads fails the pod at start,
    # not at install — fail here instead of pretending it is fine. The value is
    # captured, never printed; empty means the key is absent.
    for pair in "$@"; do
      key="${pair%%=*}"
      if [ -z "$(kubectl -n "$NAMESPACE" get secret "$name" -o jsonpath="{.data.$key}")" ]; then
        echo "app-secrets: Secret $name exists but has no '$key' key — delete it to regenerate, then re-run" >&2
        exit 1
      fi
    done
    echo "› Secret $name exists — kept"
    return
  fi
  local env="$tmp/$name.env"
  : > "$env"
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    case "$value" in
      @rand)   value="$(rand)" ;;
      @fernet) value="$(fernet_key)" ;;
    esac
    printf '%s=%s\n' "$key" "$value" >> "$env"
  done
  kubectl -n "$NAMESPACE" create secret generic "$name" --from-env-file="$env" >/dev/null
  kubectl -n "$NAMESPACE" label secret "$name" app.kubernetes.io/part-of=stardelt >/dev/null
  echo "› Secret $name created (generated)"
}

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null

# Airflow. Keys are the ones the chart's Secret-reference fields read
# (fernetKeySecretName, apiSecretKeySecretName, webserverSecretKeySecretName,
# jwtSecretName — see helm-values/airflow.yaml).
ensure_secret airflow-fernet-key fernet-key=@fernet
# Airflow 3 reads [api] secret_key as AIRFLOW__API__SECRET_KEY from key
# `api-secret-key`; `webserver-secret-key` is the Airflow <3 name, kept in the
# same Secret so a chart/app rollback still finds one.
ensure_secret airflow-webserver-key webserver-secret-key=@rand api-secret-key=@rand
ensure_secret airflow-jwt-secret jwt-secret=@rand
ensure_secret airflow-admin username=admin password=@rand

# Superset. `superset 0.15.5` has no Secret-name field for its secret key; the
# chart passes extraEnvRaw through to every pod including the init Job.
ensure_secret superset-secret-key secret-key=@rand
ensure_secret superset-admin username=admin password=@rand \
  firstname=stardelt lastname=Admin email=admin@stardelt.local
