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
OPENFGA_VERSION    ?= 0.2.62
TRINO_VERSION      := 1.42.2
AIRFLOW_VERSION    := 1.21.0
RELOADER_VERSION   := 2.2.18
OPENBAO_VERSION    := 0.30.4
EXTERNAL_SECRETS_VERSION := 2.13.0
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
# Query-log feed (stardelt-nova#116): Trino's event listener posts to Nova's internal port.
TRINO_QUERYLOG := -f helm-values/trino-query-log.yaml
# Which claim names the Trino principal (platform#311) and therefore what the
# group file holds. `sub` is the switched state (`make catalog-enforce`);
# `username` is the pre-switch state (`make catalog-enforce-rollback` passes it,
# together with the overlay below). One knob for both so they cannot disagree:
# a group file of ids while the engine compares usernames silently drops every
# group, and an administrator quietly loses the query visibility it grants.
GROUP_PRINCIPAL ?= sub
# An extra `-f` for the identity branch of `make trino`, applied last. Empty in
# the normal case; `make catalog-enforce-rollback` passes
# helm-values/trino-identity-file-only.yaml, which keeps `preferred_username`
# and the file access control alone.
TRINO_IDENTITY_OVERLAY ?=

# Extra `-f`/`--set` arguments for the umbrella chart, e.g.
#   make chart-template CHART_EXTRA="-f chart/values-slim.yaml"
CHART_EXTRA ?=

# Base domain for the platform IdP (install-identity): Keycloak at id.<BASE_DOMAIN>,
# client redirect URIs on the app subdomains. Same default as `dev-dns`.
BASE_DOMAIN ?= $(or $(INGRESS_HOST),alpha.dev.stardelt.io)

.PHONY: _context help deps lint install install-core install-notebooks install-spark install-identity install-operator openfga trino catalogs upgrade uninstall build-superset-image push-superset-image build-jupyter-image push-jupyter-image pf pin pin-images dev-up dev-down dev-dns dev-dns-down
.PHONY: chart-deps chart-template chart-install
.PHONY: verify-backups verify-backups-identity verify-backups-nova verify-backup-config verify-realm-admin sync-realm-admin sync-realm-user-management
.PHONY: sync-oidc-clients verify-oidc-clients verify-trino-tls verify-trino-auth sync-trino-groups sync-trino-group-sync-client sync-pipeline-runner-client sync-dev-client sync-catalog-audience openbao test-openbao-policies seaweedfs-admin
.PHONY: external-secrets eso-stores

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
	 fi; \
	 if git rev-parse --git-dir >/dev/null 2>&1 && git ls-remote --exit-code origin HEAD >/dev/null 2>&1; then \
	   git fetch -q origin 2>/dev/null || true; \
	   behind="$$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"; \
	   if [ "$$behind" -gt 0 ]; then \
	     echo "› warning: this checkout is $$behind commit(s) behind origin/main — 'git pull' before applying, or an older revision may strip live fields (#62)" >&2; \
	   fi; \
	 fi

lint: ## Syntax-check (bash -n) + ShellCheck the scripts under scripts/ and dev/
	@bash scripts/lint.sh

# The node's memory budget is the ceiling for every Spark size (platform#373): requests
# decide what still fits (at 99 % of allocatable a new request stays Pending), and the
# pods above their request are the ones the kubelet evicts first. Read-only, no cluster
# change: three kubectl calls and a table.
.PHONY: node-budget
node-budget: ## Memory requests, limits and use on the node
	@python3 scripts/node-budget.py

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
# The CloudNative-PG Cluster the guards read.
PG_CLUSTER      ?= lakekeeper-pg

verify-backup-config: _context ## Assert the live Cluster still declares spec.backup (post-apply guard)
	@NAMESPACE=$(NAMESPACE) CLUSTER=$(PG_CLUSTER) bash scripts/verify-backups.sh --config-only

verify-backups: _context ## Verify WAL archiving for real: config + a fresh object in the bucket + agreement with pg_stat_archiver. SKIP_OBJECTS=1 drops the S3 half
	@NAMESPACE=$(NAMESPACE) CLUSTER=$(PG_CLUSTER) SKIP_OBJECTS="$(SKIP_OBJECTS)" MAX_AGE_SECONDS="$(MAX_AGE_SECONDS)" \
	  bash scripts/verify-backups.sh

