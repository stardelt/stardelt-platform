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
JUPYTER_IMAGE  := ghcr.io/stardelt/jupyter-singleuser:dev

# SLIM=1 applies the small-node overrides in helm-values/slim/ (for cx33 / 8 GB).
TRINO_EXTRA := $(if $(filter 1,$(SLIM)),-f helm-values/slim/trino.yaml,)

# Extra `-f`/`--set` arguments for the umbrella chart, e.g.
#   make chart-template CHART_EXTRA="-f chart/values-slim.yaml"
CHART_EXTRA ?=

# Base domain for the platform IdP (install-identity): Keycloak at id.<BASE_DOMAIN>,
# client redirect URIs on the app subdomains. Same default as `dev-dns`.
BASE_DOMAIN ?= $(or $(INGRESS_HOST),alpha.dev.stardelt.io)

.PHONY: _context help deps lint install install-core install-notebooks install-spark install-identity install-operator trino upgrade uninstall build-superset-image push-superset-image build-jupyter-image push-jupyter-image pf pin pin-images dev-up dev-down dev-dns dev-dns-down
.PHONY: chart-deps chart-template chart-install
.PHONY: verify-backups verify-backups-identity verify-backup-config verify-realm-admin sync-realm-admin sync-realm-user-management
.PHONY: sync-oidc-clients verify-oidc-clients verify-trino-tls sync-trino-groups

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

verify-backups-identity: _context ## Verify WAL archiving for keycloak-pg (same checks as verify-backups, identity database)
	@NAMESPACE=$(NAMESPACE) CLUSTER=keycloak-pg SKIP_OBJECTS="$(SKIP_OBJECTS)" MAX_AGE_SECONDS="$(MAX_AGE_SECONDS)" \
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

	@NAMESPACE=$(NAMESPACE) bash scripts/s3-secrets.sh

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

	@echo "› [2/7] Generated credentials (S3 key pair, once)"
	@NAMESPACE=$(NAMESPACE) bash scripts/s3-secrets.sh

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
# Spark — heavy compute over the same Iceberg catalog (manifests/spark.yaml).
#
# A Deployment, not a Helm release: there is no upstream chart for a Spark
# Connect *server* (the Apache Spark Kubernetes Operator is a controller for
# many SparkApplications, and its own overhead is not worth it for one app on
# the dev node — see the header of manifests/spark.yaml).
#
# The ConfigMap holds the whole Spark configuration. `kubectl apply` updates it
# without touching the running driver, so the target restarts the driver only
# when the rendered config actually changed; an unchanged re-run leaves open
# sessions alone.
# ---------------------------------------------------------------------------
install-spark: deps _context ## Install the Spark Connect endpoint (Iceberg on the Lakekeeper catalog)
	@old=$$(kubectl -n $(NAMESPACE) get configmap spark-connect-config \
	  -o jsonpath='{.data.spark-defaults\.conf}' 2>/dev/null | sha256sum | cut -d' ' -f1 || true); \
	kubectl apply -f manifests/spark.yaml; \
	new=$$(kubectl -n $(NAMESPACE) get configmap spark-connect-config \
	  -o jsonpath='{.data.spark-defaults\.conf}' | sha256sum | cut -d' ' -f1); \
	if [ "$$old" != "$$new" ]; then \
	  echo "› spark-defaults.conf changed — restarting the connect server"; \
	  kubectl -n $(NAMESPACE) rollout restart deploy/spark-connect; \
	fi
	@kubectl -n $(NAMESPACE) rollout status deploy/spark-connect --timeout=5m
	@echo "Spark Connect ready: sc://spark-connect.$(NAMESPACE).svc.cluster.local:15002 (in-cluster only)"

