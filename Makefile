# stardelt Platform — install/upgrade/uninstall against your current kube-context.
#
# Usage:
#   make install              # install all components into the stardelt namespace
#   NAMESPACE=mycluster make install
#   make pf                   # open port-forwards

NAMESPACE ?= stardelt

# Pinned chart versions
CNPG_VERSION       := 0.28.2
SEAWEEDFS_VERSION  := 4.25.1
LAKEKEEPER_VERSION := 0.11.0
TRINO_VERSION      := 1.42.2
AIRFLOW_VERSION    := 1.21.0
SUPERSET_VERSION   := 0.15.5
JUPYTERHUB_VERSION := 4.4.3

HELM_FLAGS := --namespace $(NAMESPACE) --create-namespace --wait --timeout 10m

SUPERSET_IMAGE := ghcr.io/stardelt/superset:dev

# SLIM=1 applies the small-node overrides in helm-values/slim/ (for cx33 / 8 GB).
TRINO_EXTRA := $(if $(filter 1,$(SLIM)),-f helm-values/slim/trino.yaml,)

# Extra `-f`/`--set` arguments for the umbrella chart, e.g.
#   make chart-template CHART_EXTRA="-f chart/values-slim.yaml"
CHART_EXTRA ?=

.PHONY: help deps lint install install-core install-notebooks install-operator upgrade uninstall build-superset-image push-superset-image pf pin dev-up dev-down dev-dns dev-dns-down
.PHONY: chart-deps chart-template chart-install

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

deps: ## Check required CLI tools
	@bash scripts/check-deps.sh

lint: ## Syntax-check (bash -n) + ShellCheck the scripts under scripts/ and dev/
	@bash scripts/lint.sh

