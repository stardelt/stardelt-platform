# stardelt Platform — install/upgrade/uninstall against your current kube-context.
#
# Every target that changes a cluster first prints the kube-context it will act on
# (`_context`). Pin it with EXPECT_CONTEXT so a stale `kubectl config use-context`
# cannot send an install or uninstall to the wrong cluster:
#   EXPECT_CONTEXT=stardelt-dev make install-core
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

# Pinned image versions (no chart: plain manifests in manifests/keycloak.yaml).
# Mirrored in manifests/keycloak.yaml and chart/values.yaml
# (identity.keycloak.image.tag); scripts/check-version-parity.sh checks all three.
KEYCLOAK_VERSION   := 26.8.1

HELM_FLAGS := --namespace $(NAMESPACE) --create-namespace --wait --timeout 10m

SUPERSET_IMAGE := ghcr.io/stardelt/superset:dev

# SLIM=1 applies the small-node overrides in helm-values/slim/ (for cx33 / 8 GB).
TRINO_EXTRA := $(if $(filter 1,$(SLIM)),-f helm-values/slim/trino.yaml,)

# Extra `-f`/`--set` arguments for the umbrella chart, e.g.
#   make chart-template CHART_EXTRA="-f chart/values-slim.yaml"
CHART_EXTRA ?=

# Base domain for the platform IdP (install-identity): Keycloak at id.<BASE_DOMAIN>,
# client redirect URIs on the app subdomains. Same default as `dev-dns`.
BASE_DOMAIN ?= $(or $(INGRESS_HOST),alpha.dev.stardelt.io)

.PHONY: _context help deps lint install install-core install-notebooks install-identity install-operator trino upgrade uninstall build-superset-image push-superset-image pf pin pin-images dev-up dev-down dev-dns dev-dns-down
.PHONY: chart-deps chart-template chart-install
.PHONY: verify-backups verify-backup-config

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

deps: ## Check required CLI tools
	@bash scripts/check-deps.sh

# Show which cluster a mutating target is about to act on; with EXPECT_CONTEXT set,
# refuse to continue unless the current kube-context matches it exactly.
EXPECT_CONTEXT ?=
_context:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found (run 'make deps')" >&2; exit 1; }
	@ctx="$$(kubectl config current-context 2>/dev/null || true)"; \
	 [ -n "$$ctx" ] || { echo "no kubectl current-context: set KUBECONFIG or run 'kubectl config use-context'" >&2; exit 1; }; \
	 server="$$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"; \
	 echo "› kube-context: $$ctx ($$server)"; \
	 if [ -n "$(EXPECT_CONTEXT)" ] && [ "$$ctx" != "$(EXPECT_CONTEXT)" ]; then \
	   echo "refusing: current-context is '$$ctx' but EXPECT_CONTEXT is '$(EXPECT_CONTEXT)'" >&2; exit 1; \
	 fi

lint: ## Syntax-check (bash -n) + ShellCheck the scripts under scripts/ and dev/
	@bash scripts/lint.sh

# ---------------------------------------------------------------------------
# Backup guards (issue #59): a client-side `kubectl apply` from a stale checkout
# silently strips spec.backup from the live Cluster, which turns WAL archiving
# into a successful no-op — every operator-visible signal stays green while the
# bucket stops growing. verify-backup-config is the post-apply guard the install
# targets run; verify-backups is the full bucket-vs-database check, to run after
# any change to the backup path (a scheduled wrapper is future work on #59).
# ---------------------------------------------------------------------------
SKIP_OBJECTS    ?=
MAX_AGE_SECONDS ?= 900
# The CloudNative-PG Cluster the guards read. Passed to the script as CLUSTER
# *explicitly*: callers of `make` (stardelt-demos' verification gate does this)
# export CLUSTER for the kind cluster's name, which would otherwise be read as
# the Postgres Cluster name and fail the guard with
# "cannot read Cluster stardelt/stardelt" before anything is installed (#76).
PG_CLUSTER      ?= lakekeeper-pg

verify-backup-config: _context ## Assert the live Cluster still declares spec.backup (post-apply guard)
	@NAMESPACE=$(NAMESPACE) CLUSTER=$(PG_CLUSTER) bash scripts/verify-backups.sh --config-only

