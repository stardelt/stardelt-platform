# stardelt-platform

Production-shape deployment artifacts. Helm values, manifests, and scripts to install stardelt on any conformant Kubernetes cluster.

> For a local laptop demo (kind cluster, sample data), see [github.com/stardelt/stardelt-demos](https://github.com/stardelt/stardelt-demos).
> Full documentation: [stardelt.io](https://stardelt.io)

---

## Prerequisites

| Tool | Minimum version | Notes |
|------|----------------|-------|
| `kubectl` | 1.28+ | Must be configured with a valid kubeconfig pointing at your cluster |
| `helm` | 3.18+ | The `stardelt-dedupe` post-renderer plugin is installed automatically |
| `docker` | any recent | Required only for `make build-superset-image` / `make push-superset-image` |

Your `kubectl` current-context determines the target cluster. Verify with:

```sh
kubectl config current-context
```

Every installing or uninstalling `make` target prints the context it is about to act on.
Set `EXPECT_CONTEXT` to make it refuse any other cluster:

```sh
EXPECT_CONTEXT=stardelt-dev make install-core
```

---

## S3 credentials (required before install)

All components that touch object storage read credentials from the `stardelt-s3-creds` Secret. Copy the example, fill it in, and apply it **before** running `make install`:

```sh
cp manifests/s3-credentials.example.yaml manifests/s3-credentials.yaml
# Edit manifests/s3-credentials.yaml — fill in access-key, secret-key, endpoint, bucket, region
kubectl apply -f manifests/s3-credentials.yaml
```

---

## Quickstart

```sh
make deps      # verify kubectl + helm are present
make install   # add helm repos, install plugin, deploy all components
make pf        # open port-forwards
```

Override the namespace (default: `stardelt`):

```sh
NAMESPACE=my-namespace make install
```

---

## Helm chart (baseline)

`chart/` is the declarative alternative to `make install`: one umbrella chart
(`stardelt-platform`) with every component as a sub-chart, plus Nova, the CNPG
Postgres cluster, the S3 credentials Secret and the Lakekeeper bootstrap Job as
templates. Same chart versions, same values and same object names as the
Makefile path — use **one or the other** per namespace, not both.

```sh
make chart-deps     # helm dependency update chart (fetches the sub-charts)
make chart-template # render to stdout, change nothing
make chart-install  # helm upgrade --install stardelt chart -n stardelt
```

What is on by default (same shape as `make install-core`): the CNPG operator and
its `lakekeeper-pg` Cluster, SeaweedFS, Lakekeeper, the Lakekeeper bootstrap Job,
Trino, the `stardelt-s3-creds` Secret and Nova. Off by default: Superset,
Airflow and JupyterHub. Turn them on via `--set` or your own values file:

```sh
make chart-install CHART_EXTRA="--set superset.enabled=true -f my-values.yaml"
```

Two things to know before enabling the heavy components: Superset and Airflow
cannot both be enabled in one release — the Superset chart's bundled Redis defines
the same Helm template names as the Airflow chart, so the render fails — and their
objects are named after the release (`stardelt-api-server`, `stardelt-postgresql`,
...) rather than `airflow-api-server`, so the playground ingress needs the matching
name.

For a small single node (cx33 / 8 GB), `chart/values-slim.yaml` mirrors
`helm-values/slim/trino.yaml`:

```sh
make chart-install CHART_EXTRA="-f chart/values-slim.yaml"
```

With ingress.enabled=true only Nova (and Keycloak in identity.mode=platform) get an Ingress; list components in ingress.exposeUnauthenticated (e.g. [trino]) to expose a UI that has no sign-in.

The default `stardelt-s3-creds` Secret holds the dev credentials that match the
SeaweedFS sub-chart (as `make install-core` does). For a real install override
`s3Credentials.accessKey` / `secretKey`, or set `s3Credentials.create=false` and
create the Secret yourself from `manifests/s3-credentials.example.yaml`.

A chart install also gets the catalog's continuous backups (`postgres.backup`,
on by default): the `lakekeeper-pg` Cluster declares `spec.backup.barmanObjectStore`
writing to `s3://<postgres.backup.bucket>/` on `s3Credentials.endpoint`, and the
daily `ScheduledBackup` `lakekeeper-pg-daily` (`immediate: true`) adds base
backups. The destination bucket must exist — the SeaweedFS sub-chart creates
`backups`, but with `s3Credentials.create=false` create it in your own store
first. The #59 backup guards describe a chart install as well; point them at the
release namespace: `NAMESPACE=<release ns> make verify-backup-config` / `verify-backups`.

---

## Airflow and Superset credentials

Neither values file contains a secret. `scripts/app-secrets.sh` generates them on the
cluster and every install path runs it first (`make install`, `make chart-install`);
`make install-core` does not need it. It is idempotent — a Secret that already exists is
left untouched, so re-running an install never rotates a key under a running stack.

| Secret | Keys | Read by |
|---|---|---|
| `airflow-fernet-key` | `fernet-key` | `fernetKeySecretName` |
| `airflow-webserver-key` | `webserver-secret-key`, `api-secret-key` | `webserverSecretKeySecretName` (Airflow <3) and `apiSecretKeySecretName` (Airflow 3) |
| `airflow-jwt-secret` | `jwt-secret` | `jwtSecretName` |
| `airflow-admin` | `username`, `password` | create-user Job env → `airflow users create` |
| `superset-secret-key` | `secret-key` | `SUPERSET_SECRET_KEY` via `extraEnvRaw` |
| `superset-admin` | `username`, `password`, `firstname`, `lastname`, `email` | Superset init Job (password) |

The Airflow chart has no Secret reference for `createUserJob.defaultUser` and the Superset
chart has no `supersetSecretKeySecretName` (its `extraSecretEnv` writes literals), so both
values files use the charts' next-smallest hooks instead: `createUserJob.env` plus custom
`args`, and `extraEnvRaw` plus a copy of the default `init.initscript` that reads the
password from the environment. Usernames and profile fields stay in values; only
credentials come from Secrets.

The Secrets carry `app.kubernetes.io/part-of=stardelt` and belong to no Helm release, so
`make uninstall` / `helm uninstall` keep them (like the PVCs). Read one back deliberately —
the script never prints a value:

```sh
kubectl -n stardelt get secret airflow-admin -o jsonpath='{.data.password}' | base64 -d
kubectl -n stardelt get secret airflow-fernet-key -o jsonpath='{.data}' | jq 'keys'
```

To rotate, delete the Secret and re-run the step — `NAMESPACE=stardelt bash
scripts/app-secrets.sh` (or the next `make install`). Two things to know:

- **The fernet key is not like the others.** Rotating `airflow-fernet-key` makes every
  connection Airflow stored encrypted in its metadata database undecryptable; the stored
  credentials have to be re-entered. Rotating the API/JWT/session keys only ends sessions
  (Superset users get logged out).
- **The Airflow create-user Job only creates the user.** Changing an existing user's
  password is Airflow CLI work, not a Secret edit. And because Job specs are immutable,
  delete the two Airflow Jobs before the first upgrade that carries this change:
  `kubectl -n stardelt delete job airflow-create-user airflow-run-airflow-migrations`.

---

## Identity (optional platform IdP)

stardelt has two identity modes (contract: `docs/architecture/identity` in stardelt-docs):
an **external** OIDC provider (Entra ID, Okta, a corporate Keycloak) or the **platform** IdP,
Keycloak, that every building block authenticates against. Either way the platform publishes
the same ConfigMap, `stardelt-identity`, with `issuerUrl`, `groupClaim` (`groups`) and
`adminGroup` (`stardelt-admins`).

| Umbrella chart | Makefile | What is deployed |
|---|---|---|
| `identity.mode: none` (default) | — | nothing |
| `identity.mode: platform` | `make install-identity` | Keycloak (official `quay.io/keycloak/keycloak`, Apache-2.0) + its own CNPG Cluster `keycloak-pg`, realm `stardelt`; Ingress `id.<baseDomain>` when `ingress.enabled` (playground: `dev/playground/ingress.yaml`) |
| `identity.mode: external` + `identity.issuerUrl` | — | only `stardelt-identity` (render fails without an https issuer) |

```sh
make install-core SLIM=1                                    # CNPG operator first
make install-identity BASE_DOMAIN=alpha.dev.stardelt.io     # Keycloak at https://id.<BASE_DOMAIN>
# or: make chart-install CHART_EXTRA="--set identity.mode=platform --set platform.baseDomain=example.com"
```

### Embedding JupyterHub in Nova

Nova's Notebooks page embeds the hub, and the hub refuses framing by default
(`frame-ancestors 'none'`, its clickjacking protection since JupyterHub 4.1) — so Nova reports
`embed.state: blocked` with the exact header rather than showing a blank iframe. `helm-values/jupyterhub.yaml`
carries the narrow override that allows **only** Nova's origin, and the umbrella chart documents it
under `jupyterhub:` for admins who want the same. Without it, nothing breaks: the page explains
itself and the hub stays unembeddable.

### Turning on sign-in

Deploying the IdP does not put anything behind a login: that is Nova's decision
(`nova.auth.mode`) plus, later, the other building blocks' own clients.

```sh
# chart path — the IdP and the login in one install
helm upgrade --install stardelt chart -n stardelt \
  --set identity.mode=platform --set platform.baseDomain=example.com \
  --set nova.auth.mode=oidc

# manifest path — set two values on the Deployment after `make install-identity`
kubectl -n stardelt set env deploy/nova \
  NOVA_AUTH_MODE=oidc NOVA_PUBLIC_URL=https://example.com
```

The issuer, client secret and session secret are read from `stardelt-identity`,
`stardelt-oidc-clients` (key `nova`) and `stardelt-nova-session` — all created by
`scripts/identity-bootstrap.sh` (manifest path) or by the chart (identity mode ≠ none), so
the only thing an operator supplies is the mode and Nova's public URL. The redirect URI
`<publicUrl>/api/auth/callback` must be registered at the IdP; the realm import does that
for the `nova` client already.

Two deliberate behaviours: the render **fails** when `nova.auth.mode=oidc` is set without
an issuer (rather than shipping a pod that crash-loops), and `dev` stays the default
everywhere, because CI, `make demo` and the kind gate have no IdP.

Rotating the session secret logs everyone out: delete the Secret and re-run the installer
(the chart regenerates it and keeps it across upgrades — `helm.sh/resource-policy: keep`).

The realm import (`chart/files/keycloak-realm.json`, shared by both paths) defines group
`stardelt-admins`, user `admin` in it, a `groups` claim (group names, full path off) and these clients:

| Client | Type | Redirect URI |
|---|---|---|
| `nova` | confidential, code + PKCE | `https://<baseDomain>/api/auth/callback` |
| `trino` | public, code + PKCE, device grant | `https://trino.<baseDomain>/oauth2/callback` |
| `lakekeeper` | confidential | `https://lakekeeper.<baseDomain>/ui/*` |
| `superset` | confidential | `https://superset.<baseDomain>/oauth-authorized/keycloak` |
| `airflow` | confidential | `https://airflow.<baseDomain>/auth/oauth-authorized/keycloak` |
| `jupyterhub` | confidential | `https://jupyter.<baseDomain>/hub/oauth_callback` |

**No committed credentials.** On first install the Keycloak bootstrap-admin password, the realm
`admin` password and the five client secrets are generated (`openssl rand` in
`scripts/identity-bootstrap.sh`; `randAlphaNum` + `lookup` in the chart) into the Secrets
`keycloak-admin`, `stardelt-realm-admin` and `stardelt-oidc-clients` (one key per client). They are
never printed, the realm ConfigMap only holds `${ENV}` placeholders, and re-runs keep existing
values. `make uninstall` (and `helm uninstall`) leave the Secrets in place; delete them to rotate
before a fresh install. The realm is imported only when it does not exist yet, so later edits to the
realm file are not applied to a running realm.

Sizing (single node): Keycloak 100m / 512Mi request, 1 CPU / 1Gi limit, one replica,
`KC_CACHE=local`; its Postgres 50m / 128Mi request, 256Mi limit, 1Gi volume. The Keycloak image is
pinned as `KEYCLOAK_VERSION` in the Makefile and mirrored in `manifests/keycloak.yaml` and
`identity.keycloak.image.tag`; `scripts/check-version-parity.sh` checks all three and Renovate
updates them together. Behind ingress-nginx, raise `proxy-buffer-size` for the `id.` host (the
playground Ingress sets `16k`; for the chart pass it through `ingress.annotations`), since Keycloak's
login responses outgrow nginx's default 4k header buffer.

---

## Makefile targets

| Target | Description |
|--------|-------------|
| `help` | List all targets with descriptions |
| `deps` | Run `scripts/check-deps.sh` to verify CLI tools |
| `lint` | `bash -n` + ShellCheck every script under `scripts/` and `dev/` (ShellCheck only if installed) |
| `install` | Add helm repos, deploy the full stack (11 steps; generates the Airflow/Superset Secrets first) |
| `install-core` | Core only (storage + catalog + query + Nova) — fits a small node; `SLIM=1` for 8 GB |
| `verify-backup-config` | Post-apply guard (also run by both install targets): the live `lakekeeper-pg` Cluster must still declare `spec.backup`, or the command fails loudly |
| `verify-backups` | Full WAL check: `spec.backup` + the newest object in `s3://backups/lakekeeper-pg/wals/` is younger than `MAX_AGE_SECONDS` (900) + it matches `pg_stat_archiver.last_archived_wal`. `SKIP_OBJECTS=1` skips the S3 half |
| `install-notebooks` | JupyterHub (notebooks) |
| `install-identity` | Platform IdP: Keycloak + CNPG Postgres + realm `stardelt` (`BASE_DOMAIN=…`, see [Identity](#identity-optional-platform-idp)) |
| `install-operator` | Install the stardelt Operator from `../stardelt-operator/chart` (dev path) |
| `pin` | Pin a deployment to the newest published digest **and write it back into `manifests/nova-deployment.yaml`** (`make pin APP=nova`), so a later `kubectl apply` cannot put the mutable tag back |
| `pin-images` | Pin Nova and the operator to their digests (the install targets do this themselves) |
| `upgrade` | Re-run `install` (helm upgrade is idempotent) |
| `uninstall` | Remove all helm releases and manifests in reverse order |
| `chart-deps` | `helm dependency update chart` — fetch/refresh the umbrella chart's sub-charts |
| `chart-template` | Render the umbrella chart (`helm template stardelt chart -n <ns>`) |
| `chart-install` | Install/upgrade the umbrella chart as release `stardelt` (see [Helm chart](#helm-chart-baseline)) |
| `build-superset-image` | Build `ghcr.io/stardelt/superset:dev` locally |
| `push-superset-image` | Push that image to ghcr.io |
| `pf` | Open port-forwards to Nova, Trino, Lakekeeper, Superset |
| `dev-up` / `dev-down` | Create / delete the Hetzner k3s development cluster |
| `dev-dns` / `dev-dns-down` | Point / remove the playground DNS records |

---

## Repository layout

```
chart/                Umbrella Helm chart (see "Helm chart (baseline)")
  Chart.yaml            Dependencies + conditions; versions mirror the Makefile pins
  values.yaml           Per-sub-chart values, mirrored from helm-values/
  values-slim.yaml      Small-node Trino overrides (mirrors helm-values/slim/)
  templates/            Nova, CNPG Cluster + ScheduledBackup, S3 Secret, Lakekeeper bootstrap Job, Keycloak/identity
  files/                keycloak-realm.json — realm import shared with make install-identity
  charts/               Sub-charts, fetched by `make chart-deps` (not committed)

helm-values/          Helm values files, one per chart
  airflow.yaml          Apache Airflow 3.x (KubernetesExecutor)
  jupyterhub.yaml       JupyterHub multi-user notebooks
  lakekeeper.yaml       Lakekeeper Iceberg REST catalog
  seaweedfs.yaml        SeaweedFS S3-compatible storage
  superset.yaml         Apache Superset BI
  trino.yaml            Trino MPP SQL engine
  slim/                 Small-node overrides (see `SLIM=1`)

manifests/            Plain Kubernetes manifests (kubectl apply)
  cnpg-postgres.yaml    CloudNative-PG Cluster for Lakekeeper metadata
  keycloak.yaml         Platform IdP: Keycloak + its CNPG Cluster (make install-identity)
  lakekeeper-bootstrap.yaml  Job: accept ToS + create default warehouse
  nova-deployment.yaml  stardelt Nova UI + backend
  s3-credentials.example.yaml  Template for the stardelt-s3-creds Secret

images/
  superset/Dockerfile   Superset 5.0.0 + psycopg2 + trino driver

scripts/
  app-secrets.sh        Generate the Airflow/Superset Secrets (idempotent, never printed)
  check-deps.sh         Verify required CLI tools
  identity-bootstrap.sh Generate the IdP Secrets + render realm/identity ConfigMaps
  lint.sh               bash -n + ShellCheck the shell scripts (make lint)
  port-forwards.sh      Background port-forwards to all services
  protect-branches.sh   Apply `main` branch protection in all five stardelt repos
  verify-backups.sh     Backup guards: post-apply spec.backup assert + bucket-vs-database WAL check
  helm-plugins/
    stardelt-dedupe/    Helm v4 post-renderer: deduplicates env lists
```

---

## Branch protection

`main` is protected in every stardelt repo (`stardelt-docs`, `stardelt-platform`, `stardelt-nova`,
`stardelt-operator`, `stardelt-demos`) by [`scripts/protect-branches.sh`](scripts/protect-branches.sh)
(`bash scripts/protect-branches.sh`, `--dry-run` to preview). Each repo requires the CI job names its
pull requests report — validated against checks actually seen on recent PRs, because a wrong name would
silently block every merge — plus no force pushes, no deletions and linear history. Pull requests are
required but no approvals: the maintainer and AI agents merge under one owner account, so CI is the gate;
`enforce_admins` stays off for emergencies. Re-run it after a workflow job name changes.
Collaboration/release branches are planned later (issue #38).

---

## Component versions

| Component | Chart version | App version |
|-----------|--------------|-------------|
| CloudNative-PG | 0.28.2 | — |
| SeaweedFS | 4.25.1 | 4.25 |
| Lakekeeper | 0.11.0 | 0.12.2 |
| Trino | 1.42.2 | 480 |
| Apache Airflow | 1.21.0 | 3.2.0 |
| Apache Superset | 0.15.5 | 5.0.0 |
| Keycloak (image, no chart) | — | 26.8.1 |

---

## Version pins

Chart and application versions are pinned in the root [`Makefile`](Makefile) — one
`<COMPONENT>_VERSION := x.y.z` line per chart. Every Makefile install path
(`make install`, `make install-core`) reads the pin from there, so that file is the
source of truth for what gets deployed and a version bump is a one-line change.

The umbrella chart needs the same numbers again as literal `dependencies[].version`
entries in [`chart/Chart.yaml`](chart/Chart.yaml) (Helm cannot read a Make variable).
Renovate reads that file natively and the `helm charts` group below covers it, so a
bump normally arrives as one PR touching both files.

Dependencies are kept current by [Renovate](https://docs.renovatebot.com/), configured in
[`renovate.json`](renovate.json). It opens grouped pull requests for:

- the `*_VERSION` chart pins in the `Makefile` (read as Helm chart versions — see the
  per-pin comments in `renovate.json` for why each one uses the `helm` datasource),
- the `dependencies` in `chart/Chart.yaml` (Helm datasource, same group),
- the base images in `images/**/Dockerfile`,
- the action versions in `.github/workflows/**`,

on a weekly schedule. Renovate keeps the versions exact (`rangeStrategy: pin`); major chart
bumps are held back until they are approved on the Dependency Dashboard, since a chart major
is what usually breaks a values file. Upgrading a component is therefore normally a review of
a Renovate PR rather than a manual edit.

Note that the table above and the `--version` flags in `.github/workflows/ci.yml` are still
hand-maintained copies of the `Makefile` pins — keep them in sync when reviewing a chart bump.

---

## Configuration

### Overriding helm values

The simplest approach is to add a second values file and pass it at the end (later files win):

```sh
# Create an override file
cp helm-values/trino.yaml my-trino-overrides.yaml
# Edit as needed, then:
helm upgrade --install trino trino/trino \
  --version 1.42.2 \
  --namespace stardelt \
  -f helm-values/trino.yaml \
  -f my-trino-overrides.yaml
```

For persistent overrides, modify the files in `helm-values/` directly and commit them.

### Nova image

`manifests/nova-deployment.yaml` uses `ghcr.io/stardelt/nova:dev` with
`imagePullPolicy: Always`, and pulls through the `ghcr-creds` secret.

### Superset image

The Superset image adds `psycopg2-binary` and the `trino` SQLAlchemy driver to the
upstream Superset 5.0.0 base. **CI builds it** — the `Image` workflow in this repo
publishes `ghcr.io/stardelt/superset:dev` (plus `sha-<short>`) on merge to `main`, and
`helm-values/superset.yaml` points at it with the `ghcr-creds` pull secret. A local
`make build-superset-image` + `make push-superset-image` is only for iteration.

---

## Container images

stardelt images live under `ghcr.io/stardelt/*` and are built by CI, not by the
cluster: merge to `main` publishes `dev` and an immutable `sha-<short>` tag, and the
job summary prints the digest. **Pin deployments by digest** — a moving tag may keep
serving a cached layer.

`nova` is public; `operator` and `superset` are internal/private until someone flips
them in the package settings (the API refuses), so the cluster needs a pull secret
named `ghcr-creds` in the namespace:

```sh
./dev/ghcr-pull-secret.sh          # uses your `gh auth token`
GHCR_TOKEN=<read:packages PAT> ./dev/ghcr-pull-secret.sh   # preferred
```

The secret lives in the cluster, so give it a token that can only read packages
(`GHCR_TOKEN`) rather than your full `gh` login token. It acts on the current kube-context
(or `KUBE_CONTEXT`) and prints it first.

Alternatively, make the packages public in the GitHub package settings and drop the
`imagePullSecrets` entry. `nova:dev` is a mutable tag — pin by digest for reproducible installs.

## Uninstalling

```sh
make uninstall
```

This removes helm releases in reverse dependency order and deletes the manifests. PVCs
are intentionally left in place; delete them manually if you want to reclaim storage:

```sh
kubectl delete pvc --all -n stardelt
```
