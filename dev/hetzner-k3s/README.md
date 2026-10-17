# Hetzner k3s — development environment

A real single-node k3s cluster on Hetzner Cloud, used as the **primary dev environment**
because the full chart set (Airflow, Superset, Trino, SeaweedFS, Lakekeeper, …) does not fit
comfortably on a laptop. `kind` remains a fallback for Nova-only work.

Cost note: `cx32` (4 vCPU / 8 GB) is about **€7/month**. Bump to `cx42` (8 vCPU / 16 GB,
~€16/month) if Airflow or Superset get `OOMKilled`. Hetzner bills while the server exists, so
`make dev-down` when idle.

## What this gives you

- One Hetzner Cloud VM (Ubuntu 24.04) running **k3s** (Traefik ingress, ServiceLB, local-path storage).
- A firewall allowing SSH + Kubernetes API **only from your current public IP**, plus 80/443.
- A standalone kubeconfig at `~/.kube/stardelt-dev.yaml`.
- Everything is disposable: `./destroy.sh` removes the server; nothing else is touched.

## Prerequisites

- A Hetzner Cloud **API token** (`HCLOUD_TOKEN`) with read/write scope.
- `hcloud` CLI — <https://github.com/hetznercloud/cli#installation>
- An SSH key: defaults to `~/.ssh/id_ed25519.pub`.
- `kubectl` (already installed by `stardelt-platform/agents/scripts/install-tools.sh`).

## Bring it up

```sh
cd stardelt-platform/dev/hetzner-k3s
cp .env.example .env          # fill HCLOUD_TOKEN (and optionally TYPE/LOCATION)
set -a; . ./.env; set +a

./provision.sh                # ~60–90 s: server + firewall + k3s
export KUBECONFIG="$HOME/.kube/stardelt-dev.yaml"
kubectl get nodes             # one Ready node
```

Then deploy the platform against it:

```sh
cd ../..                      # stardelt-platform
make install
```

## Configure

All via env vars (see `.env.example`):

| Var | Default | Meaning |
|---|---|---|
| `HCLOUD_TOKEN` | — | required API token |
| `NAME` | `stardelt-dev` | server + firewall + key name |
| `TYPE` | `cx32` | server type (4 vCPU / 8 GB, ~€7/mo) |
| `LOCATION` | `nbg1` | `nbg1`, `fsn1`, `hel1`, `ash`, `hil` |
| `IMAGE` | `ubuntu-24.04` | base image |
| `ALLOW_CIDR` | your current IP `/32` | who may reach SSH + 6443 |
| `SSH_PUBKEY` | `~/.ssh/id_ed25519.pub` | key uploaded to Hetzner |
| `INGRESS_HOST` | `alpha.dev.stardelt.io` | playground hostname (A + wildcard A) |

## Playground DNS

If `~/.config/stardelt/cloudflare.env` exists, `provision.sh` points
`$INGRESS_HOST` and `*.$INGRESS_HOST` at the node automatically. Manage it by hand:

```sh
make dev-dns        # upsert A + wildcard A → node IP
make dev-dns-down   # remove them
```

See [dev/playground](../playground) for the ingress + TLS setup.

## Tear it down

```sh
./destroy.sh            # deletes the server (firewall + key are kept for reuse)
```

## Notes / limitations (deliberately simple)

- **Single node, no HA.** This is a dev environment, not the demo stage or production.
- **local-path storage.** Fine for dev. Add the Hetzner CSI driver later if you need real volumes.
- **No cloud controller manager.** The node is one server; ServiceLB handles `LoadBalancer` services.
- **Do not put real data here.** See [sovereignty](../../../stardelt-docs/docs/architecture/sovereignty).
