# stardelt Platform — install/upgrade/uninstall against your current kube-context.
#
# Usage:
#   make install              # install all components into the stardelt namespace
#   NAMESPACE=mycluster make install
#   make pf                   # open port-forwards

NAMESPACE ?= stardelt

# Environment layering: prod is the default (runs on committed defaults);
# `STARDELT_ENV=lab make ingress` opts into the edited dev cluster.
# environments/<env>.env sets STARDELT_DOMAIN, STARDELT_ACME_SERVER, STARDELT_DNS_SYNC.
STARDELT_ENV ?= prod
include environments/$(STARDELT_ENV).env
export STARDELT_DOMAIN STARDELT_ACME_SERVER STARDELT_DNS_SYNC

# Pinned chart versions
CNPG_VERSION       := 0.28.2
SEAWEEDFS_VERSION  := 4.25.1
LAKEKEEPER_VERSION := 0.11.0
TRINO_VERSION      := 1.42.2
AIRFLOW_VERSION    := 1.21.0
SUPERSET_VERSION   := 0.15.5
CERT_MANAGER_VERSION := 1.16.2
OAUTH2_PROXY_VERSION := 7.7.1

HELM_FLAGS := --namespace $(NAMESPACE) --create-namespace --wait --timeout 5m

SUPERSET_IMAGE := ghcr.io/stardelt/superset:dev

.PHONY: help deps install upgrade uninstall build-superset-image push-superset-image pf ingress dns-sync uninstall-ingress

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(firstword $(MAKEFILE_LIST)) | \
	  awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

deps: ## Check required CLI tools
	@bash scripts/check-deps.sh

# ---------------------------------------------------------------------------
# Helm repo setup
# ---------------------------------------------------------------------------
.PHONY: _helm-repos _helm-plugin
_helm-repos:
	@echo "› adding helm repos"
	@helm repo add cnpg           https://cloudnative-pg.github.io/charts           2>/dev/null || true
	@helm repo add seaweedfs      https://seaweedfs.github.io/seaweedfs/helm         2>/dev/null || true
	@helm repo add lakekeeper     https://charts.lakekeeper.io                       2>/dev/null || true
	@helm repo add trino          https://trinodb.github.io/charts                   2>/dev/null || true
	@helm repo add apache-airflow https://airflow.apache.org                         2>/dev/null || true
	@helm repo add superset       https://apache.github.io/superset                  2>/dev/null || true
	@helm repo add jetstack       https://charts.jetstack.io                         2>/dev/null || true
	@helm repo update

