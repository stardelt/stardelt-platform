#!/usr/bin/env bash
# Create the Secrets and ConfigMaps the platform IdP (Keycloak) needs, against the
# current kube-context. Called by `make install-identity` before it applies
# manifests/keycloak.yaml; safe to re-run.
#
#   NAMESPACE=stardelt BASE_DOMAIN=alpha.dev.stardelt.io bash scripts/identity-bootstrap.sh
#
# Secrets are generated with `openssl rand` only when they do not exist yet, so a
# re-run never rotates a credential the imported realm already holds. Values go
# through a mode-0600 temp file (never argv, never stdout) and are not printed.
# Read one back deliberately with e.g.
#   kubectl -n stardelt get secret stardelt-realm-admin -o jsonpath='{.data.password}' | base64 -d
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
BASE_DOMAIN="${BASE_DOMAIN:?set BASE_DOMAIN, e.g. alpha.dev.stardelt.io}"
REALM_FILE="chart/files/keycloak-realm.json"

# The base domain is substituted into the realm with sed and into a URL: accept a
# plain hostname only.
if ! [[ "$BASE_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  echo "identity-bootstrap: BASE_DOMAIN '$BASE_DOMAIN' is not a plain lower-case hostname" >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "identity-bootstrap: openssl not found" >&2; exit 1; }

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hex keeps generated values free of characters that would need escaping inside
# the realm JSON (Keycloak substitutes them verbatim).
rand() { openssl rand -hex 24; }

# ensure_secret NAME KEY=VALUE|KEY=@rand ...
ensure_secret() {
  local name="$1"; shift
  if kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    echo "› Secret $name exists — kept"
    return
  fi
  local env="$tmp/$name.env" pair key value
  : > "$env"
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    [[ "$value" == "@rand" ]] && value="$(rand)"
    printf '%s=%s\n' "$key" "$value" >> "$env"
  done
  kubectl -n "$NAMESPACE" create secret generic "$name" --from-env-file="$env" >/dev/null
  kubectl -n "$NAMESPACE" label secret "$name" app.kubernetes.io/part-of=stardelt >/dev/null
  echo "› Secret $name created (generated)"
}

# ensure_secret_key NAME KEY=@rand
# Adds one generated key to a Secret that already exists (a new credential on an
# upgraded install) without touching the keys around it — in particular without
# rotating a value the imported realm already holds.
ensure_secret_key() {
  local name="$1" key="${2%%=*}" value
  if ! kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    echo "ensure_secret_key: Secret $name does not exist" >&2
    exit 1
  fi
  if [ -n "$(kubectl -n "$NAMESPACE" get secret "$name" -o jsonpath="{.data.$key}")" ]; then
    echo "› Secret $name has '$key' — kept"
    return
  fi
  value="$(rand)"
  kubectl -n "$NAMESPACE" patch secret "$name" --type merge \
    -p "{\"data\":{\"$key\":\"$(printf '%s' "$value" | base64 | tr -d '\n')\"}}" >/dev/null
  echo "› Secret $name: added key '$key' (generated)"
}

# bcrypt hash for Trino's file password authenticator. Trino accepts $2a/$2b/$2y
# at cost >= 8; `htpasswd -B` writes $2y$, mkpasswd (libxcrypt) writes $2b$.
bcrypt_hash() {
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbBC 10 x "$1" | cut -d: -f2
    return
  fi
  if command -v mkpasswd >/dev/null 2>&1 && mkpasswd -m bcrypt -R 10 x >/dev/null 2>&1; then
    mkpasswd -m bcrypt -R 10 "$1"
    return
  fi
  echo "identity-bootstrap: need htpasswd (apache2-utils) or mkpasswd (whois) to hash the Trino service-account password" >&2
  exit 1
}

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null

ensure_secret keycloak-admin        username=admin password=@rand
ensure_secret stardelt-realm-admin  username=admin password=@rand
# One key per OIDC client. `trino` was added when Trino got OAuth2 (Trino 480
# requires a confidential client); the first four existed before it, so an
# upgrade adds only the new key.
ensure_secret       stardelt-oidc-clients nova=@rand superset=@rand airflow=@rand jupyterhub=@rand
ensure_secret_key   stardelt-oidc-clients trino=@rand
# Signs Nova's session cookie; Nova refuses to start with less than 32 bytes.
ensure_secret stardelt-nova-session session=@rand
# Trino authentication (helm-values/trino-identity.yaml):
#   * trino-internal-secret — coordinator <-> worker shared secret; Trino refuses
#     to start with an authenticator but no shared secret.
#   * trino-password-db — the PASSWORD-authenticator file for machine clients.
#     One service account `superset`; the plaintext is kept next to the hash so
#     the follow-up wiring of Superset's datasource URI (helm-values/superset.yaml
#     is owned by another change right now) has a single source for it.
#     Read it back deliberately with:
#       kubectl -n $NAMESPACE get secret trino-password-db -o jsonpath='{.data.superset-password}' | base64 -d
ensure_secret trino-internal-secret shared-secret=@rand
if ! kubectl -n "$NAMESPACE" get secret trino-password-db >/dev/null 2>&1; then
  superset_pw="$(rand)"
  superset_hash="$(bcrypt_hash "$superset_pw")"
  : > "$tmp/trino-password-db.env"
  printf 'password.db=%s\n' "superset:$superset_hash" >> "$tmp/trino-password-db.env"
  printf 'superset-password=%s\n' "$superset_pw" >> "$tmp/trino-password-db.env"
  kubectl -n "$NAMESPACE" create secret generic trino-password-db --from-env-file="$tmp/trino-password-db.env" >/dev/null
  kubectl -n "$NAMESPACE" label secret trino-password-db app.kubernetes.io/part-of=stardelt >/dev/null
  echo "› Secret trino-password-db created (service account 'superset')"
else
  echo "› Secret trino-password-db exists — kept"
fi

# Host layout matches dev/playground/ingress.yaml and the chart's ingress
# defaults: Nova on the base domain itself, every other app on <sub>.<base>.
sed -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__NOVA_HOST__|${BASE_DOMAIN}|g" \
    -e "s|__TRINO_HOST__|trino.${BASE_DOMAIN}|g" \
    -e "s|__LAKEKEEPER_HOST__|lakekeeper.${BASE_DOMAIN}|g" \
    -e "s|__SUPERSET_HOST__|superset.${BASE_DOMAIN}|g" \
    -e "s|__AIRFLOW_HOST__|airflow.${BASE_DOMAIN}|g" \
    -e "s|__JUPYTER_HOST__|jupyter.${BASE_DOMAIN}|g" \
    "$REALM_FILE" > "$tmp/stardelt-realm.json"

apply_configmap() {
  kubectl -n "$NAMESPACE" create configmap "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

apply_configmap keycloak-realm --from-file=stardelt-realm.json="$tmp/stardelt-realm.json"
echo "› ConfigMap keycloak-realm (realm stardelt, hosts under ${BASE_DOMAIN})"

apply_configmap keycloak-env --from-literal=KC_HOSTNAME="https://id.${BASE_DOMAIN}"
echo "› ConfigMap keycloak-env (KC_HOSTNAME=https://id.${BASE_DOMAIN})"

# The identity contract every component reads — same keys as the chart's
# `identity.mode: platform|external` ConfigMap.
# `authMode` and `publicUrl` are what Nova reads to switch sign-in on. They live here
# rather than in the Deployment so re-applying manifests/nova-deployment.yaml cannot turn
# authentication off by accident — it did, once, and the cluster silently went back to
# no-login.
#
# `trinoUrl` is the query engine's in-cluster TLS endpoint, which exists under
# exactly the same condition as the IdP: `make trino` adds the HTTPS listener and
# the internal-CA certificate (manifests/trino-tls.yaml) only when this ConfigMap
# is present. Nova reads it for NOVA_TRINO_URL; without the key its built-in
# plain-HTTP default applies, which is what a dev install without identity runs.
# The key has to live in this ConfigMap rather than in Nova's manifest because
# `kubectl apply` of the ConfigMap would otherwise prune it again.
apply_configmap stardelt-identity \
  --from-literal=issuerUrl="https://id.${BASE_DOMAIN}/realms/stardelt" \
  --from-literal=groupClaim=groups \
  --from-literal=adminGroup=stardelt-admins \
  --from-literal=authMode=oidc \
  --from-literal=publicUrl="https://${BASE_DOMAIN}" \
  --from-literal=trinoUrl="https://trino.${NAMESPACE}.svc.cluster.local:8443"
echo "› ConfigMap stardelt-identity (issuer https://id.${BASE_DOMAIN}/realms/stardelt)"