verify-backups: _context ## Verify WAL archiving for real: config + a fresh object in the bucket + agreement with pg_stat_archiver. SKIP_OBJECTS=1 drops the S3 half
	@NAMESPACE=$(NAMESPACE) CLUSTER=$(PG_CLUSTER) SKIP_OBJECTS="$(SKIP_OBJECTS)" MAX_AGE_SECONDS="$(MAX_AGE_SECONDS)" \
	  bash scripts/verify-backups.sh

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
install: deps _context _helm-repos ## Install all stardelt components (idempotent)
	@echo "› [1/11] CloudNative-PG operator"
	@helm upgrade --install cnpg cnpg/cloudnative-pg \
	  --version $(CNPG_VERSION) \
	  $(HELM_FLAGS)

	@echo "› [2/11] CNPG Cluster (Lakekeeper Postgres)"
	@kubectl apply -f manifests/cnpg-postgres.yaml
	@echo "› [2/11] guard: the live Cluster must still declare its backup config"
	@$(MAKE) --no-print-directory verify-backup-config

	@echo "› [3/11] SeaweedFS"
	@helm upgrade --install seaweedfs seaweedfs/seaweedfs \
	  --version $(SEAWEEDFS_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/seaweedfs.yaml

	@echo "› [4/11] Lakekeeper"
	@helm upgrade --install lakekeeper lakekeeper/lakekeeper \
	  --version $(LAKEKEEPER_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/lakekeeper.yaml

	@echo "› [5/11] Lakekeeper bootstrap"
	@kubectl apply -f manifests/lakekeeper-bootstrap.yaml

	@echo "› [6/11] Trino"
	@$(MAKE) --no-print-directory trino

	@echo "› [7/11] Airflow/Superset Secrets (generated once, kept across installs)"
	@NAMESPACE=$(NAMESPACE) bash scripts/app-secrets.sh

	@echo "› [8/11] Airflow"
	@helm upgrade --install airflow apache-airflow/airflow \
	  --version $(AIRFLOW_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/airflow.yaml

	@echo "› [9/11] Superset"
	@helm upgrade --install superset superset/superset \
	  --version $(SUPERSET_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/superset.yaml

	@echo "› [10/11] Nova"
	@kubectl apply -f manifests/nova-deployment.yaml

	@echo "› [11/11] Pin images to the digests CI published"
	@$(MAKE) --no-print-directory pin-images

	@echo ""
	@echo "stardelt installed. Run 'make pf' to open port-forwards."

# ---------------------------------------------------------------------------
# Core install — the cheap path for a single small node (cx33 / 8 GB).
# Storage + catalog + query + Nova. Skips Airflow and Superset.
# ---------------------------------------------------------------------------
install-core: deps _context _helm-repos ## Install the core only (storage+catalog+query+Nova)
	@echo "› [1/7] CloudNative-PG operator"
	@helm upgrade --install cnpg cnpg/cloudnative-pg \
	  --version $(CNPG_VERSION) \
	  $(HELM_FLAGS)

	@echo "› [2/7] S3 credentials Secret (dev default, created only if absent)"
	@if kubectl -n stardelt get secret stardelt-s3-creds >/dev/null 2>&1; then \
	  echo "  › stardelt-s3-creds exists — keeping it"; \
	else \
	  kubectl apply -f manifests/s3-credentials.dev.yaml; \
	fi

	@echo "› [3/7] CNPG Cluster (Lakekeeper Postgres)"
	@kubectl apply -f manifests/cnpg-postgres.yaml
	@echo "› [3/7] guard: the live Cluster must still declare its backup config"
	@$(MAKE) --no-print-directory verify-backup-config
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
	@$(MAKE) --no-print-directory trino
	@kubectl apply -f manifests/nova-deployment.yaml

	@echo "› [8/8] Pin images to the digests CI published"
	@$(MAKE) --no-print-directory pin-images

	@echo ""
	@echo "Core installed. Run 'make pf' to reach Nova, Trino and Lakekeeper."

# ---------------------------------------------------------------------------
# Notebooks — JupyterHub (fits the cheap node alongside the core stack).
# ---------------------------------------------------------------------------
install-notebooks: deps _context _helm-repos ## Install JupyterHub (notebooks)
	@echo "› JupyterHub"
	@helm upgrade --install jupyterhub jupyterhub/jupyterhub \
	  --version $(JUPYTERHUB_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/jupyterhub.yaml
	@kubectl -n $(NAMESPACE) rollout status deploy/hub --timeout=5m
	@echo "JupyterHub installed. Public service: proxy-public:80."

# ---------------------------------------------------------------------------
# Trino — the query engine, and the one component whose authentication state
# depends on whether the platform has an IdP: with `stardelt-identity` present
# (make install-identity / the umbrella chart) every statement needs a Keycloak
# token or the service-account password (helm-values/trino-identity.yaml); on a
# bare `install-core` without identity there is nothing to authenticate against
# and Trino keeps the development default — anonymous, cluster-internal only.
# ---------------------------------------------------------------------------
trino: deps _context ## Install/upgrade Trino, with OAuth2 when a platform IdP is present
	@if kubectl -n $(NAMESPACE) get configmap stardelt-identity >/dev/null 2>&1; then \
	  echo "› Trino $(TRINO_VERSION) + helm-values/trino-identity.yaml (platform IdP present)"; \
	  helm upgrade --install trino trino/trino \
	    --version $(TRINO_VERSION) \
	    $(HELM_FLAGS) \
	    -f helm-values/trino.yaml $(TRINO_EXTRA) \
	    -f helm-values/trino-identity.yaml; \
	else \
	  echo "› Trino $(TRINO_VERSION) — no platform IdP, so no authentication (dev only)"; \
	  helm upgrade --install trino trino/trino \
	    --version $(TRINO_VERSION) \
	    $(HELM_FLAGS) \
	    -f helm-values/trino.yaml $(TRINO_EXTRA); \
	fi

# ---------------------------------------------------------------------------
# Identity — optional platform IdP (Keycloak, realm `stardelt`).
# Needs the CNPG operator (install-core). Secrets are generated on first run and
# never printed; see scripts/identity-bootstrap.sh.
# ---------------------------------------------------------------------------
install-identity: deps _context ## Install the platform IdP (Keycloak) at id.$(BASE_DOMAIN)
	@kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || { \
	  echo "CloudNative-PG CRDs not found — run 'make install-core' first" >&2; exit 1; }
	@echo "› [1/5] Secrets + realm/identity ConfigMaps (base domain $(BASE_DOMAIN))"
	@NAMESPACE=$(NAMESPACE) BASE_DOMAIN=$(BASE_DOMAIN) bash scripts/identity-bootstrap.sh
	@echo "› [2/5] CNPG Cluster (Keycloak Postgres)"
	@kubectl apply -f manifests/keycloak.yaml
	@kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/keycloak-pg
	@echo "› [3/5] Keycloak $(KEYCLOAK_VERSION)"
	@kubectl -n $(NAMESPACE) rollout status deploy/keycloak --timeout=10m
	@echo "› [4/5] Sync the live realm's Trino client (import skips an existing realm)"
	@NAMESPACE=$(NAMESPACE) TRINO_PUBLIC_URL=https://trino.$(BASE_DOMAIN) \
	  bash scripts/keycloak-sync-trino-client.sh
	@echo "› [5/5] Put the query engine behind the platform identity"
	@$(MAKE) --no-print-directory trino
	@echo "Keycloak installed. Issuer: https://id.$(BASE_DOMAIN)/realms/stardelt"
	@echo "Realm admin password: kubectl -n $(NAMESPACE) get secret stardelt-realm-admin -o jsonpath='{.data.password}' | base64 -d"

# ---------------------------------------------------------------------------
# Control plane — the stardelt Operator (dev: from the sibling checkout).
# ---------------------------------------------------------------------------
OPERATOR_DIR ?= ../stardelt-operator
install-operator: _context ## Install the stardelt Operator (needs ../stardelt-operator)
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
uninstall: _context ## Uninstall all stardelt components (reverse order)
	@echo "› removing manifests"
	@kubectl delete -f manifests/nova-deployment.yaml        --ignore-not-found
	@kubectl delete -f manifests/keycloak.yaml               --ignore-not-found
	@kubectl -n $(NAMESPACE) delete configmap keycloak-realm keycloak-env stardelt-identity --ignore-not-found
	@kubectl delete -f manifests/lakekeeper-bootstrap.yaml   --ignore-not-found
	@kubectl delete -f manifests/cnpg-postgres.yaml          --ignore-not-found

	@echo "› uninstalling helm releases"
	@helm uninstall jupyterhub --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall superset   --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall airflow    --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall trino      --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall lakekeeper --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall seaweedfs  --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall cnpg       --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true

	@echo "Uninstall complete. Kept (like PVCs): Secrets keycloak-admin, stardelt-realm-admin,"
	@echo "stardelt-oidc-clients, trino-internal-secret, trino-password-db,"
	@echo "airflow-fernet-key, airflow-webserver-key, airflow-jwt-secret,"
	@echo "airflow-admin, superset-secret-key, superset-admin (see scripts/app-secrets.sh)."

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

chart-install: _context ## Install/upgrade the umbrella chart as release `stardelt`
	@NAMESPACE=$(NAMESPACE) bash scripts/app-secrets.sh
	@helm upgrade --install stardelt chart \
	  --namespace $(NAMESPACE) --create-namespace \
	  $(CHART_EXTRA)
	@echo ""
	@echo "stardelt installed from chart/. Run 'make pf' to open port-forwards."

# ---------------------------------------------------------------------------
# Superset image
# ---------------------------------------------------------------------------
pin: _context ## Pin a deployment to the newest published digest: make pin APP=nova NS=stardelt TAG=dev
	@APP="$(APP)" NS="$(NAMESPACE)" TAG="$(TAG)" bash scripts/pin-image.sh

pin-images: _context ## Pin every stardelt image this cluster runs to its published digest
	@for app in nova stardelt-operator; do \
	  if kubectl -n $(NAMESPACE) get deploy $$app >/dev/null 2>&1; then \
	    APP=$$app NS=$(NAMESPACE) bash scripts/pin-image.sh || \
	      echo "  › could not pin $$app — leaving the tag in place"; \
	  fi; \
	done

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
