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

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null

ensure_secret keycloak-admin        username=admin password=@rand
ensure_secret stardelt-realm-admin  username=admin password=@rand
ensure_secret stardelt-oidc-clients nova=@rand superset=@rand airflow=@rand jupyterhub=@rand
# Signs Nova's session cookie; Nova refuses to start with less than 32 bytes.
ensure_secret stardelt-nova-session session=@rand

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
apply_configmap stardelt-identity \
  --from-literal=issuerUrl="https://id.${BASE_DOMAIN}/realms/stardelt" \
  --from-literal=groupClaim=groups \
  --from-literal=adminGroup=stardelt-admins
echo "› ConfigMap stardelt-identity (issuer https://id.${BASE_DOMAIN}/realms/stardelt)"
