#!/usr/bin/env bash
# Bring stardelt up on the home k3s node, after `install-k3s.sh`.
#
#   BASE_DOMAIN=alpha.example.dev ACME_EMAIL=ops@example.dev \
#     bash dev/home-k3s/deploy.sh [--notebooks] [--spark] [--full] [--seed]
#
# Unprivileged: everything here is `helm`/`kubectl`/`make`. Idempotent — each phase
# can be re-run alone, and `--skip-core`/`--skip-identity` resume a partial run.
#
# Phases, in order (each one needs the previous):
#   1  ingress-nginx (host-network) and cert-manager, then the DNS-01 issuer
#   2  make install-core SLIM=1          storage + catalog + query + Nova
#   3  make install-identity             Keycloak, the realm and the OIDC clients
#   4  the playground Ingresses and Nova's base domain
#   optional: notebooks (JupyterHub), spark, full (Airflow + Superset), seed
#
# Prerequisite that this script refuses to do for you: the Cloudflare token Secret
# in namespace `cert-manager` (a credential must be created from a shell that has
# it, never from a file in this repository):
#
#   kubectl -n cert-manager create secret generic cloudflare-api-token \
#     --from-literal=api-token="$CLOUDFLARE_API_TOKEN"
set -euo pipefail

BASE_DOMAIN="${BASE_DOMAIN:?set BASE_DOMAIN, e.g. BASE_DOMAIN=alpha.example.dev}"
ACME_EMAIL="${ACME_EMAIL:-}"
NAMESPACE="${NAMESPACE:-stardelt}"
EXPECT_CONTEXT="${EXPECT_CONTEXT:-stardelt-dev}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

DO_NOTEBOOKS=0 DO_SPARK=0 DO_FULL=0 DO_SEED=0 SKIP_CORE=0 SKIP_IDENTITY=0
for arg in "$@"; do
  case "$arg" in
    --notebooks)      DO_NOTEBOOKS=1 ;;
    --spark)          DO_SPARK=1 ;;
    --full)           DO_FULL=1 ;;
    --seed)           DO_SEED=1 ;;
    --skip-core)      SKIP_CORE=1 ;;
    --skip-identity)  SKIP_IDENTITY=1 ;;
    -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m› %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
[ -f "$KUBECONFIG" ] || die "no kubeconfig at $KUBECONFIG"

ctx="$(kubectl config current-context 2>/dev/null || true)"
[ "$ctx" = "$EXPECT_CONTEXT" ] \
  || die "current-context is '$ctx', expected '$EXPECT_CONTEXT' (KUBECONFIG=$KUBECONFIG)"

step "cluster: $ctx  base domain: $BASE_DOMAIN"
kubectl get nodes -o wide

# --- 1. ingress + certificates ---------------------------------------------
step "helm repos: ingress-nginx, jetstack"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
helm repo add jetstack      https://charts.jetstack.io --force-update >/dev/null
helm repo update >/dev/null

step "ingress-nginx (host-network :80/:443)"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f dev/playground/ingress-nginx-values.yaml --wait --timeout 10m

step "cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  -f dev/home-k3s/cert-manager-values.yaml --wait --timeout 10m

kubectl -n cert-manager get secret cloudflare-api-token >/dev/null 2>&1 \
  || die "Secret cert-manager/cloudflare-api-token is missing — see the header of this script"

step "ClusterIssuer letsencrypt-prod (DNS-01, Cloudflare)"
if [ -n "$ACME_EMAIL" ]; then
  sed "s|email: .*|email: $ACME_EMAIL|" dev/home-k3s/clusterissuer-cloudflare.yaml \
    | kubectl apply -f -
else
  kubectl apply -f dev/home-k3s/clusterissuer-cloudflare.yaml
  printf '  ! ACME_EMAIL unset — the issuer keeps the address in the file\n'
fi

# --- 2. core ---------------------------------------------------------------
if [ "$SKIP_CORE" = 0 ]; then
  step "install-core SLIM=1 (storage, catalog, query, Nova)"
  EXPECT_CONTEXT="$EXPECT_CONTEXT" make install-core SLIM=1
else
  step "skipping install-core"
fi

# --- 3. identity -----------------------------------------------------------
if [ "$SKIP_IDENTITY" = 0 ]; then
  step "install-identity BASE_DOMAIN=$BASE_DOMAIN"
  EXPECT_CONTEXT="$EXPECT_CONTEXT" make install-identity BASE_DOMAIN="$BASE_DOMAIN"
else
  step "skipping install-identity"
fi

# --- 4. ingresses and Nova's base domain -----------------------------------
step "playground Ingresses for $BASE_DOMAIN"
sed "s/alpha\.dev\.stardelt\.io/$BASE_DOMAIN/g" dev/playground/ingress.yaml | kubectl apply -f -

step "Nova's base domain (deep-links, Dashboards and Notebooks embeds)"
EXPECT_CONTEXT="$EXPECT_CONTEXT" BASE_DOMAIN="$BASE_DOMAIN" make platform-config
kubectl -n "$NAMESPACE" rollout status deploy/nova --timeout=5m

# --- optional phases -------------------------------------------------------
if [ "$DO_NOTEBOOKS" = 1 ]; then
  step "install-notebooks (JupyterHub)"
  EXPECT_CONTEXT="$EXPECT_CONTEXT" make install-notebooks
fi
if [ "$DO_SPARK" = 1 ]; then
  step "install-spark (Spark Connect)"
  EXPECT_CONTEXT="$EXPECT_CONTEXT" make install-spark
fi
if [ "$DO_FULL" = 1 ]; then
  step "install (adds Airflow + Superset)"
  EXPECT_CONTEXT="$EXPECT_CONTEXT" make install SLIM=1
fi
if [ "$DO_SEED" = 1 ]; then
  step "seed-dev-access (groups, people, warehouses)"
  EXPECT_CONTEXT="$EXPECT_CONTEXT" make seed-dev-access YES=1
fi

# --- report ----------------------------------------------------------------
step "certificates"
kubectl -n "$NAMESPACE" get certificate \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,EXPIRES:.status.notAfter' \
  || true
kubectl -n "$NAMESPACE" wait --for=condition=Ready certificate --all --timeout=600s \
  || printf '  ! not every certificate is Ready — check the Orders/Challenges, then:\n    kubectl -n %s describe certificate\n' "$NAMESPACE"

step "pods"
kubectl -n "$NAMESPACE" get pods

ok "rollout finished — https://$BASE_DOMAIN"
