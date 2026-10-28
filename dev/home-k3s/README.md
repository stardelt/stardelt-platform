# Home k3s — running the dev cluster on your own single node

The Hetzner dev cluster (`dev/hetzner-k3s`) is optional. The same platform runs on one
machine you already own, reached through your router, with the same hostnames — so nothing
in `helm-values/`, the Keycloak realm or Nova's deep-links changes.

This directory is the **generic** path: host names, addresses and the DDNS name are
inputs, not defaults. Keep your own values in a shell file outside the repository (see
§5) — the public repo stays free of maintainer infrastructure.

| Piece | Value in this guide |
|---|---|
| Host | any Debian/Ubuntu machine with 8 vCPU / 16 GiB RAM / ≥100 GB disk |
| Cluster | k3s, single node, **no HA** |
| Ingress | ingress-nginx host-network on `:443` (same chart values as `dev/playground`) |
| TLS | Let's Encrypt via **DNS-01** (Cloudflare), so no inbound port 80 |
| Reachability | one router port forward, and a DDNS name |

**Single node, no irreplaceable data.** It is a development stage: rebuild it from this
repository and `ghcr.io/stardelt/*` whenever it stops being useful.

---

## 1. Router — once

1. Give the host a **fixed DHCP lease**; the forward and the k3s node IP follow that
   address, and so does everything the cluster publishes.
2. Forward **TCP 443** to the host. Port 80 is *not* required: certificates use DNS-01.
   If port 80 is already taken on your line by another service, that is the expected
   case, not a problem.
3. DNS: point the platform's records at the router's **DDNS name** (not at an address),
   so a changing public IP needs no work. Cloudflare:

   ```sh
   set -a; . ~/.config/stardelt/cloudflare.env; set +a
   TYPE=CNAME TARGET=<router-ddns-name> NAME=<base-domain> \
     ./dev/cloudflare-dns.sh upsert
   ```

   That writes `<base-domain>` and `*.<base-domain>` and removes an A record of the same
   name if one exists (Cloudflare refuses a CNAME next to an A).

   Check: `dig +short id.<base-domain>` must end in your public IPv4. If your line is
   behind CGNAT/DS-Lite, no forward will work — test from outside, not from the host.

## 2. Host + k3s — once, needs root

```sh
sudo bash dev/home-k3s/install-k3s.sh
# optional: extra SANs for the API certificate (comma separated)
sudo EXTRA_TLS_SANS=<base-domain>,<lan-ip> bash dev/home-k3s/install-k3s.sh
```

Idempotent; re-running installs the same version with the same flags. It disables swap,
sets the k8s sysctls, installs k3s (`traefik` and `servicelb` off — ingress-nginx is
host-network and would otherwise fight them for `:80`/`:443`), and installs `kubectl`,
`helm` and `gh` into `/usr/local/bin`. It writes `~/.kube/config` and
`~/.kube/stardelt-dev.yaml` for the login user with context `stardelt-dev`, so
`EXPECT_CONTEXT=stardelt-dev` matches the Makefile guard.

## 3. Ingress and certificates

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f dev/playground/ingress-nginx-values.yaml --wait

helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait

# the token needs Zone → DNS → Edit on the zone, and nothing else
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN"
kubectl apply -f dev/home-k3s/clusterissuer-cloudflare.yaml
```

`clusterissuer-cloudflare.yaml` is the DNS-01 variant of
`dev/playground/clusterissuer.yaml` and keeps the name `letsencrypt-prod`, so the
playground Ingresses need no edit. Set the ACME address in it before applying.

## 4. The platform

Start with the core, then the IdP (the Ingresses need it for the browser flows):

```sh
export KUBECONFIG="$HOME/.kube/config"
cd stardelt-platform

EXPECT_CONTEXT=stardelt-dev make install-core SLIM=1
EXPECT_CONTEXT=stardelt-dev make install-identity BASE_DOMAIN=<base-domain>

kubectl apply -f dev/playground/ingress.yaml
kubectl -n stardelt create configmap stardelt-platform-config \
  --from-literal=baseDomain=<base-domain> \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n stardelt rollout restart deploy/nova
```

`dev/playground/ingress.yaml` carries `alpha.dev.stardelt.io` as the example host; with
a different base domain render it first:

```sh
sed "s/alpha\.dev\.stardelt\.io/${BASE_DOMAIN//./\\.}/g" dev/playground/ingress.yaml \
  | kubectl apply -f -
```

Then, as on Hetzner: `make install-notebooks`, `make install-spark`, and for the full
stack `make install` (adds Airflow + Superset). On a 16 GiB node the full stack fits;
`make node-budget` is the read-only check.

## 5. Your own values, outside the repository

The inputs are environment variables, so no hostname or address needs to be committed:

```sh
# ~/.config/stardelt/home-cluster.env   (mode 600)
export BASE_DOMAIN=alpha.example.dev
export INGRESS_HOST="$BASE_DOMAIN"
export ROUTER_DDNS=xxxxx.example-router.net
export CLOUDFLARE_API_TOKEN=…
```

## 6. Notes and limits

- **Memory is the ceiling, not CPU.** Trino's two pods request ~1.8 GiB each in the slim
  profile; Airflow and Superset are the next biggest. Raise a request only with a
  measured peak.
- **Storage is the host disk** (`local-path`): SeaweedFS data, Postgres volumes,
  JupyterHub homes and Trino spill live under `/var/lib/rancher/k3s/storage` and are lost
  with the host. Backups go to `s3://backups/…` on the same SeaweedFS — not an off-site
  copy. Configure `Secret backup-offsite` if that matters.
- **No cloud controller, no load balancer, no firewall allowlist.** Reachability is the
  router's. Do not forward `6443` (the cluster API); reach it over a private network
  (Tailscale, WireGuard, SSH tunnel) or from the LAN.
- **Tear down**: `sudo /usr/local/bin/k3s-uninstall.sh` — then delete the DNS records
  with `dev/cloudflare-dns.sh delete` and the host's `/var/lib/rancher/k3s` if you want
  the disk back.

## Why not a private network only?

Binding the ingress to a VPN address and pointing DNS at it works for one person and puts
nothing on the internet, but Let's Encrypt cannot validate a private address over
HTTP-01 (and DNS-01 for a public zone that resolves to a private address is a foot-gun).
The platform's identity wiring wants a publicly trusted certificate: the Keycloak issuer,
the JWKS fetches from inside Trino and Nova, and JupyterHub's `SameSite=None` cookies.
One port forward plus DNS-01 gives that without exposing the cluster API.