_helm-plugin:
	@if ! helm plugin list 2>/dev/null | grep -q stardelt-dedupe; then \
	  echo "› installing stardelt-dedupe helm plugin"; \
	  helm plugin install scripts/helm-plugins/stardelt-dedupe; \
	else \
	  echo "› stardelt-dedupe plugin already installed"; \
	fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install: deps _helm-repos _helm-plugin ## Install all stardelt components (idempotent)
	@echo "› [1/9] CloudNative-PG operator"
	@helm upgrade --install cnpg cnpg/cloudnative-pg \
	  --version $(CNPG_VERSION) \
	  $(HELM_FLAGS)

	@echo "› [2/9] CNPG Cluster (Lakekeeper Postgres)"
	@kubectl apply -f manifests/cnpg-postgres.yaml

	@echo "› [3/9] SeaweedFS"
	@helm upgrade --install seaweedfs seaweedfs/seaweedfs \
	  --version $(SEAWEEDFS_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/seaweedfs.yaml

	@echo "› [4/9] Lakekeeper"
	@helm upgrade --install lakekeeper lakekeeper/lakekeeper \
	  --version $(LAKEKEEPER_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/lakekeeper.yaml

	@echo "› [5/9] Lakekeeper bootstrap"
	@kubectl apply -f manifests/lakekeeper-bootstrap.yaml

	@echo "› [6/9] Trino"
	@helm upgrade --install trino trino/trino \
	  --version $(TRINO_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/trino.yaml

	@echo "› [7/9] Airflow"
	@helm upgrade --install airflow apache-airflow/airflow \
	  --version $(AIRFLOW_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/airflow.yaml

	@echo "› [8/9] Superset"
	@helm upgrade --install superset superset/superset \
	  --version $(SUPERSET_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/superset.yaml

	@echo "› [9/9] Nova"
	@kubectl apply -f manifests/nova-deployment.yaml

	@echo ""
	@echo "stardelt installed. Run 'make pf' to open port-forwards."

# ---------------------------------------------------------------------------
# Upgrade (helm upgrade is idempotent — same as install)
# ---------------------------------------------------------------------------
upgrade: install ## Upgrade all components (same as install)

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall: ## Uninstall all stardelt components (reverse order)
	@echo "› removing manifests"
	@kubectl delete -f manifests/nova-deployment.yaml        --ignore-not-found
	@kubectl delete -f manifests/lakekeeper-bootstrap.yaml   --ignore-not-found
	@kubectl delete -f manifests/cnpg-postgres.yaml          --ignore-not-found

	@echo "› uninstalling helm releases"
	@helm uninstall superset   --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall airflow    --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall trino      --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall lakekeeper --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall seaweedfs  --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall cnpg       --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true

	@echo "Uninstall complete."

# ---------------------------------------------------------------------------
# Superset image
# ---------------------------------------------------------------------------
build-superset-image: ## Build the Superset image (ghcr.io/stardelt/superset:dev)
	@echo "› building $(SUPERSET_IMAGE)"
	@docker build -t $(SUPERSET_IMAGE) -f images/superset/Dockerfile images/superset

push-superset-image: ## Push the Superset image to ghcr.io
	@echo "› pushing $(SUPERSET_IMAGE)"
	@docker push $(SUPERSET_IMAGE)

# ---------------------------------------------------------------------------
# Port-forwards
# ---------------------------------------------------------------------------
pf: ## Open port-forwards to in-cluster services
	@NAMESPACE=$(NAMESPACE) bash scripts/port-forwards.sh

# ---------------------------------------------------------------------------
# Ingress: cert-manager + oauth2-proxy + Traefik routes
# ---------------------------------------------------------------------------
# Config comes from environments/$(STARDELT_ENV).env (default: prod).
# Lab cluster:  STARDELT_ENV=lab make ingress
# Before running, apply the two secrets:
#   kubectl apply -f manifests/cloudflare-api-token.yaml
#   kubectl apply -f manifests/oauth2-proxy-creds.yaml
ingress: deps _helm-repos ## Install ingress stack (STARDELT_ENV=prod|lab)
	@echo "› env=$(STARDELT_ENV) domain=$(STARDELT_DOMAIN) dns-sync=$(STARDELT_DNS_SYNC)"
	@echo "› [1/6] cert-manager"
	@helm upgrade --install cert-manager jetstack/cert-manager \
	  --version $(CERT_MANAGER_VERSION) \
	  --namespace cert-manager --create-namespace --wait --timeout 5m \
	  --set crds.enabled=true

	@echo "› [2/6] ClusterIssuer + wildcard Certificate"
	@bash scripts/render.sh manifests/ingress/cluster-issuer.yaml | kubectl apply -f -
	@bash scripts/render.sh manifests/ingress/certificate.yaml    | kubectl apply -f -

	@echo "› [3/6] oauth2-proxy"
	@bash scripts/render.sh manifests/ingress/oauth2-proxy.yaml | kubectl apply -f -

	@echo "› [4/6] Traefik forward-auth middleware"
	@kubectl apply -f manifests/ingress/middleware-auth.yaml

	@echo "› [5/6] Ingress routes"
	@bash scripts/render.sh manifests/ingress/ingress-routes.yaml | kubectl apply -f -

	@echo "› [6/6] DNS sync"
	@if [ "$(STARDELT_DNS_SYNC)" = "true" ]; then \
	  NAMESPACE=$(NAMESPACE) bash scripts/dns-sync.sh; \
	else \
	  echo "  skipped (STARDELT_DNS_SYNC=$(STARDELT_DNS_SYNC); prod uses a static IP)"; \
	fi

	@echo ""
	@echo "Ingress installed for *.$(STARDELT_DOMAIN). Check: kubectl get certificate -n $(NAMESPACE)"

dns-sync: ## Re-point the wildcard A-record at the current master IP (lab)
	@NAMESPACE=$(NAMESPACE) bash scripts/dns-sync.sh

uninstall-ingress: ## Remove the ingress stack (keeps cert-manager CRDs)
	@bash scripts/render.sh manifests/ingress/ingress-routes.yaml | kubectl delete --ignore-not-found -f -
	@kubectl delete --ignore-not-found -f manifests/ingress/middleware-auth.yaml
	@bash scripts/render.sh manifests/ingress/oauth2-proxy.yaml | kubectl delete --ignore-not-found -f -
	@bash scripts/render.sh manifests/ingress/certificate.yaml  | kubectl delete --ignore-not-found -f -
	@bash scripts/render.sh manifests/ingress/cluster-issuer.yaml | kubectl delete --ignore-not-found -f -
	@helm uninstall cert-manager --namespace cert-manager --ignore-not-found 2>/dev/null || true
	@echo "Ingress stack removed."