# ---------------------------------------------------------------------------
# Trino — the query engine, and the one component whose authentication state
# depends on whether the platform has an IdP: with `stardelt-identity` present
# (make install-identity / the umbrella chart) every statement needs a Keycloak
# token or the service-account password (helm-values/trino-identity.yaml); on a
# bare `install-core` without identity there is nothing to authenticate against
# and Trino keeps the development default — anonymous, cluster-internal only.
#
# In the IdP case the coordinator also gets TLS (manifests/trino-tls.yaml): a
# namespace-local cert-manager CA, an HTTPS listener on 8443 for in-cluster
# clients, and `allow-insecure-over-http=false` so a plain-HTTP statement is
# refused instead of being trusted from X-Trino-User (platform#80). cert-manager
# must be installed for that (e.g. dev/playground/README.md); the Certificate is
# waited for before the upgrade so Trino never starts without its keystore.
# ---------------------------------------------------------------------------
trino: deps _context ## Install/upgrade Trino, with OAuth2+TLS when a platform IdP is present
	@if kubectl -n $(NAMESPACE) get configmap stardelt-identity >/dev/null 2>&1; then \
	  echo "› Trino $(TRINO_VERSION) + helm-values/trino-identity.yaml (platform IdP present)"; \
	  kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || { \
	    echo "cert-manager CRDs not found — the identity install needs cert-manager to issue the" >&2; \
	    echo "Trino coordinator certificate (see dev/playground/README.md, 'cert-manager')." >&2; \
	    exit 1; \
	  }; \
	  echo "› Trino TLS anchor: CA + coordinator certificate (manifests/trino-tls.yaml)"; \
	  NAMESPACE=$(NAMESPACE) bash scripts/trino-tls-secret.sh; \
	  kubectl apply -f manifests/trino-tls.yaml; \
	  kubectl -n $(NAMESPACE) wait --for=condition=Ready certificate/trino-coordinator-tls --timeout=180s; \
	  if [ -z "$$(kubectl -n $(NAMESPACE) get configmap stardelt-identity -o jsonpath='{.data.trinoUrl}')" ]; then \
	    echo "  › warning: stardelt-identity has no trinoUrl — re-run scripts/identity-bootstrap.sh" >&2; \
	    echo "    ('make install-identity'), or Nova keeps its plain-HTTP default and cannot" >&2; \
	    echo "    reach the TLS listener." >&2; \
	  fi; \
	  echo "› Trino group file: sync stardelt-admins into ConfigMap trino-group-file (platform#125)"; \
	  NAMESPACE=$(NAMESPACE) bash scripts/sync-trino-groups.sh; \
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
#
# The realm-admin guard (#81): `--import-realm` substitutes
# ${STARDELT_REALM_ADMIN_PASSWORD} once and never again, while Secret
# stardelt-realm-admin can be regenerated later — the two then disagree and the
# documented login fails while everything else stays green. sync-realm-admin
# re-applies the Secret's current value through the master-realm API (idempotent,
# reaches Keycloak through the Service), and verify-realm-admin proves it with a
# real password grant. install-identity runs both, in that order.
#
# The same import-time snapshot applies to the four app clients' secrets in
# Secret stardelt-oidc-clients and cost every app its sign-in on 2026-10-18
# (#85). sync-oidc-clients/verify-oidc-clients are that guard; install-identity
# runs them too, around keycloak-sync-trino-client.sh.
# ---------------------------------------------------------------------------
sync-realm-admin: _context ## Point realm `stardelt`'s admin password at Secret stardelt-realm-admin (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/sync-realm-admin.sh

verify-realm-admin: _context ## Prove the realm-admin Secret still signs in to realm `stardelt` (password grant, in-cluster)
	@NAMESPACE=$(NAMESPACE) bash scripts/verify-realm-admin.sh

sync-realm-user-management: _context ## Grant realm `stardelt` admins the Users roles and enforce brute-force protection (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/sync-realm-user-management.sh

