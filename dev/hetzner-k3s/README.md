# Hetzner k3s — development cluster

A cheap single-node dev cluster on Hetzner Cloud, created with
[hetzner-k3s](https://github.com/vitobotta/hetzner-k3s). The full chart set does not fit on a
laptop, so the product deploys here.

## What you get

- One node (default **`cx33`**, 4 vCPU / 8 GB, **~€10/month**) with **one master**; workloads
  are scheduled on it (`schedule_workloads_on_masters: true`).
- A private network, firewall (SSH/API restricted to your IP; 80/443 open), Hetzner CCM + CSI
  driver, system-upgrade-controller and metrics-server.
- **No load balancer** (`create_load_balancer_for_the_kubernetes_api: false`) and **no
  bundled ingress** — ingress comes from
  [dev/playground](../playground) (ingress-nginx, host-network), so there is no LB cost.
- A kubeconfig at `~/.kube/stardelt-dev.yaml`.
- Playground DNS (A + wildcard A) for `$INGRESS_HOST`, when Cloudflare credentials exist.

## Prerequisites

| Thing | Where |
|---|---|
| `hetzner-k3s` | <https://github.com/vitobotta/hetzner-k3s> |
| Hetzner API token | `~/.config/stardelt/hetzner.env` (`HCLOUD_TOKEN=…`) or `dev/hetzner-k3s/.env` |
| SSH keypair | `~/.ssh/id_ed25519{,.pub}` (no passphrase) |
| Cloudflare creds (optional) | `~/.config/stardelt/cloudflare.env` |
| `kubectl`, `helm` | `dev/install-tools.sh` |

## Bring it up

```sh
set -a; . ~/.config/stardelt/hetzner.env; set +a
make dev-up                 # renders cluster.yaml, creates the cluster, points DNS
export KUBECONFIG="$HOME/.kube/stardelt-dev.yaml"
kubectl get nodes
```

`provision.sh` writes `dev/hetzner-k3s/cluster.yaml` (gitignored, mode 600) from the settings
below and runs `hetzner-k3s create`. Re-running is safe (hetzner-k3s is idempotent).

## Deploy stardelt

```sh
make install-core SLIM=1    # core: storage + catalog + query + Nova (fits cx33)
# or, on a 16 GB node (NODE_TYPE=cx43):
make install                # full: + Airflow + Superset
```

Then set up ingress + TLS from [dev/playground](../playground).

## Configure

| Var | Default | Meaning |
|---|---|---|
| `CLUSTER_NAME` | `stardelt-dev` | cluster name |
| `K3S_VERSION` | `v1.37.1+k3s1` | see `hetzner-k3s releases` |
| `NODE_TYPE` | `cx33` | 4 vCPU / 8 GB (~€10/mo); `cx43` = 16 GB (~€19/mo) |
| `LOCATION` | `nbg1` | `nbg1` \| `fsn1` \| `hel1` \| `ash` \| `hil` |
| `INGRESS_HOST` | `alpha.dev.stardelt.io` | playground hostname |
| `ALLOW_IPV4` / `ALLOW_IPV6` | your current public IPs | SSH + API allowlist |

Reference config: [`cluster.yaml.example`](./cluster.yaml.example).

## Tear down

```sh
make dev-down        # hetzner-k3s delete + remove DNS records
```

## Notes

- Single node, no HA — a development environment, not production.
- **Do not put real data here.**
- The build-plane AI fleet runs on the maintainer's laptop, not here. See
  [AI development fleet](../../../stardelt-docs/docs/developer/ai-fleet).
