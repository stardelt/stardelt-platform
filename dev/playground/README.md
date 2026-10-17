# Playground

A throwaway, publicly reachable stage so you can show the current dev state:

- **https://alpha.dev.stardelt.io** → stardelt Nova
- `*.alpha.dev.stardelt.io` → ingress, for the other service UIs

Ingress is **ingress-nginx** running host-network (binds :80/:443 on the node). We do **not**
use a Hetzner load balancer, so there is no extra LB cost. DNS is managed by
`dev/cloudflare-dns.sh`.

## 1. Cluster + DNS

```sh
set -a; . ~/.config/stardelt/hetzner.env; set +a    # HCLOUD_TOKEN
make dev-up                                          # hetzner-k3s + DNS
export KUBECONFIG="$HOME/.kube/stardelt-dev.yaml"
```

## 2. Core platform (fits the cheap node)

```sh
make install-core SLIM=1
```

## 3. Ingress

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f dev/playground/ingress-nginx-values.yaml --wait
```

## 4. TLS certificates

```sh
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait
kubectl apply -f dev/playground/clusterissuer.yaml
kubectl apply -f dev/playground/ingress.yaml
```

Port 80 is open (firewall + ACME HTTP-01). Certificates are issued within a minute or two;
then open **https://alpha.dev.stardelt.io**.

## Tear down

```sh
make dev-dns-down      # remove the A + wildcard records
make dev-down          # delete the cluster
```

## Cost

`cx33` (4 vCPU / 8 GB) is about **€10/month** and comfortably runs the *core* stack
(`install-core SLIM=1`). The full stack (+ Airflow + Superset) wants `NODE_TYPE=cx43`
(16 GB, ~€19/month). Hetzner bills while the server exists — `make dev-down` when idle.