# The OIDC-client guard (#85): `--import-realm` substitutes the client secrets
# once, while Secret stardelt-oidc-clients can be regenerated later — the two
# then disagree and sign-in fails for every app that uses those clients while
# their /health stays green (happened live on 2026-10-18). sync-oidc-clients
# re-applies the Secret's values through the admin API (idempotent, probes the
# token endpoint first, delegates `trino` to keycloak-sync-trino-client.sh), and
# verify-oidc-clients proves each one with a real client-credentials request.
# install-identity runs both, with trino's own script in between.
SYNC_TRINO ?= 1
sync-oidc-clients: _context ## Point the realm's confidential clients at Secret stardelt-oidc-clients (idempotent)
	@NAMESPACE=$(NAMESPACE) SYNC_TRINO=$(SYNC_TRINO) bash scripts/sync-oidc-clients.sh

verify-oidc-clients: _context ## Prove every confidential client's secret still authenticates (token endpoint, in-cluster)
	@NAMESPACE=$(NAMESPACE) bash scripts/verify-oidc-clients.sh

# platform#125: query visibility is owner-only, admins exempted (file-based
# system access control + file group provider in helm-values/trino-identity.yaml).
# sync-trino-groups writes the live realm's `stardelt-admins` membership into
# ConfigMap trino-group-file before the upgrade; file.refresh-period picks a
# remounted file up with no restart, so only a values change needs the
# coordinator restart below (which drops running queries — pick a quiet moment).
sync-trino-groups: _context ## Sync the live realm's stardelt-admins membership into ConfigMap trino-group-file (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/sync-trino-groups.sh

# platform#80: the in-cluster path must refuse plain HTTP and authenticate a
# bearer token over TLS. TRINO_VERIFY_USER_PASSWORD=… adds the user check.
verify-trino-tls: _context ## Prove the in-cluster Trino path is TLS-only and token-authenticated
	@NAMESPACE=$(NAMESPACE) bash scripts/verify-trino-tls.sh