verify-backups-nova: _context ## Verify WAL archiving for nova-pg (same checks as verify-backups, Nova's state store)
	@NAMESPACE=$(NAMESPACE) CLUSTER=nova-pg SKIP_OBJECTS="$(SKIP_OBJECTS)" MAX_AGE_SECONDS="$(MAX_AGE_SECONDS)" \
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
	@helm repo add openfga        https://openfga.github.io/helm-charts              2>/dev/null || true
	@helm repo add trino          https://trinodb.github.io/charts                   2>/dev/null || true
	@helm repo add apache-airflow https://airflow.apache.org                         2>/dev/null || true
	@helm repo add superset       https://apache.github.io/superset                  2>/dev/null || true
	@helm repo add jupyterhub     https://jupyterhub.github.io/helm-chart/           2>/dev/null || true
	@helm repo add stakater       https://stakater.github.io/stakater-charts         2>/dev/null || true
	@helm repo add openbao        https://openbao.github.io/openbao-helm            2>/dev/null || true
	@helm repo add external-secrets https://charts.external-secrets.io             2>/dev/null || true
	@helm repo update

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install: deps _context _helm-repos ## Install all stardelt components (idempotent)
	@echo "› Reloader (restarts workloads when a credential they read changes)"
	@helm upgrade --install reloader stakater/reloader --version $(RELOADER_VERSION) $(HELM_FLAGS) -f helm-values/reloader.yaml

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

	@echo "› [3/11] Versioned notebooks bucket (published notebooks, platform#290)"
	@$(MAKE) --no-print-directory notebooks-bucket

	@# OpenFGA (platform#302): the permission store for the catalog cutover. Only
	@# where the platform has an IdP — authorization is checked against a person's
	@# OIDC subject, and a bare install has nothing to check. Lakekeeper keeps
	@# `allowall` until #304, so this deployment changes no behaviour.
	@if kubectl -n $(NAMESPACE) get configmap stardelt-identity >/dev/null 2>&1; then \
	  echo "› [4/11] OpenFGA: the catalog's permission store (own Postgres, not wired yet)"; \
	  kubectl apply -f manifests/openfga-pg.yaml; \
	  kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/openfga-pg; \
	  $(MAKE) --no-print-directory verify-backup-config PG_CLUSTER=openfga-pg; \
	  echo "› [4/11] OpenFGA ingress: only the Lakekeeper catalog and migration pods"; \
	  kubectl apply -f manifests/openfga-network-policy.yaml; \
	  $(MAKE) --no-print-directory openfga; \
	fi

	@echo "› Catalog service clients (platform#282): svc-catalog-* for every caller of the catalog"
	@# Before Lakekeeper, because authentication is on (platform#285): the bootstrap
	@# Job below presents svc-catalog-bootstrap on its very first call, so the Secret
	@# must exist before the release that enables validation. Trino's `warehouse`
	@# catalog authenticates as svc-catalog-trino (platform#283) for the same reason:
	@# its overlay reads that Secret, and a missing one makes the coordinator refuse
	@# the catalog and `helm --wait` fail. Guarded by the identity ConfigMap; on a
	@# cluster without an IdP there is no Secret and the catalog stays anonymous.
	@if kubectl -n $(NAMESPACE) get configmap stardelt-identity >/dev/null 2>&1; then \
	  $(MAKE) --no-print-directory sync-catalog-clients; \
	fi

	@echo "› [4/11] Lakekeeper"
	@helm upgrade --install lakekeeper lakekeeper/lakekeeper \
	  --version $(LAKEKEEPER_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/lakekeeper.yaml \
	  $$(NAMESPACE=$(NAMESPACE) bash scripts/render-catalogs.sh bridge-arg) \
	  $$(NAMESPACE=$(NAMESPACE) bash scripts/render-catalogs.sh admin-arg)

	@echo "› [5/11] Lakekeeper bootstrap"
	@kubectl apply -f manifests/lakekeeper-bootstrap.yaml
	@echo "› [5/11] catalog ingress NetworkPolicy (only the components that need it)"
	@kubectl apply -f manifests/lakekeeper-network-policy.yaml
	@echo "› [5/11] Access sync: one warehouse per Catalog (platform#305)"
	@if kubectl -n $(NAMESPACE) get configmap stardelt-identity >/dev/null 2>&1; then \
	  $(MAKE) --no-print-directory access-sync; \
	fi

	@echo "› [6/11] Trino"
	@$(MAKE) --no-print-directory trino

	@echo "› [7/11] Airflow/Superset Secrets (generated once, kept across installs)"
	@NAMESPACE=$(NAMESPACE) bash scripts/app-secrets.sh

	@echo "› [8/11] Airflow"
	@helm upgrade --install airflow apache-airflow/airflow \
	  --version $(AIRFLOW_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/airflow.yaml
	@kubectl apply -f manifests/airflow-pipelines.yaml

	@echo "› [9/11] Superset"
	@# The init Job's role script lives in the repo (#287); --set-file puts it into
	@# the extra-config ConfigMap so Helm carries it and there is one copy to edit.
	@helm upgrade --install superset superset/superset \
	  --version $(SUPERSET_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/superset.yaml \
	  --set-file "extraConfigs.superset-analyst-role\.py=scripts/superset-analyst-role.py"

	@echo "› [10/11] Nova (state store first: the Deployment reads its Secret)"
	@kubectl apply -f manifests/nova-pg.yaml
	@$(MAKE) --no-print-directory verify-backup-config PG_CLUSTER=nova-pg
	@kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/nova-pg
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
	@echo "› Reloader (restarts workloads when a credential they read changes)"
	@helm upgrade --install reloader stakater/reloader --version $(RELOADER_VERSION) $(HELM_FLAGS) -f helm-values/reloader.yaml

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

	@echo "› [5/7] Lakekeeper (allowall: install-core has no IdP for OpenFGA)"
	@helm upgrade --install lakekeeper lakekeeper/lakekeeper \
	  --version $(LAKEKEEPER_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/lakekeeper.yaml \
	  -f helm-values/lakekeeper-allowall.yaml

	@echo "› [6/7] Lakekeeper bootstrap"
	@kubectl apply -f manifests/lakekeeper-bootstrap.yaml
	@echo "› [6/7] catalog ingress NetworkPolicy (only the components that need it)"
	@kubectl apply -f manifests/lakekeeper-network-policy.yaml

	@echo "› [7/7] Trino + Nova (state store first: the Deployment reads its Secret)"
	@$(MAKE) --no-print-directory trino
	@kubectl apply -f manifests/nova-pg.yaml
	@$(MAKE) --no-print-directory verify-backup-config PG_CLUSTER=nova-pg
	@kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/nova-pg
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
# OpenFGA — the catalog's permission store (platform#302, authz 1/8).
#
# Deployed next to Lakekeeper. The cutover (platform#304, `make catalog-authz`)
# switches `helm-values/lakekeeper.yaml` to `authz.backend: openfga`, so every
# catalog request is then checked against these tuples; `install-core` keeps
# `allowall` through `helm-values/lakekeeper-allowall.yaml`. Its own
# CloudNative-PG Cluster (manifests/openfga-pg.yaml)
# and daily base backups; `make verify-backup-config PG_CLUSTER=openfga-pg`
# is the post-apply guard.
# ---------------------------------------------------------------------------
openfga: deps _context _helm-repos ## Install OpenFGA (catalog permission store; not wired to Lakekeeper yet)
	@helm upgrade --install openfga openfga/openfga --version $(OPENFGA_VERSION) $(HELM_FLAGS) -f helm-values/openfga.yaml

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
	@NAMESPACE=$(NAMESPACE) bash scripts/nova-events-token.sh
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
	  NAMESPACE=$(NAMESPACE) GROUP_PRINCIPAL=$(GROUP_PRINCIPAL) bash scripts/sync-trino-groups.sh; \
	  echo "› Trino group sync: refresh the job script and apply the 5-minute CronJob (platform#167)"; \
	  kubectl -n $(NAMESPACE) create configmap trino-group-sync-script --from-file=job.py=scripts/trino-group-sync-job.py \
	    --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	  kubectl apply -f manifests/trino-group-sync.yaml; \
	  helm upgrade --install trino trino/trino \
	    --version $(TRINO_VERSION) \
	    $(HELM_FLAGS) \
	    -f helm-values/trino.yaml $(TRINO_EXTRA) $(TRINO_QUERYLOG) \
	    -f helm-values/trino-identity.yaml \
	    $(TRINO_IDENTITY_OVERLAY) \
	    $$(NAMESPACE=$(NAMESPACE) bash scripts/render-catalogs.sh trino-args); \
	else \
	  echo "› Trino $(TRINO_VERSION) — no platform IdP, so no authentication (dev only)"; \
	  helm upgrade --install trino trino/trino \
	    --version $(TRINO_VERSION) \
	    $(HELM_FLAGS) \
	    -f helm-values/trino.yaml $(TRINO_EXTRA) $(TRINO_QUERYLOG); \
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
# Between applies, CronJob trino-group-sync (platform#167) keeps that ConfigMap
# converged every 5 minutes — membership changes land without any apply.
sync-trino-groups: _context ## Sync the live realm's stardelt-admins membership into ConfigMap trino-group-file (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/sync-trino-groups.sh

# platform#167: the group file above went stale between applies — a removed
# admin kept their all-queries view with no bound. The CronJob in
# manifests/trino-group-sync.yaml re-runs the sync every 5 minutes as the
# dedicated `trino-group-sync` service-account client (exactly view-users on
# realm-management, converged here; the import only declares it for fresh
# realms). install-identity runs this before `trino` so the client exists when
# the CronJob starts ticking.
sync-trino-group-sync-client: _context ## Converge the live realm's trino-group-sync client (secret + read-only grant, idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/keycloak-sync-trino-group-sync-client.sh

# The service principal scheduled pipelines run as (scheduled jobs J0, platform#118): a
# confidential service-account client whose tokens carry the audience `trino`.
sync-pipeline-runner-client: _context ## Converge the live realm's pipeline-runner client (secret, audience mapper, no admin role; idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/keycloak-sync-pipeline-runner-client.sh

# One principal per ServicePrincipal, owned by a realm group (scheduled jobs D20/D21,
# platform#244): client `sp-<name>`, Secret of the same name in the namespace, one audience
# mapper per requested audience, a groups mapper and membership of the owner group only.
.PHONY: sync-principal
sync-principal: _context ## Create or converge a ServicePrincipal client and its Secret (idempotent)
	@NAMESPACE=$(NAMESPACE) NAME=$(NAME) GROUP=$(GROUP) AUDIENCES=$(AUDIENCES) ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh

.PHONY: delete-principal
delete-principal: _context ## Delete a ServicePrincipal client and its Secret (stardelt-managed only; needs YES=1)
	@NAMESPACE=$(NAMESPACE) NAME=$(NAME) YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete

# Every caller of the Iceberg REST catalog gets its own confidential service client
# (platform#282, step 1 of the catalog turn-on): the Trino coordinator, Nova, the Spark
# Connect driver, the Airflow task pods and the bootstrap Job. Step 2 (platform#303) adds
# the two permission managers — the OPA bridge sidecar in the Lakekeeper pod and the
# operator's Catalog controller. Each token carries the audience `lakekeeper`, and
# Lakekeeper validates it since platform#285. A new caller gets a client the same way:
# `make sync-catalog-clients`, or `make sync-principal KIND=service NAME=<name>
# AUDIENCES=lakekeeper`; its Secret holds client-id/client-secret/token-url, and the
# NetworkPolicy must admit the pod.
CATALOG_CLIENTS := catalog-trino catalog-nova catalog-spark catalog-airflow catalog-bootstrap catalog-bridge catalog-operator

.PHONY: sync-catalog-clients
sync-catalog-clients: _context ## Create/converge the seven svc-catalog-* service clients and their Secrets (idempotent)
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-trino AUDIENCES=lakekeeper ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-nova AUDIENCES=lakekeeper ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-spark AUDIENCES=lakekeeper ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-airflow AUDIENCES=lakekeeper ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-bootstrap AUDIENCES=lakekeeper ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-bridge AUDIENCES=lakekeeper ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-operator AUDIENCES=lakekeeper ROTATE=$(ROTATE) bash scripts/keycloak-sync-principal.sh
	@# The chart's OPA bridge reads its scope from that one Secret (scopeSecretKey, default
	@# `scope`) and defaults it to the client scope `lakekeeper`, which this realm does not have
	@# (400 invalid_scope); `openid` is a default scope of every client, and the aud-lakekeeper
	@# mapper still puts the audience on the token. A merge of the same value changes nothing,
	@# so a rerun that changes nothing leaves the Secret's resourceVersion alone.
	@kubectl -n $(NAMESPACE) patch secret svc-catalog-bridge --type merge -p '{"stringData":{"scope":"openid"}}'

# ---------------------------------------------------------------------------
# Catalog authorization (platform#304, authz 3/8) — the OpenFGA cutover.
#
# A live operation: take a CloudNative-PG backup, upgrade Lakekeeper to
# `authz.backend: openfga`, re-bootstrap the catalog, reconcile OpenFGA and
# write the grants, then run the verification table. Idempotent: a second run
# reports every step as already done. A mistake locks the catalog out (403) —
# the recovery path is in the script and in the README "Catalog authorization"
# section. Never switch back to `allowall` by improvising; that is a maintainer
# decision.
# ---------------------------------------------------------------------------
.PHONY: catalog-authz
catalog-authz: _context ## Cut Lakekeeper over to OpenFGA authorization (idempotent; scripts/catalog-authz-bootstrap.sh)
	@NAMESPACE=$(NAMESPACE) LAKEKEEPER_VERSION=$(LAKEKEEPER_VERSION) HELM_FLAGS="$(HELM_FLAGS)" bash scripts/catalog-authz-bootstrap.sh

.PHONY: delete-catalog-clients
delete-catalog-clients: _context ## Delete the seven svc-catalog-* service clients and their Secrets (stardelt-managed only; needs YES=1)
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-trino YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-nova YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-spark YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-airflow YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-bootstrap YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-bridge YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete
	@NAMESPACE=$(NAMESPACE) KIND=service NAME=catalog-operator YES=$(YES) bash scripts/keycloak-sync-principal.sh --delete

# ---------------------------------------------------------------------------
# Access sync (platform#305, authz 4/8; platform#306, 5/8) — `Catalog` objects
# become Lakekeeper warehouses, their `owner`/`grants` become grants on them.
#
# CronJob `access-sync` (every 2 minutes) converges every Catalog into one
# Lakekeeper warehouse, turns each declared Keycloak group into a Lakekeeper role
# whose assignees are the group's members, writes the catalog's grants onto the
# warehouse, and writes `status.phase` / `status.warehouseId` plus the
# `GrantsReady` / `Drift` conditions back; scripts/access-sync-job.py holds the
# rules, the design and the "what is not built" list (per-catalog buckets). The
# script reaches the Pod on ConfigMap `access-sync-script`, refreshed here from the
# file on every apply so there is one source of truth — the pattern of CronJob
# trino-group-sync (platform#167).
#
# Needs the identity install: the job signs in to the catalog as
# `svc-catalog-operator` (project_admin) and reads groups from the realm as
# `trino-group-sync`, so a bare `install-core` — anonymous catalog, no IdP — gets
# no CronJob.
# ---------------------------------------------------------------------------
.PHONY: access-sync access-sync-now
access-sync: _context ## Create/refresh the script ConfigMap and apply CronJob access-sync
	@kubectl -n $(NAMESPACE) create configmap access-sync-script --from-file=job.py=scripts/access-sync-job.py \
	  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@kubectl apply -f manifests/access-sync.yaml

access-sync-now: _context ## Run one access-sync Job now, wait for it and print its log
	@name=access-sync-now-$$(date +%s); \
	  kubectl -n $(NAMESPACE) create job --from=cronjob/access-sync "$$name" >/dev/null; \
	  kubectl -n $(NAMESPACE) wait --for=condition=complete "job/$$name" --timeout=150s >/dev/null \
	    || { kubectl -n $(NAMESPACE) logs "job/$$name" 2>/dev/null || true; \
	         echo "job $$name did not complete — see the log above" >&2; exit 1; }; \
	  kubectl -n $(NAMESPACE) logs "job/$$name"

# ---------------------------------------------------------------------------
# More catalogs (platform#308, authz 6/8) — the Catalog objects become Trino
# catalogs and bridge mappings.
#
# A `Catalog` that access-sync turned Ready needs three more things to be usable:
# the OPA bridge must map its Trino catalog name to its warehouse, the Trino
# coordinator needs a catalog properties file, and the engine has to load it.
# scripts/render-catalogs.sh reads the objects and renders both arguments — no
# list of names lives in this repo; `warehouse` stays in the values files
# (helm-values/trino-identity.yaml repeats its properties, see the header there).
#
# Needs the identity install, like access-sync: the first step runs the CronJob as
# Job, so a cluster without a realm and `svc-catalog-operator` fails there and
# nothing reaches Lakekeeper.
#
# Trino cannot load a catalog live (the chart mounts a read-only ConfigMap), so
# an added or removed catalog rolls the coordinator and the worker — about a
# minute, and the coordinator restart drops running queries: pick a quiet moment.
# A run with nothing new renders the same ConfigMap and leaves both pods alone.
# ---------------------------------------------------------------------------
.PHONY: catalogs
catalogs: _context ## Converge Catalogs into Trino catalogs + bridge mappings (restarts Trino when the set changed)
	@$(MAKE) --no-print-directory access-sync-now
	@helm upgrade --install lakekeeper lakekeeper/lakekeeper \
	  --version $(LAKEKEEPER_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/lakekeeper.yaml \
	  $$(NAMESPACE=$(NAMESPACE) bash scripts/render-catalogs.sh bridge-arg) \
	  $$(NAMESPACE=$(NAMESPACE) bash scripts/render-catalogs.sh admin-arg)
	@kubectl -n $(NAMESPACE) rollout status deploy/lakekeeper --timeout=5m
	@$(MAKE) --no-print-directory trino

# ---------------------------------------------------------------------------
# Dev seed (platform#309, layout platform#365) — a small, repeatable permission
# set a person can check by hand: two domain groups (`finops`, `analytics`) and
# three seed people (plus the existing `analyst`). The baseline layout is the
# maintainer's five Catalogs (warehouse, shared, bronze, silver, gold); the seed
# creates groups, people and their Secret but does NOT apply
# dev/seed/catalogs.yaml unless SEED_CATALOGS=1 (that is how a deleted baseline
# Catalog comes back). The differentiated fixtures (finance, product, sandbox,
# with seed.nation) are opt-in: `make seed-permission-fixtures YES=1`.
#
# The seed is a development aid, never an install step: it refuses when
# ConfigMap `stardelt-identity` says environment=production, and every mutating
# target needs YES=1. Passwords are generated at run time and stored only in
# Secret `dev-seed-users` (one key per user name) — never printed, never
# committed. A second seed run changes nothing; `unseed` deletes only what
# carries the Keycloak attribute `stardelt-managed=seed` and that Secret — never
# a Catalog, a Lakekeeper warehouse, or data.
# ---------------------------------------------------------------------------
.PHONY: seed-dev-access unseed-dev-access seed-permission-fixtures unseed-permission-fixtures
.PHONY: verify-catalog-permissions
seed-dev-access: _context ## Create the dev seed groups, people and Secret (no Catalog unless SEED_CATALOGS=1; needs YES=1)
	@NAMESPACE=$(NAMESPACE) YES=$(YES) SEED_CATALOGS=$(SEED_CATALOGS) bash scripts/seed-dev-access.sh

unseed-dev-access: _context ## Remove the dev seed users, groups and their Secret (keeps every Catalog; needs YES=1)
	@NAMESPACE=$(NAMESPACE) YES=$(YES) bash scripts/seed-dev-access.sh --unseed

seed-permission-fixtures: _context ## Create the opt-in finance/product/sandbox Catalogs and their seed.nation tables (needs YES=1)
	@NAMESPACE=$(NAMESPACE) YES=$(YES) bash scripts/seed-dev-access.sh --fixtures

unseed-permission-fixtures: _context ## Remove the opt-in finance/product/sandbox Catalogs (never a baseline one; needs YES=1)
	@NAMESPACE=$(NAMESPACE) YES=$(YES) bash scripts/seed-dev-access.sh --unseed-fixtures

verify-catalog-permissions: _context ## Prove the live Catalog grants against the OPA bridge (exit 1 on any mismatch)
	@NAMESPACE=$(NAMESPACE) bash scripts/verify-catalog-permissions.sh

# ---------------------------------------------------------------------------
# The switch (platform#311, authz 8/8): Trino asks the OPA bridge, and the
# engine's user becomes the Keycloak `sub`.
#
# Before this, Trino authorizes by helm-values/trino-identity.yaml's file rules
# alone: every signed-in person may address every catalog, and a `Catalog`
# object's grants are enforced only on the catalog side — visible in Nova and
# Superset, which take their catalog list from the engine. After it, the
# `Catalog` grants decide, and a catalog nobody granted is not listed at all.
#
# Fail-closed: with `access-control.config-files` naming the bridge, an
# unreachable or wrong bridge denies every statement, including `SELECT 1`. So
# the gates run first, in this order, and the target stops at the first
# failure:
#
#   1. `make access-sync-now` — every Catalog's grants are on its warehouse,
#      and the role assignees are `oidc~<sub>` (the ids Trino will present);
#   2. `make verify-catalog-permissions` — the nine-question matrix answered by
#      the bridge itself (the questions the engine will ask);
#   3. `bash scripts/bridge-replay.sh --data-only` — the same answers against
#      the *captured* Trino requests (platform#333), so a request shape the
#      bridge mishandles fails here and not on a person's screen;
#   4. `bash scripts/sync-trino-groups.sh` — the group file by `sub`, so
#      `stardelt-admins` still matches what Trino compares against;
#   5. the Lakekeeper release with `OPABridge.adminUsers` (the same group), so
#      an administrator is not vetoed by the bridge;
#   6. `make trino` — the new values, both access-control files, the principal.
#
# Then the verification table in the ticket, by hand: the matrix per seed
# person, Superset, a notebook, Nova, Airflow, and the latency of one scan.
# `make catalog-enforce-rollback` is the way back. It rewrites the group file
# and re-applies Trino, so the two disagree between those steps; a failure in
# between leaves the group file naming the wrong strings (every group lookup
# silently matches nobody) until the target is run again. `deps` is therefore a
# prerequisite and the CronJob is switched back first, so a tool check or the
# five-minute writer cannot strand the rollback half-done (seen live on
# 2026-10-21).
#
# Two knobs define the state, and they must agree — a group file of `sub`
# strings while the engine compares usernames drops every group silently:
#   GROUP_PRINCIPAL=sub (default)  what the group file holds and what the
#                                  CronJob trino-group-sync keeps writing
#   TRINO_IDENTITY_OVERLAY=        an extra `-f` for `make trino`; the rollback
#                                  passes helm-values/trino-identity-file-only.yaml
# ---------------------------------------------------------------------------
.PHONY: catalog-enforce catalog-enforce-rollback
catalog-enforce: deps _context ## Switch Trino to the permission bridge and the sub principal (gated; see the header)
	@$(MAKE) --no-print-directory access-sync-now
	@$(MAKE) --no-print-directory verify-catalog-permissions
	@NAMESPACE=$(NAMESPACE) bash scripts/bridge-replay.sh --data-only
	@NAMESPACE=$(NAMESPACE) GROUP_PRINCIPAL=sub bash scripts/sync-trino-groups.sh
	@echo "› Lakekeeper: the bridge's administrators, from the group file"
	@helm upgrade --install lakekeeper lakekeeper/lakekeeper \
	  --version $(LAKEKEEPER_VERSION) \
	  $(HELM_FLAGS) \
	  -f helm-values/lakekeeper.yaml \
	  $$(NAMESPACE=$(NAMESPACE) bash scripts/render-catalogs.sh bridge-arg) \
	  $$(NAMESPACE=$(NAMESPACE) bash scripts/render-catalogs.sh admin-arg)
	@kubectl -n $(NAMESPACE) rollout status deploy/lakekeeper --timeout=5m
	@$(MAKE) --no-print-directory trino GROUP_PRINCIPAL=sub
	@kubectl -n $(NAMESPACE) rollout status deploy/trino-coordinator --timeout=5m
	@echo ""
	@echo "stardelt: Trino now authorizes through the permission bridge (user = Keycloak sub)."
	@echo "  Verify by hand (ticket #311): show catalogs / read / write / create per person,"
	@echo "  Superset, a notebook, Nova, Airflow, and the latency of one scan."
	@echo "  Roll back with: make catalog-enforce-rollback"

catalog-enforce-rollback: deps _context ## Put Trino back on the file rules and the username principal (recovery; see the README)
	@# Order matters, and every step before the Trino apply is a window in which the
	@# group file and the engine compare different strings (see the header). The
	@# recovery was exercised live on 2026-10-21 and the first version got this
	@# wrong: it rewrote the group file, then `make trino` stopped in its `deps`
	@# check, and the two disagreed until the target ran again. `deps` is a
	@# prerequisite now, and the CronJob goes first so the five-minute writer can
	@# never re-apply `sub` in the middle of the rollback.
	@# Stop the CronJob first: `make trino` had applied it with GROUP_PRINCIPAL=sub,
	@# and it rewrites the group file to ids within five minutes.
	@kubectl -n $(NAMESPACE) set env cronjob/trino-group-sync GROUP_PRINCIPAL=username >/dev/null
	@echo "› Group file back to usernames"
	@NAMESPACE=$(NAMESPACE) GROUP_PRINCIPAL=username bash scripts/sync-trino-groups.sh
	@echo "› Trino: helm-values/trino-identity-file-only.yaml (file access control only, preferred_username)"
	@$(MAKE) --no-print-directory trino GROUP_PRINCIPAL=username \
	  TRINO_IDENTITY_OVERLAY="-f helm-values/trino-identity-file-only.yaml"
	@kubectl -n $(NAMESPACE) rollout status deploy/trino-coordinator --timeout=5m
	@echo ""
	@echo "stardelt: Trino is back on the file rules alone — every signed-in person"
	@echo "  addresses every catalog again, and the Catalog grants enforce nothing."
	@echo "  The bridge's adminUsers list still holds sub ids until the next Lakekeeper"
	@echo "  apply; harmless while the bridge is not an authorizer."
	@echo "  Switch on again with: make catalog-enforce"

# ---------------------------------------------------------------------------
# The bridge contract (platform#333): what Trino sends the OPA authorizer, and
# what the bridge answers. `capture` runs the coordinator image as a throwaway
# pod with a stub authorizer that says yes and records every body; the fixture
# is the evidence, refreshed after a Trino upgrade. `replay` asks the live
# bridge the captured questions for the four seed principals and prints one
# table — no cluster change, one throwaway pod admitted by `lakekeeper-ingress`.
# `latency` is the timing companion (platform#359): `FilterCatalogs` with every
# catalog, five cold runs, min/median/max, one `AccessCatalog` and one
# `SelectFromColumns`, and the same answers from the chart's own rules — the gate
# that `SHOW CATALOGS` stays under 0.2 s (`make catalog-authz` runs it).
# `differential` is the correctness gate of the decision table: the front entry
# points against the chart's own rules, every catalog, every table that exists,
# every principal. `test-bridge-policies` proves the same policy in CI against a
# stub Lakekeeper that counts calls.
# `catalog-authz` and `catalog-enforce` (#311) run `replay --data-only` as a
# gate: the questions a query depends on must be answered correctly.
# ---------------------------------------------------------------------------
.PHONY: bridge-capture bridge-replay bridge-differential bridge-latency test-bridge-policies
bridge-capture: _context ## Capture the OPA requests Trino sends (rewrites scripts/tests/fixtures/trino-opa-requests.json)
	@NAMESPACE=$(NAMESPACE) bash scripts/bridge-capture.sh

bridge-replay: _context ## Replay the captured OPA requests against the live bridge (exit 1 on an error, empty answer or wrong data row)
	@NAMESPACE=$(NAMESPACE) bash scripts/bridge-replay.sh

bridge-differential: _context ## Prove the front entry points equal the chart's own rules (every catalog, every table, every principal; exit 1 on a difference)
	@NAMESPACE=$(NAMESPACE) bash scripts/bridge-replay.sh --differential

bridge-latency: _context ## Measure FilterCatalogs and one single question on the live bridge (exit 1 above 0.2 s / 0.05 s median or on any changed answer)
	@NAMESPACE=$(NAMESPACE) bash scripts/bridge-latency.sh

test-bridge-policies: ## Prove the decision-table policy against a stub Lakekeeper (needs helm with the lakekeeper repo + the opa binary)
	@bash scripts/test-bridge-policies.sh

# The public client developer tools on a laptop sign in with (platform#157): the device grant and
# PKCE to a loopback address. `make sync-dev-client DEV_CLIENT_ENABLED=false` switches it off.
sync-dev-client: _context ## Converge the live realm's stardelt-dev client (device grant, PKCE, loopback redirects; idempotent)
	@NAMESPACE=$(NAMESPACE) DEV_CLIENT_ENABLED=$(or $(DEV_CLIENT_ENABLED),true) bash scripts/keycloak-sync-dev-client.sh

# The audience `openbao` on the tokens of Nova, the notebook hub and the developer client, so the
# secret store's JWT sign-in accepts them (platform#160, decision D27).
.PHONY: sync-store-audience
sync-store-audience: _context ## Converge the live realm so Nova, hub and dev-client tokens carry the secret store's audience (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/keycloak-sync-store-audience.sh

# The audience `nova` on the notebook hub's and the developer client's tokens, so a notebook can
# call Nova with the token it already has (platform#290, notebook publishing; spike platform#268 B2).
.PHONY: sync-nova-audience
sync-nova-audience: _context ## Converge the live realm so hub and dev-client tokens carry Nova's audience (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/keycloak-sync-nova-audience.sh

# The audience `lakekeeper` on the notebook hub's and the developer client's tokens, so a notebook's
# Spark session talks to the catalog as the signed-in person (platform#317).
.PHONY: sync-catalog-audience
sync-catalog-audience: _context ## Converge the live realm so hub and dev-client tokens carry the catalog's audience (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/keycloak-sync-catalog-audience.sh

# External Secrets Operator (decision D23): syncs a secret store into Kubernetes Secrets. Opt-in.
external-secrets: deps _context _helm-repos ## Install External Secrets Operator (opt-in)
	@helm upgrade --install external-secrets external-secrets/external-secrets --version $(EXTERNAL_SECRETS_VERSION) $(HELM_FLAGS) -f helm-values/external-secrets.yaml

# The sandbox secret store (decision D23, platform#160): OpenBao, opt-in, never part of `install`. Production
# installs use the customer's own store through External Secrets and do not run this. The seal key and the
# volume belong together: never delete Secret openbao-seal-key while the volume of pod openbao-0 exists.
openbao: deps _context _helm-repos ## Install the sandbox secret store (OpenBao, opt-in): auto-unseal, KV v2, JWT sign-in with the platform IdP
	@NAMESPACE=$(NAMESPACE) bash scripts/openbao-seal-key.sh
	@helm upgrade --install openbao openbao/openbao --version $(OPENBAO_VERSION) $(HELM_FLAGS) -f helm-values/openbao.yaml
	@NAMESPACE=$(NAMESPACE) bash scripts/openbao-bootstrap.sh
	@NAMESPACE=$(NAMESPACE) OWNER_GROUPS="$(OWNER_GROUPS)" bash scripts/openbao-connections.sh

test-openbao-policies: ## Prove the connection policies against a throwaway local OpenBao (needs the bao binary)
	@bash scripts/test-openbao-policies.sh

# One SecretStore per owner group (and one for `managed`), each with its own role that reads only
# that group's path (decisions D23/D27, platform#220). Opt-in, needs `make external-secrets` first.
STORE_GROUPS ?=
eso-stores: ## Create one External Secrets store per owner group and for managed connections
	@NAMESPACE=$(NAMESPACE) bash scripts/eso-openbao-store.sh managed $(STORE_GROUPS)

# platform#80: the in-cluster path must refuse plain HTTP and authenticate a
# bearer token over TLS. TRINO_VERIFY_USER_PASSWORD=… adds the user check.
verify-trino-tls: _context ## Prove the in-cluster Trino path is TLS-only and token-authenticated
	@NAMESPACE=$(NAMESPACE) bash scripts/verify-trino-tls.sh

# The path clients take, end to end: anonymous refusal, the service-account Secret,
# the user's own token (TRINO_VERIFY_USER_PASSWORD=… adds that check), and
# Superset's own stored connection — the one that went stale in platform#278.
verify-trino-auth: _context ## Prove Trino's authentication end to end, including Superset's stored connection
	@NAMESPACE=$(NAMESPACE) bash scripts/verify-trino-auth.sh

install-identity: deps _context ## Install the platform IdP (Keycloak) at id.$(BASE_DOMAIN)
	@kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || { \
	  echo "CloudNative-PG CRDs not found — run 'make install-core' first" >&2; exit 1; }
	@echo "› [1/11] Secrets + realm/identity ConfigMaps (base domain $(BASE_DOMAIN))"
	@NAMESPACE=$(NAMESPACE) BASE_DOMAIN=$(BASE_DOMAIN) bash scripts/identity-bootstrap.sh
	@echo "› [2/11] CNPG Cluster (Keycloak Postgres)"
	@kubectl apply -f manifests/keycloak.yaml
	@echo "› [2/11] guard: the live Cluster must still declare its backup config"
	@$(MAKE) --no-print-directory verify-backup-config PG_CLUSTER=keycloak-pg
	@kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/keycloak-pg
	@echo "› [3/11] Keycloak $(KEYCLOAK_VERSION)"
	@kubectl -n $(NAMESPACE) rollout status deploy/keycloak --timeout=10m
	@echo "› [4/11] Heal realm-admin drift: the Secret is the source of truth, not the import"
	@$(MAKE) --no-print-directory sync-realm-admin
	@echo "› [5/11] guard: the documented realm admin must still sign in"
	@$(MAKE) --no-print-directory verify-realm-admin
	@echo "› [6/11] Realm admins manage users (roles + brute force on a live realm)"
	@$(MAKE) --no-print-directory sync-realm-user-management
	@echo "› [7/11] Heal app-client drift: Secret stardelt-oidc-clients is the source of truth too"
	@$(MAKE) --no-print-directory sync-oidc-clients SYNC_TRINO=0
	@echo "› [8/11] Sync the live realm's Trino client (import skips an existing realm)"
	@NAMESPACE=$(NAMESPACE) TRINO_PUBLIC_URL=https://trino.$(BASE_DOMAIN) \
	  bash scripts/keycloak-sync-trino-client.sh
	@echo "› [9/11] Sync the live realm's group-sync client (read-only service account, platform#167)"
	@$(MAKE) --no-print-directory sync-trino-group-sync-client
	@echo "› [9/11] Sync the live realm's pipeline-runner client (scheduled pipelines, platform#118)"
	@$(MAKE) --no-print-directory sync-pipeline-runner-client
	@echo "› [9/11] Sync the live realm's developer sign-in client (stardelt-dev, platform#157)"
	@$(MAKE) --no-print-directory sync-dev-client
	@echo "› [9/11] Sync the live realm's secret-store audience (platform#160)"
	@$(MAKE) --no-print-directory sync-store-audience
	@echo "› [10/11] guard: every client secret must authenticate at the token endpoint"
	@$(MAKE) --no-print-directory verify-oidc-clients
	@echo "› [10/11] Sync the live realm's Nova audience (notebook publishing, platform#290)"
	@$(MAKE) --no-print-directory sync-nova-audience
	@echo "› [10/11] Sync the live realm's catalog audience (Spark in notebooks, platform#317)"
	@$(MAKE) --no-print-directory sync-catalog-audience
	@echo "› [10/11] Catalog callers get their own service clients (svc-catalog-*, platform#282)"
	@$(MAKE) --no-print-directory sync-catalog-clients
	@echo "› [11/11] Put the query engine behind the platform identity (TLS on the coordinator)"
	@$(MAKE) --no-print-directory trino
	@# Nova reads its Trino endpoint from the identity ConfigMap (authMode turned
	@# sign-in on, trinoUrl turns on the in-cluster TLS endpoint) and both are
	@# process environment, not watched files: without this restart a fresh
	@# install would keep running the dev-mode, plain-HTTP Nova it started with.
	@if kubectl -n $(NAMESPACE) get deploy nova >/dev/null 2>&1; then \
	  echo "› Nova: re-apply the manifest and restart so it re-reads the identity contract"; \
	  kubectl apply -f manifests/nova-pg.yaml; \
	  kubectl -n $(NAMESPACE) wait --for=condition=Ready --timeout=300s cluster/nova-pg; \
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
	@kubectl delete -f manifests/trino-group-sync.yaml          --ignore-not-found
	@kubectl -n $(NAMESPACE) delete configmap trino-group-sync-script --ignore-not-found
	@kubectl delete -f manifests/access-sync.yaml              --ignore-not-found
	@kubectl -n $(NAMESPACE) delete configmap access-sync-script --ignore-not-found
	@kubectl delete -f manifests/spark.yaml                   --ignore-not-found
	@kubectl delete -f manifests/trino-tls.yaml               --ignore-not-found
	@kubectl delete -f manifests/nova-deployment.yaml        --ignore-not-found
	@kubectl delete -f manifests/nova-pg.yaml                --ignore-not-found
	@kubectl delete -f manifests/keycloak.yaml               --ignore-not-found
	@kubectl -n $(NAMESPACE) delete configmap keycloak-realm keycloak-env stardelt-identity --ignore-not-found
	@kubectl delete -f manifests/lakekeeper-network-policy.yaml --ignore-not-found
	@kubectl delete -f manifests/openfga-network-policy.yaml  --ignore-not-found
	@kubectl delete -f manifests/lakekeeper-bootstrap.yaml   --ignore-not-found
	@kubectl delete -f manifests/cnpg-postgres.yaml          --ignore-not-found
	@kubectl delete -f manifests/openfga-pg.yaml             --ignore-not-found

	@echo "› uninstalling helm releases"
	@helm uninstall jupyterhub --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall superset   --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@kubectl delete -f manifests/airflow-pipelines.yaml --ignore-not-found
	@helm uninstall airflow    --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall reloader   --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall external-secrets --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall openbao    --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall trino      --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall lakekeeper --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
	@helm uninstall openfga    --namespace $(NAMESPACE) --ignore-not-found 2>/dev/null || true
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
	  $(MAKE) --no-print-directory sync-catalog-clients; \
	  if kubectl -n $(NAMESPACE) get deploy nova >/dev/null 2>&1; then \
	    echo "› Nova: restart so it reads the catalog client the sync just created"; \
	    kubectl -n $(NAMESPACE) rollout restart deploy/nova; \
	  fi; \
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
# Published notebooks — the versioned bucket Nova writes notebook versions to
# (platform#290). The version, not the key, is what a scheduled notebook pins
# (spike #268 B1: byte-stable across overwrites, deletes and gateway restarts).
# The SeaweedFS chart's bucket hook only creates buckets, so this calls the S3
# API with the platform identity; re-running prints the same bucket/state line.
# ---------------------------------------------------------------------------
.PHONY: notebooks-bucket
notebooks-bucket: _context ## Create the versioned `notebooks` bucket for published notebooks (idempotent)
	@NAMESPACE=$(NAMESPACE) bash scripts/create-notebooks-bucket.sh

# ---------------------------------------------------------------------------
# Port-forwards
# ---------------------------------------------------------------------------
pf: ## Open port-forwards to in-cluster services
	@NAMESPACE=$(NAMESPACE) bash scripts/port-forwards.sh

# The object store's own web UI for cluster administrators (decision D28): a port-forward, nothing is exposed.
seaweedfs-admin: _context ## Open the object store's admin UI on http://127.0.0.1:23646 (login: Secret seaweedfs-admin-ui)
	@echo "› http://127.0.0.1:23646 — user admin; password: kubectl -n $(NAMESPACE) get secret seaweedfs-admin-ui -o jsonpath='{.data.password}' | base64 -d"
	@kubectl -n $(NAMESPACE) port-forward svc/seaweedfs-admin 23646:23646

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
