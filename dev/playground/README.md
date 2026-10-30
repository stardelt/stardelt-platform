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

Request bodies through Nova are limited to 2 MiB (the Nova Ingress annotation
`nginx.ingress.kubernetes.io/proxy-body-size`, matching what Nova itself enforces;
oversize bodies get a clean 413, not a 502).

## 5. Tell Nova where it is (already done by the install)

Nova builds every app deep-link **and both embedded apps — Dashboards (Superset) and Notebooks
(JupyterHub)** — from `NOVA_BASE_DOMAIN`. `make install` and `make install-core` converge it
through the `platform-config` target:

```sh
make platform-config                     # BASE_DOMAIN=... to override, default alpha.dev.stardelt.io
```

The value lives in ConfigMap `stardelt-platform-config`, not inline, so re-applying
`manifests/nova-deployment.yaml` cannot wipe it. Set it by hand only on a bare manifest install:

```sh
kubectl -n stardelt create configmap stardelt-platform-config \
  --from-literal=baseDomain="${INGRESS_HOST:-alpha.dev.stardelt.io}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n stardelt rollout restart deploy/nova
```

Without it Nova still reports live status, but the app links are empty and the two embedded pages
show an empty state — which looks like "Dashboards and Notebooks are not set up" even when
Superset and JupyterHub are healthy. The umbrella chart passes `platform.baseDomain` to Nova
directly and does not need the ConfigMap.

## 6. Platform IdP (optional)

```sh
make install-identity BASE_DOMAIN="${INGRESS_HOST:-alpha.dev.stardelt.io}"
```

Keycloak comes up at **https://id.alpha.dev.stardelt.io** (the `keycloak` Ingress in
`ingress.yaml`; re-apply it if you applied the file before this step existed). It adds about
640 MiB of memory requests. Sign in to realm `stardelt` as `admin`; the password is in a Secret
and is never printed by the install:

```sh
kubectl -n stardelt get secret stardelt-realm-admin -o jsonpath='{.data.password}' | base64 -d
```

The Ingress publishes only what a browser needs for that sign-in: `/realms/stardelt`
(sign-in, token and account endpoints), `/resources` (the theme's static assets) and
`/robots.txt` — plus, for platform admins, the realm's admin console and its REST API:
`/admin/stardelt/...` and `/admin/realms/stardelt/...`. Those two are segment-exact
ingress-nginx regexes (`(/|$)`), so the master realm (`/admin/master/console/`,
`/realms/master`, `/admin/realms/master/...`) is **not** on the public host and returns
ingress-nginx's default 404 — it controls every other realm. Open the console at:

```text
https://id.alpha.dev.stardelt.io/admin/stardelt/console/
```

Nova links there from **Users** (Platform group, admins only), and the group
`stardelt-admins` carries the `realm-management` roles the Users page needs. On a live
realm those roles and the realm's brute-force protection are applied by
`make sync-realm-user-management`; the umbrella chart publishes the same narrow paths
(`chart/templates/ingress.yaml`).

## 7. Notebooks (optional)

```sh
make install-notebooks
```

JupyterHub signs in through Keycloak (`helm-values/jupyterhub.yaml`): client `jupyterhub`,
group `stardelt-admins` for sign-in and for Hub admin. It reads the issuer from ConfigMap
`stardelt-identity` and the client secret from Secret `stardelt-oidc-clients` (key
`jupyterhub`), so §6 must have run first — there is no password in the values file and
`/hub/login` only offers "Sign in with Keycloak".

## Tear down

```sh
make dev-dns-down      # remove the A + wildcard records
make dev-down          # delete the cluster
```

## Cost

`cx33` (4 vCPU / 8 GB) is about **€10/month** and comfortably runs the *core* stack
(`install-core SLIM=1`). The full stack (+ Airflow + Superset) wants `NODE_TYPE=cx43`
(16 GB, ~€19/month). Hetzner bills while the server exists — `make dev-down` when idle.