install-identity: deps _context ## Install the platform IdP (Keycloak) at id.$(BASE_DOMAIN)
	@kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || { \
	  echo "CloudNative-PG CRDs not found — run 'make install-core' first" >&2; exit 1; }
	@echo "› [1/10] Secrets + realm/identity ConfigMaps (base domain $(BASE_DOMAIN))"
	@NAMESPACE=$(NAMESPACE) BASE_DOMAIN=$(BASE_DOMAIN) bash scripts/identity-bootstrap.sh
	@echo "› [2/10] CNPG Cluster (Keycloak Postgres)"
	@kubectl apply -f manifests/keycloak.yaml
	@echo "› [2/10] guard: the live Cluster must still declare its backup config"
	@$(MAKE) --no-print-directory verify-backup-config PG_CLUSTER=keycloak-pg
	@kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/keycloak-pg
	@echo "› [3/10] Keycloak $(KEYCLOAK_VERSION)"
	@kubectl -n $(NAMESPACE) rollout status deploy/keycloak --timeout=10m
	@echo "› [4/10] Heal realm-admin drift: the Secret is the source of truth, not the import"
	@$(MAKE) --no-print-directory sync-realm-admin
	@echo "› [5/10] guard: the documented realm admin must still sign in"
	@$(MAKE) --no-print-directory verify-realm-admin
	@echo "› [6/10] Realm admins manage users (roles + brute force on a live realm)"
	@$(MAKE) --no-print-directory sync-realm-user-management
	@echo "› [7/10] Heal app-client drift: Secret stardelt-oidc-clients is the source of truth too"
	@$(MAKE) --no-print-directory sync-oidc-clients SYNC_TRINO=0
	@echo "› [8/10] Sync the live realm's Trino client (import skips an existing realm)"
	@NAMESPACE=$(NAMESPACE) TRINO_PUBLIC_URL=https://trino.$(BASE_DOMAIN) \
	  bash scripts/keycloak-sync-trino-client.sh
	@echo "› [9/10] guard: every client secret must authenticate at the token endpoint"
	@$(MAKE) --no-print-directory verify-oidc-clients
	@echo "› [10/10] Put the query engine behind the platform identity (TLS on the coordinator)"
	@$(MAKE) --no-print-directory trino
	@# Nova reads its Trino endpoint from the identity ConfigMap (authMode turned
	@# sign-in on, trinoUrl turns on the in-cluster TLS endpoint) and both are
	@# process environment, not watched files: without this restart a fresh
	@# install would keep running the dev-mode, plain-HTTP Nova it started with.
	@if kubectl -n $(NAMESPACE) get deploy nova >/dev/null 2>&1; then \
	  echo "› Nova: re-apply the manifest and restart so it re-reads the identity contract"; \
	  kubectl apply -f manifests/nova-deployment.yaml; \
	  kubectl -n $(NAMESPACE) rollout restart deploy/nova >/dev/null; \
	  kubectl -n $(NAMESPACE) rollout status deploy/nova --timeout=3m; \
	fi
	@echo "Keycloak installed. Issuer: https://id.$(BASE_DOMAIN)/realms/stardelt"
	@echo "Admin console: https://id.$(BASE_DOMAIN)/admin/stardelt/console/ (sign in as admin, then Users)"
	@echo "Realm admin password: kubectl -n $(NAMESPACE) get secret stardelt-realm-admin -o jsonpath='{.data.password}' | base64 -d"
	@echo "  (the install re-applies it: rotate by changing the Secret, then 'make sync-realm-admin')"
	@echo "Client secrets: Secret stardelt-oidc-clients, one key per client; the install re-applies it,"
	@echo "  so 'make sync-oidc-clients' is all a rotation needs — 'make verify-oidc-clients' proves it"

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
	@kubectl delete -f manifests/spark.yaml                   --ignore-not-found
	@kubectl delete -f manifests/trino-tls.yaml               --ignore-not-found
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
	@echo "stardelt-oidc-clients, trino-internal-secret, trino-password-db, trino-tls-keystore,"
	@echo "trino-ca, trino-coordinator-tls,"
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
	@# identity.mode=platform ships Keycloak; the same import-time drift applies to
	@# the chart path, so re-apply the Secret afterwards too — the realm admin
	@# (#81) and the OIDC client secrets (#85) — then the user-management roles
	@# and brute-force settings.
	@if kubectl -n $(NAMESPACE) get deploy keycloak >/dev/null 2>&1; then \
	  $(MAKE) --no-print-directory sync-realm-admin; \
	  $(MAKE) --no-print-directory verify-realm-admin; \
	  $(MAKE) --no-print-directory sync-realm-user-management; \
	  $(MAKE) --no-print-directory sync-oidc-clients; \
	  $(MAKE) --no-print-directory verify-oidc-clients; \
	fi
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
	@if kubectl -n $(NAMESPACE) get deploy spark-connect >/dev/null 2>&1; then \
	  APP=spark DEPLOY=spark-connect NS=$(NAMESPACE) bash scripts/pin-image.sh || \
	    echo "  › could not pin spark — leaving the tag in place"; \
	fi

build-superset-image: ## Build the Superset image (ghcr.io/stardelt/superset:dev)
	@echo "› building $(SUPERSET_IMAGE)"
	@docker build -t $(SUPERSET_IMAGE) -f images/superset/Dockerfile images/superset

push-superset-image: ## Push the Superset image to ghcr.io
	@echo "› pushing $(SUPERSET_IMAGE)"
	@docker push $(SUPERSET_IMAGE)

build-jupyter-image: ## Build the Jupyter single-user image (ghcr.io/stardelt/jupyter-singleuser:dev)
	@echo "› building $(JUPYTER_IMAGE)"
	@docker build -t $(JUPYTER_IMAGE) -f images/jupyter/Dockerfile images/jupyter

push-jupyter-image: ## Push the Jupyter single-user image to ghcr.io
	@echo "› pushing $(JUPYTER_IMAGE)"
	@docker push $(JUPYTER_IMAGE)

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