# ---------------------------------------------------------------------------
# Helm repo setup
# ---------------------------------------------------------------------------
.PHONY: _helm-repos
_helm-repos:
	@echo "› adding helm repos"
	@helm repo add cnpg           https://cloudnative-pg.github.io/charts           2>/dev/null || true
	@helm repo add seaweedfs      https://seaweedfs.github.io/seaweedfs/helm         2>/dev/null || true
	@helm repo add lakekeeper     https://lakekeeper.github.io/lakekeeper-charts/   2>/dev/null || true
	@helm repo add trino          https://trinodb.github.io/charts                   2>/dev/null || true
	@helm repo add apache-airflow https://airflow.apache.org                         2>/dev/null || true
	@helm repo add superset       https://apache.github.io/superset                  2>/dev/null || true
	@helm repo add jupyterhub     https://jupyterhub.github.io/helm-chart/           2>/dev/null || true
	@helm repo update

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install: deps _helm-repos ## Install all stardelt components (idempotent)
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
# Core install — the cheap path for a single small node (cx33 / 8 GB).
# Storage + catalog + query + Nova. Skips Airflow and Superset.
# ---------------------------------------------------------------------------
install-core: deps _helm-repos ## Install the core only (storage+catalog+query+Nova)
	@echo "› [1/7] CloudNative-PG operator"
	@helm upgrade --install cnpg cnpg/cloudnative-pg \
	  --version $(CNPG_VERSION) \
	  $(HELM_FLAGS)

	@echo "› [2/7] S3 credentials Secret (dev, pinned to SeaweedFS)"
	@kubectl apply -f manifests/s3-credentials.dev.yaml

	@echo "› [3/7] CNPG Cluster (Lakekeeper Postgres)"
	@kubectl apply -f manifests/cnpg-postgres.yaml
	@kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/lakekeeper-pg

	@echo "› [4/7] SeaweedFS"
	@helm upgrade --install seaweedfs seaweedfs/seaweedfs \
	  --version $(SEAWEEDFS_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/seaweedfs.yaml

	@echo "› [5/7] Lakekeeper"
	@helm upgrade --install lakekeeper lakekeeper/lakekeeper \
	  --version $(LAKEKEEPER_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/lakekeeper.yaml

	@echo "› [6/7] Lakekeeper bootstrap"
	@kubectl apply -f manifests/lakekeeper-bootstrap.yaml

	@echo "› [7/7] Trino + Nova"
	@helm upgrade --install trino trino/trino \
	  --version $(TRINO_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/trino.yaml $(TRINO_EXTRA)
	@kubectl apply -f manifests/nova-deployment.yaml

	@echo ""
	@echo "Core installed. Run 'make pf' to reach Nova, Trino and Lakekeeper."

# ---------------------------------------------------------------------------
# Notebooks — JupyterHub (fits the cheap node alongside the core stack).
# ---------------------------------------------------------------------------
install-notebooks: deps _helm-repos ## Install JupyterHub (notebooks)
	@echo "› JupyterHub"
	@helm upgrade --install jupyterhub jupyterhub/jupyterhub \
	  --version $(JUPYTERHUB_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/jupyterhub.yaml
	@kubectl -n $(NAMESPACE) rollout status deploy/hub --timeout=5m
	@echo "JupyterHub installed. Public service: proxy-public:80."

# ---------------------------------------------------------------------------
# Control plane — the stardelt Operator (dev: from the sibling checkout).
# ---------------------------------------------------------------------------
OPERATOR_DIR ?= ../stardelt-operator
install-operator: ## Install the stardelt Operator (needs ../stardelt-operator)
	@test -f $(OPERATOR_DIR)/chart/Chart.yaml || { \
	  echo "operator chart not found at $(OPERATOR_DIR)/chart — set OPERATOR_DIR"; exit 1; }
	@helm upgrade --install stardelt-operator $(OPERATOR_DIR)/chart \
	  --namespace $(NAMESPACE) --create-namespace --wait --timeout 5m \
	  --set 'imagePullSecrets[0].name=ghcr-creds'
	@echo "Operator installed. CRDs: PlatformInstance, Tenant, Lakehouse, IngestionSource, Pipeline."

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
# Umbrella chart — the declarative counterpart of `install`/`install-core`.
#
# chart/ ships the same components (same chart versions, same values, same
# object names) as one Helm release named `stardelt`. Use it *instead of* the
# per-component targets above in a given namespace: both paths own the same
# object names, so a parallel install collides.
#
# Run `make chart-deps` once after a fresh clone and whenever chart/Chart.yaml
# changes; it fetches the sub-charts into chart/charts/ (git-ignored).
# ---------------------------------------------------------------------------
chart-deps: ## Fetch/refresh the umbrella chart's sub-charts (helm dependency update)
	@helm dependency update chart

chart-template: ## Render the umbrella chart without installing it
	@helm template stardelt chart --namespace $(NAMESPACE) $(CHART_EXTRA)

chart-install: ## Install/upgrade the umbrella chart as release `stardelt`
	@helm upgrade --install stardelt chart \
	  --namespace $(NAMESPACE) --create-namespace \
	  $(CHART_EXTRA)
	@echo ""
	@echo "stardelt installed from chart/. Run 'make pf' to open port-forwards."

# ---------------------------------------------------------------------------
# Superset image
# ---------------------------------------------------------------------------
pin: ## Pin a deployment to the newest published digest: make pin APP=nova NS=stardelt TAG=dev
	@APP="$(APP)" NS="$(NAMESPACE)" TAG="$(TAG)" bash scripts/pin-image.sh

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
# Hetzner k3s development cluster
# ---------------------------------------------------------------------------
dev-up: ## Provision the Hetzner k3s dev cluster (needs HCLOUD_TOKEN)
	@bash dev/hetzner-k3s/provision.sh

dev-down: ## Destroy the Hetzner k3s dev cluster
	@bash dev/hetzner-k3s/destroy.sh

dev-dns: ## Point the playground hostname (and wildcard) at the dev node
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/stardelt-dev.yaml}"; \
	 IP=$$(kubectl --kubeconfig "$$KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https://##; s#:.*##'); \
	 HOST="$${INGRESS_HOST:-alpha.dev.stardelt.io}"; \
	 echo "› $$HOST → $$IP"; \
	 IP="$$IP" NAME="$$HOST" bash dev/cloudflare-dns.sh upsert

dev-dns-down: ## Remove the playground DNS records
	@HOST="$${INGRESS_HOST:-alpha.dev.stardelt.io}"; \
	 NAME="$$HOST" bash dev/cloudflare-dns.sh delete
