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

## Internet access (ingress + SSO)

Expose the UIs on per-service subdomains behind GitHub SSO. **Not used by the
kind laptop demo.**

Config is layered **prod-default / lab-override**: a bare `make ingress` targets
**prod** (`cloud.stardelt.io`, committed defaults in `environments/prod.env`).
The Hetzner dev cluster is an explicit opt-in via `STARDELT_ENV=lab`, which
sources `environments/lab.env` (`lab.stardelt.io`, DNS re-sync on). Edit
`environments/lab.env` freely; leave `environments/prod.env` stable.

### One-time per cluster

1. Choose the environment for the session (prod is the default):
   ```sh
   export STARDELT_ENV=lab        # omit / set prod for the production cluster
   ```
2. Create a **GitHub OAuth App** in the `stardelt` org (one per environment —
   lab and prod need different callback URLs). With `STARDELT_ENV=lab` the domain
   is `lab.stardelt.io`:
   - Homepage URL: `https://nova.lab.stardelt.io`
   - Callback URL: `https://auth.lab.stardelt.io/oauth2/callback`
3. Apply the two secrets (copy the templates, fill them in):
   ```sh
   cp manifests/cloudflare-api-token.example.yaml manifests/cloudflare-api-token.yaml
   cp manifests/oauth2-proxy-creds.example.yaml    manifests/oauth2-proxy-creds.yaml
   # edit both: Cloudflare DNS:Edit token; GitHub client id/secret;
   #   cookie-secret via: openssl rand -base64 32
   kubectl apply -f manifests/cloudflare-api-token.yaml
   kubectl apply -f manifests/oauth2-proxy-creds.yaml
   ```
4. Install the ingress stack:
   ```sh
   STARDELT_ENV=lab make ingress      # prod: just `make ingress`
   ```

### Hosts (lab)

| URL | Service |
|---|---|
| `https://nova.lab.stardelt.io` | Nova UI + API gateway |
| `https://superset.lab.stardelt.io` | Superset BI |
| `https://airflow.lab.stardelt.io` | Airflow |
| `https://trino.lab.stardelt.io` | Trino UI |
| `https://auth.lab.stardelt.io` | oauth2-proxy (login/callback) |

In prod the same hosts live under `cloud.stardelt.io`. All hosts except `auth`
require a GitHub login as a `stardelt` org member.

### After recreating the ephemeral lab cluster

The master gets a new public IP, so re-point DNS (one command). Prod never needs
this — its IP is static.
```sh
STARDELT_ENV=lab make dns-sync     # if ingress is already installed
# or: STARDELT_ENV=lab make ingress # full (re)install — also re-points DNS
kubectl get certificate -n stardelt   # wait for stardelt-wildcard → Ready
```

### Verify

```sh
curl -sI https://trino.lab.stardelt.io | head -1     # → 302 (redirect to GitHub) when logged out
kubectl get certificate -n stardelt                  # stardelt-wildcard READY=True
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
| `ingress` | Install ingress stack (cert-manager + oauth2-proxy + routes); `STARDELT_ENV=prod\|lab` |
| `dns-sync` | Re-point the wildcard A-record at the current master IP (lab) |
| `uninstall-ingress` | Remove the ingress stack (keeps cert-manager CRDs) |

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
