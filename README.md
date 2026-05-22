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

## Makefile targets

| Target | Description |
|--------|-------------|
| `help` | List all targets with descriptions |
| `deps` | Run `scripts/check-deps.sh` to verify CLI tools |
| `install` | Add helm repos, install the dedupe plugin, deploy all components |
| `upgrade` | Re-run `install` (helm upgrade is idempotent) |
| `uninstall` | Remove all helm releases and manifests in reverse order |
| `build-superset-image` | Build `ghcr.io/stardelt/superset:dev` locally |
| `push-superset-image` | Push that image to ghcr.io |
| `pf` | Open port-forwards to Nova, Trino, Lakekeeper, Superset |

---

## Repository layout

```
helm-values/          Helm values files, one per chart
  airflow.yaml          Apache Airflow 3.x (KubernetesExecutor)
  lakekeeper.yaml       Lakekeeper Iceberg REST catalog
  seaweedfs.yaml        SeaweedFS S3-compatible storage
  superset.yaml         Apache Superset BI
  trino.yaml            Trino MPP SQL engine

manifests/            Plain Kubernetes manifests (kubectl apply)
  cnpg-postgres.yaml    CloudNative-PG Cluster for Lakekeeper metadata
  lakekeeper-bootstrap.yaml  Job: accept ToS + create default warehouse
  nova-deployment.yaml  stardelt Nova UI + backend
  s3-credentials.example.yaml  Template for the stardelt-s3-creds Secret

images/
  superset/Dockerfile   Superset 5.0.0 + psycopg2 + trino driver

scripts/
  check-deps.sh         Verify required CLI tools
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

## Uninstalling

```sh
make uninstall
```

This removes helm releases in reverse dependency order and deletes the manifests. PVCs
are intentionally left in place; delete them manually if you want to reclaim storage:

```sh
kubectl delete pvc --all -n stardelt
```
