# Makefile targets

Part of the [stardelt-platform](../README.md) manual.

| Target | Description |
|--------|-------------|
| `help` | List all targets with descriptions |
| `deps` | Run `scripts/check-deps.sh` to verify CLI tools |
| `lint` | `bash -n` + ShellCheck every script under `scripts/` and `dev/` (ShellCheck only if installed) |
| `install` | Add helm repos, deploy the full stack (the same step targets `make platform` runs, in the same order) |
| `install-core` | Core only (storage + catalog + query + Nova) — fits a small node; `SLIM=1` for 8 GB |
| `verify-backup-config` | Post-apply guard (also run by both install targets): the live `lakekeeper-pg` Cluster must still declare `spec.backup`, or the command fails loudly |
| `verify-backups-nova` | Same full WAL check for `nova-pg` (`s3://backups/nova-pg/wals/`) |
| `verify-backups` | Full WAL check: `spec.backup` + the bucket covers every WAL segment PostgreSQL has queued (the current segment, or the previous one with no `.ready` file) + it matches `pg_stat_archiver.last_archived_wal`. `SKIP_OBJECTS=1` skips the S3 half |
| `verify-backups-identity` | Same full WAL check for `keycloak-pg` (`s3://backups/keycloak-pg/wals/`) |
| `verify-backups-openfga` | Same full WAL check for `openfga-pg` (`s3://backups/openfga-pg/wals/`) |
| `backups` | Apply the two `pg_dump` CronJobs (`superset-pg-dump`, `airflow-pg-dump`) from `manifests/pg-dump-backup.yaml` |
| `export-recovery-secrets` | Write the Secrets that make the backups readable — the OpenBao seal/init material, Lakekeeper's and Airflow's encryption keys, the object-store credentials, the IdP administrators — to one encrypted file (`FILE=…`, `RECOVERY_PASSPHRASE` in the environment, `0600`, refused inside the repository) |
| `import-recovery-secrets` | Restore them with `kubectl apply` into `NAMESPACE` (`CHECK=1` decrypts and lists the names without applying) — first step of a restore |
| `verify-pgdump` | Run those CronJob(s) once (`PG_DUMP=superset\|airflow\|all`), restore the newest dump into a scratch database with `pg_restore --exit-on-error`, and compare the table count with the live database |
| `install-notebooks` | JupyterHub (notebooks) |
| `install-spark` | Spark Connect endpoint (`manifests/spark.yaml`); catalogs are per person in the session (platform#317), no static catalog in the ConfigMap. Restarts the driver only when its ConfigMap changed |
| `openfga` | OpenFGA permission store + its CNPG Postgres (`helm-values/openfga.yaml`, `manifests/openfga-pg.yaml`); not wired to Lakekeeper until the cutover (#302) |
| `install-identity` | Platform IdP: Keycloak + CNPG Postgres + realm `stardelt`, then the realm-admin sync + guard, the user-management roles/brute-force sync, the client-secret sync + guard, the live-realm Trino client, the Nova and catalog audiences, and the Trino OAuth2 overlay (`BASE_DOMAIN=…`, see [Identity](identity.md#identity-optional-platform-idp)) |
| `sync-realm-admin` | Point realm `stardelt`'s `admin` at Secret `stardelt-realm-admin` through the master-realm API; idempotent, runs as part of `install-identity`/`chart-install` (#81) |
| `verify-realm-admin` | Prove the realm-admin Secret still signs in — a real password grant as that user through `svc/keycloak`; fails with the fix in the message |
| `sync-realm-user-management` | Grant `stardelt-admins` the four `realm-management` user-management roles and enforce brute-force protection on the live realm; idempotent, runs with both install paths |
| `sync-oidc-clients` | Point the realm's confidential clients (`nova`, `superset`, `airflow`, `jupyterhub`; delegates `trino`) at Secret `stardelt-oidc-clients`; probe-first, idempotent, never prints a value (#85) |
| `verify-oidc-clients` | Prove every client secret still authenticates at the token endpoint (`invalid_grant` vs `unauthorized_client`) and matches what the realm stores; names the drifting clients and the fix |
| `sync-catalog-audience` | Add/repair the `aud-lakekeeper` mapper on `jupyterhub` and `stardelt-dev` (the control client `superset` must not carry it), prove it with Keycloak's evaluate call; idempotent, runs with `install-identity` (#317) |
| `sync-catalog-clients` | Create/converge the seven catalog-caller service clients (`svc-catalog-*`) and their Secrets, audience `lakekeeper`, no group; idempotent (#282, #303; Lakekeeper validates them since #285) |
| `delete-catalog-clients` | Delete those seven clients and Secrets; only `stardelt-managed=service` clients, needs `YES=1` |
| `access-sync` | Create/refresh ConfigMap `access-sync-script`, ensure ConfigMaps `trino-warehouses`/`trino-group-file` exist, and apply CronJob `access-sync` — one Lakekeeper warehouse per `Catalog`, its `owner`/`grants` on that warehouse, and one resource group plus group-file line per `SqlWarehouse` (platform#305, #306, #312) |
| `trino-warehouse-configmaps` | Create ConfigMaps `trino-warehouses` (key `resource-groups.json`) and `trino-group-file` (key `groups.txt`) when they are missing; the sync fills them and may never create them itself (platform#312) |
| `access-sync-now` | Run that CronJob once as a Job now, wait for it and print its log |
| `catalogs` | Converge every Ready `Catalog` into a Trino catalog and an OPA-bridge mapping; runs `access-sync-now`, upgrades Lakekeeper, then Trino (restarts Trino only when the set changed) (platform#308) |
| `seed-dev-access` | Create the dev seed: groups `finops`/`analytics`, users `dev-*`, Catalogs `warehouse`/`finance`/`product`/`sandbox` and the `seed.nation` tables; needs `YES=1`, refuses on `environment: production` (platform#309) |
| `unseed-dev-access` | Delete the seed users, groups and Catalogs and Secret `dev-seed-users`; needs `YES=1`, never touches `warehouse` or data (platform#309) |
| `verify-catalog-permissions` | Prove the nine-row permission matrix against the OPA bridge, one PASS/FAIL per cell; exit 1 on any mismatch (platform#309) |
| `bridge-capture` | Capture the authorization requests the Trino coordinator's image sends to an OPA authorizer, from a throwaway pod with a stub, into `scripts/tests/fixtures/trino-opa-requests.json`; refresh after a Trino upgrade (platform#333) |
| `bridge-replay` | Replay the captured requests against the live bridge for the three seed people and an admin: contract, probes, must-work reads and the matrix; exit 1 on an error, empty answer or wrong row. `--data-only` is the matrix gate (platform#333) |
| `bridge-latency` | `FilterCatalogs` with every catalog of the cluster plus system/tpch/tpcds, five cold runs per seed person and the admin: prints min/median/max and exits 1 above a 1.0 s median; asserts every answer equals the chart's per-catalog path (platform#359) |
| `catalog-enforce` | **The switch** (platform#311): Trino asks the bridge and the engine user becomes the Keycloak `sub`. Gated in order — `access-sync-now` (grants, group file and resource groups), `verify-catalog-permissions`, `bridge-replay --data-only`, Lakekeeper with `OPABridge.adminUsers`, `make trino` — and stops at the first failure. See [Who may read what](catalogs.md#who-may-read-what) |
| `catalog-enforce-rollback` | The recovery path: Trino on the file access control alone (`helm-values/trino-identity-file-only.yaml`), waiting for the rollout. It takes the bridge out of the authorization path and changes nothing else — the principal stays the Keycloak `sub` and the group file stays the one CronJob `access-sync` writes, so there is no window in which the two disagree. `deps` is a prerequisite, so a missing tool cannot stop it after it has started changing state. One command, for a failed cell of the switch's verification |
| `trino` | Install/upgrade Trino; adds `helm-values/trino-identity.yaml` (Keycloak OAuth2 + service-account password) when `stardelt-identity` exists. Ensures the two ConfigMaps and runs one `access-sync-now` before the upgrade (platform#312) |
| `install-operator` | Install the stardelt Operator from `../stardelt-operator/chart` (dev path) |
| `pin` | Pin a deployment to the newest published digest **and write it back into the manifest** (`make pin APP=nova`, `APP=spark DEPLOY=spark-connect`), so a later `kubectl apply` cannot put the mutable tag back |
| `pin-images` | Pin Nova, the operator and Spark to their digests (the install targets do this themselves) |
| `upgrade` | The upgrade path: converge the cluster to this release, move the image pins, run the schema migrations, converge the access-sync, then the verify targets. Safe to run twice |
| `platform` | **The one command that installs the platform** — twelve named steps, then it waits for every workload and prints what is running (see [Runbook](install.md#runbook)) |
| `platform-dry-run` | Show what `make platform` would do — the commands of every step, nothing written |
| `platform-idempotence` | The idempotence gate: snapshot every object of the platform, run the install again, compare — exits 1 when a resource version moved |
| `upgrade-idempotence` | The same gate for the upgrade path |
| `uninstall` | Remove all helm releases and manifests in reverse order |
| `chart-deps` | `helm dependency update chart` — fetch/refresh the umbrella chart's sub-charts |
| `chart-template` | Render the umbrella chart (`helm template stardelt chart -n <ns>`) |
| `chart-install` | Install/upgrade the umbrella chart as release `stardelt` (see [Helm chart](install.md#helm-chart-baseline)) |
| `build-superset-image` | Build `ghcr.io/stardelt/superset:dev` locally |
| `push-superset-image` | Push that image to ghcr.io |
| `build-jupyter-image` | Build `ghcr.io/stardelt/jupyter-singleuser:dev` locally |
| `push-jupyter-image` | Push that image to ghcr.io |
| `pf` | Open port-forwards to Nova, Trino, Lakekeeper, Superset |
| `dev-up` / `dev-down` | Create / delete the Hetzner k3s development cluster |
| `dev-dns` / `dev-dns-down` | Point / remove the playground DNS records |

---

# Repository layout

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
  openfga.yaml          OpenFGA permission store (catalog authz, not wired yet)
  seaweedfs.yaml        SeaweedFS S3-compatible storage
  superset.yaml         Apache Superset BI
  trino.yaml            Trino MPP SQL engine
  catalog.properties.tmpl  Catalog body for every extra `Catalog`, name templated (platform#308)
  slim/                 Small-node overrides (see `SLIM=1`)

manifests/            Plain Kubernetes manifests (kubectl apply)
  cnpg-postgres.yaml    CloudNative-PG Cluster for Lakekeeper metadata
  cnpg-backup-schedule.yaml  Daily base backups for lakekeeper-pg and openfga-pg
  pg-dump-backup.yaml   CronJobs: pg_dump of the Superset and Airflow databases (platform#366)
  openfga-pg.yaml       CloudNative-PG Cluster for the OpenFGA permission store
  openfga-network-policy.yaml  OpenFGA ingress: the Lakekeeper catalog and migration pods only
  keycloak.yaml         Platform IdP: Keycloak + its CNPG Cluster (make install-identity)
  lakekeeper-bootstrap.yaml  Job: accept ToS + create default warehouse
  lakekeeper-network-policy.yaml  Catalog ingress: the callers that may reach 8181 / the bridge
  access-sync.yaml      CronJob: one Lakekeeper warehouse per Catalog, its grants, and the
                        resource groups + group file of every SqlWarehouse, statuses written back
  nova-deployment.yaml  stardelt Nova UI + backend
  spark.yaml            Spark Connect endpoint + Spark configuration (make install-spark)
  s3-credentials.example.yaml  Template for the stardelt-s3-creds Secret

images/
  spark/Dockerfile      Spark 4.1.4 + Iceberg 1.12 runtime + AWS bundle
  superset/Dockerfile   Superset 5.0.0 + psycopg2 + trino driver
  jupyter/Dockerfile    scipy-notebook + trino, pyspark, pandas, pyarrow
  jupyter/notebooks/    warehouse-quickstart.ipynb (seeded into each user's home)

scripts/
  app-secrets.sh        Generate the Airflow/Superset Secrets (idempotent, never printed)
  access-sync-job.py    CronJob access-sync: Catalog objects become Lakekeeper warehouses
                        and grants (groups become roles, members assignees); SqlWarehouse
                        objects become resource groups and wh-<name> group-file lines
  platform.sh           The flow of `make platform` / `make upgrade`: the named steps,
                        the failure message, the wait, the report and the idempotence
                        gate (platform#422)
  check-deps.sh         Verify required CLI tools
  check-catalog-template.sh  Fail when catalog.properties.tmpl drifts from the `warehouse` block (platform#308)
  render-catalogs.sh    Ready Catalogs → Trino `--set-file`s and the bridge's `--set-json` (platform#308)
  identity-bootstrap.sh Generate the IdP Secrets + render realm/identity ConfigMaps
  keycloak-sync-trino-client.sh  Sync the live realm's Trino token settings (import skips an existing realm)
  lib/keycloak-admin.sh Shared Keycloak admin-API access (port-forward, forwarded headers, master token)
  seed-dev-access.sh    Dev seed: groups, people, Secret (baseline Catalogs only with SEED_CATALOGS=1); opt-in permission fixtures (platform#309, #365)
  lib/catalog-layout.py The permission oracle: expected grants from the live Catalog objects and Keycloak groups (platform#365)
  verify-catalog-permissions.sh  Prove the live Catalog grants against the OPA bridge (platform#309, #365)
  lint.sh               bash -n + ShellCheck the shell scripts (make lint)
  port-forwards.sh      Background port-forwards to all services
  protect-branches.sh   Apply `main` branch protection in all five stardelt repos
  superset-probe.py     Run `SELECT current_user` through Superset's own stored connection (verify-trino-auth 4/4)
  sync-realm-admin.sh   Re-apply Secret stardelt-realm-admin to the live realm's admin (import skips an existing realm)
  sync-realm-user-management.sh  Grant stardelt-admins the user-management roles + enforce brute force on the live realm
  sync-oidc-clients.sh  Re-apply Secret stardelt-oidc-clients to the live realm's clients (import skips an existing realm; trino delegated)
  verify-backups.sh     Backup guards: post-apply spec.backup assert + bucket-vs-database WAL check
  verify-pgdump.sh      Run a pg_dump CronJob, restore the newest dump into a scratch DB, compare table counts (platform#366)
  verify-notebook-identity.py  Headless hub login + run the quickstart in the pod (positive and 401 negative)
  verify-oidc-clients.sh Assert every client secret in Secret stardelt-oidc-clients authenticates at the token endpoint
  verify-realm-admin.sh Assert the realm-admin Secret still signs in to realm `stardelt`
  verify-trino-auth.sh  Assert Trino refuses anonymous SQL, accepts user tokens + the service account, and Superset's stored connection works
  tests/
    test_access_sync.py  Unit tests for access-sync-job.py (python3 -m unittest discover -s scripts/tests)
    fixtures/            The golden resource-groups.json the renderer is compared against (#312)
  helm-plugins/
    stardelt-dedupe/    Helm v4 post-renderer: deduplicates env lists
```

---

# Branch protection

`main` is protected in every stardelt repo (`stardelt-docs`, `stardelt-platform`, `stardelt-nova`,
`stardelt-operator`, `stardelt-demos`) by [`scripts/protect-branches.sh`](../scripts/protect-branches.sh)
(`bash scripts/protect-branches.sh`, `--dry-run` to preview). Each repo requires the CI job names its
pull requests report — validated against checks actually seen on recent PRs, because a wrong name would
silently block every merge — plus no force pushes, no deletions and linear history. Pull requests are
required but no approvals: the maintainer and AI agents merge under one owner account, so CI is the gate;
`enforce_admins` stays off for emergencies. Re-run it after a workflow job name changes.
Collaboration/release branches are planned later (issue #38).

---

# Component versions

| Component | Chart version | App version |
|-----------|--------------|-------------|
| CloudNative-PG | 0.29.1 | 1.30.1 |
| SeaweedFS | 4.25.1 | 4.25 |
| Lakekeeper | 0.11.0 | 0.12.2 |
| OpenFGA | 0.4.1 | v1.22.1 |
| Trino | 1.45.0 | 484 |
| Apache Airflow | 1.22.0 | 3.2.2 |
| Apache Superset | 0.15.5 | 5.0.0 |
| Apache Spark (image, no chart) | — | 4.1.4 (Iceberg 1.12.0) |
| Keycloak (image, no chart) | — | 26.8.2 |

---

# Version pins

Chart and application versions are pinned in the root [`Makefile`](../Makefile) — one
`<COMPONENT>_VERSION := x.y.z` line per chart. Every Makefile install path
(`make install`, `make install-core`) reads the pin from there, so that file is the
source of truth for what gets deployed and a version bump is a one-line change.

The umbrella chart needs the same numbers again as literal `dependencies[].version`
entries in [`chart/Chart.yaml`](../chart/Chart.yaml) (Helm cannot read a Make variable).
Renovate reads that file natively and the `helm charts` group below covers it, so a
bump normally arrives as one PR touching both files.

Dependencies are kept current by [Renovate](https://docs.renovatebot.com/), configured in
[`renovate.json`](../renovate.json). It opens grouped pull requests for:

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

One pin Renovate does not own: `ICEBERG_VERSION` in `images/spark/Dockerfile`. The Iceberg
runtime is matched to the Spark minor (`iceberg-spark-runtime-4.1_2.13`), so a Spark
major/minor bump is a deliberate edit of the base image and the runtime together.

---

# Configuration

## Overriding helm values

The simplest approach is to add a second values file and pass it at the end (later files win):

```sh
# Create an override file
cp helm-values/trino.yaml my-trino-overrides.yaml
# Edit as needed, then:
helm upgrade --install trino trino/trino \
  --version 1.45.0 \
  --namespace stardelt \
  -f helm-values/trino.yaml \
  -f my-trino-overrides.yaml
```

For persistent overrides, modify the files in `helm-values/` directly and commit them.

## Nova image

`manifests/nova-deployment.yaml` uses `ghcr.io/stardelt/nova:dev` with
`imagePullPolicy: Always`, and pulls through the `ghcr-creds` secret.

## Superset image

The Superset image adds `psycopg2-binary` and the `trino` SQLAlchemy driver to the
upstream Superset 5.0.0 base. **CI builds it** — the `Image` workflow in this repo
publishes `ghcr.io/stardelt/superset:dev` (plus `sha-<short>`) on merge to `main`, and
`helm-values/superset.yaml` points at it with the `ghcr-creds` pull secret. A local
`make build-superset-image` + `make push-superset-image` is only for iteration.

## Jupyter single-user image

`images/jupyter/Dockerfile` adds `trino`, `pyspark[connect]`, `pandas` and `pyarrow` to
`quay.io/jupyter/scipy-notebook` and ships `warehouse-quickstart.ipynb`. It also installs
the **pinned release** of the notebook helper (`stardelt/stardelt-python`): the pin lives in
the `Makefile` (`STARDELT_LIB_REF`, the commit; `STARDELT_LIB_TAG`, the release) and the
Dockerfile installs it as a build arg — `scripts/check-stardelt-pin.sh`, run by `make lint`,
fails the build when the two disagree or when the pin is not a full commit SHA. Same workflow:
CI publishes `ghcr.io/stardelt/jupyter-singleuser:dev` on merge to `main`, and
`helm-values/jupyterhub.yaml` points `singleuser.image` at it with the `ghcr-creds`
pull secret; `make build-jupyter-image` + `make push-jupyter-image` are for local
iteration. It never carries credentials — the user's token is copied into the pod at
spawn (see [Notebooks](identity.md#notebooks-the-users-own-identity-inside-the-pod)).

The same digest is pinned two more times — as `PIPELINE_NOTEBOOK_IMAGE` in
`helm-values/airflow.yaml`, because a notebook task runs in a pod of its own on this
image (see [Notebook tasks](notebooks.md#notebook-tasks)), and as `jupyterhub.singleuser.image.tag`
in `chart/values.yaml`, because the umbrella chart spawns single-user pods too:
`WRITE_MANIFEST_ONLY=1 ./scripts/pin-image.sh jupyter` moves all three pins and needs no
cluster, and `scripts/check-notebook-image-pin.sh` — run by `make lint` and therefore by
CI — fails with the three digests when they differ.

---

# Container images

stardelt images live under `ghcr.io/stardelt/*` and are built by CI, not by the
cluster: merge to `main` publishes `dev` and an immutable `sha-<short>` tag, and the
job summary prints the digest. **Pin deployments by digest** — a moving tag may keep
serving a cached layer.

`nova` is public; `operator`, `superset`, `jupyter-singleuser` and `spark` are internal/private until
someone flips them in the package settings (the API refuses), so the cluster needs a pull
secret named `ghcr-creds` in the namespace:

```sh
./dev/ghcr-pull-secret.sh          # uses your `gh auth token`
GHCR_TOKEN=<read:packages PAT> ./dev/ghcr-pull-secret.sh   # preferred
```

The secret lives in the cluster, so give it a token that can only read packages
(`GHCR_TOKEN`) rather than your full `gh` login token. It acts on the current kube-context
(or `KUBE_CONTEXT`) and prints it first.

Alternatively, make the packages public in the GitHub package settings and drop the
`imagePullSecrets` entry. `nova:dev` is a mutable tag — pin by digest for reproducible installs.
