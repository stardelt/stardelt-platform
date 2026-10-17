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

The default `stardelt-s3-creds` Secret holds the dev credentials that match the
SeaweedFS sub-chart (as `make install-core` does). For a real install override
`s3Credentials.accessKey` / `secretKey`, or set `s3Credentials.create=false` and
create the Secret yourself from `manifests/s3-credentials.example.yaml`.

---

## Makefile targets

| Target | Description |
|--------|-------------|
| `help` | List all targets with descriptions |
| `deps` | Run `scripts/check-deps.sh` to verify CLI tools |
| `lint` | `bash -n` + ShellCheck every script under `scripts/` and `dev/` (ShellCheck only if installed) |
| `install` | Add helm repos, deploy the full stack (9 steps) |
| `install-core` | Core only (storage + catalog + query + Nova) — fits a small node; `SLIM=1` for 8 GB |
| `install-notebooks` | JupyterHub (notebooks) |
| `install-operator` | Install the stardelt Operator from `../stardelt-operator/chart` (dev path) |
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
  templates/            Nova, CNPG Cluster, S3 Secret, Lakekeeper bootstrap Job
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
  lakekeeper-bootstrap.yaml  Job: accept ToS + create default warehouse
  nova-deployment.yaml  stardelt Nova UI + backend
  s3-credentials.example.yaml  Template for the stardelt-s3-creds Secret

images/
  superset/Dockerfile   Superset 5.0.0 + psycopg2 + trino driver

scripts/
  check-deps.sh         Verify required CLI tools
  lint.sh               bash -n + ShellCheck the shell scripts (make lint)
  port-forwards.sh      Background port-forwards to all services
  helm-plugins/
    stardelt-dedupe/    Helm v4 post-renderer: deduplicates env lists
```

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

`manifests/nova-deployment.yaml` defaults to `stardelt/nova:dev` (produced by the
stardelt-demos local build). In production, override the image reference to:

```yaml
image: ghcr.io/stardelt/nova:latest
```

### Superset image

The Superset image adds `psycopg2-binary` and the `trino` SQLAlchemy driver to the
upstream Superset 5.0.0 base. Build and push it once before installing:

```sh
make build-superset-image
make push-superset-image
```

The chart's `image.repository` in `helm-values/superset.yaml` already points to
`stardelt/superset:dev`. Update to `ghcr.io/stardelt/superset:dev` (or a versioned tag)
for production deployments.

---

## Container images

stardelt images live under `ghcr.io/stardelt/*` (e.g. `ghcr.io/stardelt/nova:dev`). The GHCR
packages are private, so the cluster needs a pull secret named `ghcr-creds` in the namespace:

```sh
./dev/ghcr-pull-secret.sh          # requires gh with write:packages
```

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
