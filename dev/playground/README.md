# Playground

A throwaway, publicly reachable stage so you can show the current dev state:

- **https://alpha.dev.stardelt.io** → stardelt Nova
- `*.alpha.dev.stardelt.io` → Traefik ingress, for the other service UIs

DNS is managed by `dev/cloudflare-dns.sh` (called automatically by `provision.sh`,
or explicitly via `make dev-dns`). k3s ships Traefik, so the ingress controller is
already present.

## 1. Cluster + DNS

```sh
cp dev/hetzner-k3s/.env.example dev/hetzner-k3s/.env   # HCLOUD_TOKEN, TYPE=cx32
set -a; . dev/hetzner-k3s/.env; set +a
make dev-up          # provisions k3s and points the DNS records at it
export KUBECONFIG="$HOME/.kube/stardelt-dev.yaml"
```

## 2. Platform

```sh
make install
```

## 3. TLS certificates

k3s does not ship cert-manager. Install it once:

```sh
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait
kubectl apply -f dev/playground/clusterissuer.yaml
```

HTTP-01 needs port 80 reachable, which the firewall already allows.

## 4. Ingress

```sh
kubectl apply -f dev/playground/ingress.yaml
kubectl -n stardelt get ingress
```

Certificates are issued within a minute or two; then open
**https://alpha.dev.stardelt.io**.

## Tear down DNS

```sh
make dev-dns-down      # removes the A + wildcard A records
make dev-down          # deletes the server
```

## Cost

`cx32` (4 vCPU / 8 GB) is about **€7/month**. If Airflow or Superset get
`OOMKilled`, bump `TYPE=cx42` (16 GB, ~€16/month). Hetzner bills while the server
exists, so `make dev-down` when you are done showing it.
