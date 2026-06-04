# Ingress, Domain Routing & GitHub SSO — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Nova, Superset, Airflow, and Trino on per-service subdomains of `${STARDELT_DOMAIN}`, fronted by k3s Traefik with a cert-manager DNS-01 wildcard TLS cert and a single GitHub-org-restricted oauth2-proxy sign-in.

**Architecture:** All work lives in `stardelt-platform`. Services stay `ClusterIP`; we add cert-manager (Helm), oauth2-proxy (Helm), a Traefik forward-auth `Middleware`, and host-routed `Ingress` objects rendered from token files (`__STARDELT_DOMAIN__`, `__STARDELT_ACME_SERVER__`) via `sed` in a new `make ingress` target. Config is layered **prod-default / lab-override**: `STARDELT_ENV` defaults to `prod`, and the Makefile sources `environments/<env>.env` for the domain, ACME server, and a `STARDELT_DNS_SYNC` flag. In lab, `scripts/dns-sync.sh` keeps a single Cloudflare wildcard A-record pointed at the ephemeral master IP; in prod that step is skipped. Verification is by `kubectl`/`curl`, not unit tests — this is declarative infra.

**Tech Stack:** Kubernetes, k3s Traefik, cert-manager (ACME DNS-01 / Cloudflare), oauth2-proxy (GitHub provider), Helm, `envsubst`, `curl`, Cloudflare API, hetzner-k3s.

---

## Spec

Design spec: `docs/superpowers/specs/2026-06-04-ingress-routing-sso-design.md`. Read it first.

## Conventions used throughout

- **Namespace:** `stardelt` (matches `NAMESPACE ?= stardelt` in `Makefile`).
- **Env layering:** `STARDELT_ENV` defaults to `prod`. The Makefile sources `environments/$(STARDELT_ENV).env`, which sets `STARDELT_DOMAIN`, `STARDELT_ACME_SERVER`, and `STARDELT_DNS_SYNC`. Prod runs on committed defaults; `lab` is the edited override. `STARDELT_ENV=lab make ingress` targets the dev cluster.
- **Domain variable:** `STARDELT_DOMAIN` (prod `cloud.stardelt.io`, lab `lab.stardelt.io`). Every host is `<svc>.${STARDELT_DOMAIN}`.
- **Template tokens:** literal strings `__STARDELT_DOMAIN__` and `__STARDELT_ACME_SERVER__` inside `manifests/ingress/*.yaml`, substituted at apply time. Do **not** use Helm/Kustomize.
- **In-cluster backends (verified against the existing values files):**
  | Host | Service | Port |
  |---|---|---|
  | `nova` | `nova` | 8080 |
  | `superset` | `superset` | 8088 |
  | `airflow` | `airflow-api-server` | 8080 |
  | `trino` | `trino` | 8080 |
  | `auth` | `oauth2-proxy` | 4180 |
- **Pinned chart versions** go in **both** `stardelt-platform/Makefile` and `stardelt-demos/kind/up.sh` per `CLAUDE.md` (Task 9 handles the demos side).
- **Secrets** are applied out-of-band from `*.example.yaml` templates; real files are git-ignored.

## File Structure

**Create:**
- `environments/prod.env` — committed prod defaults (domain, ACME prod, dns-sync off).
- `environments/lab.env` — lab override (domain, ACME prod, dns-sync on).
- `manifests/ingress/cluster-issuer.yaml` — cert-manager `ClusterIssuer` (ACME DNS-01 / Cloudflare). Token file.
- `manifests/ingress/certificate.yaml` — wildcard `Certificate` → secret `stardelt-wildcard-tls`. Token file.
- `manifests/ingress/oauth2-proxy.yaml` — oauth2-proxy `Deployment` + `Service`. Token file.
- `manifests/ingress/middleware-auth.yaml` — Traefik forward-auth `Middleware`. Token file.
- `manifests/ingress/ingress-routes.yaml` — one `Ingress` per host. Token file.
- `manifests/cloudflare-api-token.example.yaml` — template Secret for the Cloudflare token.
- `manifests/oauth2-proxy-creds.example.yaml` — template Secret for GitHub OAuth app creds + cookie secret.
- `scripts/dns-sync.sh` — update the Cloudflare wildcard A-record to the current master IP.
- `scripts/render.sh` — tiny `envsubst` wrapper that renders a token file to stdout.

**Modify:**
- `Makefile` — add `CERT_MANAGER_VERSION`, `OAUTH2_PROXY_VERSION`, a `_helm-repos` entry, and `ingress` / `dns-sync` / `uninstall-ingress` targets.
- `.gitignore` — ignore the real (non-example) secret files and any rendered output.
- `README.md` — document the ingress flow, secrets, and recreate runbook.
- `../stardelt-demos/kind/up.sh` — add the cert-manager version pin comment (Task 9).

---

### Task 1: `render.sh` — token substitution helper

**Files:**
- Create: `scripts/render.sh`
- Test (manual): a throwaway token file under `/tmp`

- [ ] **Step 1: Write the script**

`scripts/render.sh`:
```bash
#!/usr/bin/env bash
# Render a manifest template by substituting our explicit tokens (and only those):
#   __STARDELT_DOMAIN__       → $STARDELT_DOMAIN
#   __STARDELT_ACME_SERVER__  → $STARDELT_ACME_SERVER (optional; left as-is if unset)
# Usage: STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh manifests/ingress/foo.yaml
set -euo pipefail

file="${1:?usage: render.sh <template-file>}"
: "${STARDELT_DOMAIN:?STARDELT_DOMAIN must be set (e.g. lab.stardelt.io)}"
acme="${STARDELT_ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"

# '|' as the sed delimiter because the ACME server value contains '/'.
sed -e "s/__STARDELT_DOMAIN__/${STARDELT_DOMAIN}/g" \
    -e "s|__STARDELT_ACME_SERVER__|${acme}|g" \
    "$file"
```

We use `sed` (not `envsubst`) so unrelated `$` shell-style refs in manifests are never touched — only our explicit tokens are replaced. The ACME server defaults to Let's Encrypt prod when unset, so templates without that token are unaffected.

- [ ] **Step 2: Make executable and verify it fails without the var**

```bash
chmod +x scripts/render.sh
printf 'host: nova.__STARDELT_DOMAIN__\n' > /tmp/tok.yaml
unset STARDELT_DOMAIN; scripts/render.sh /tmp/tok.yaml; echo "exit=$?"
```
Expected: prints an error mentioning `STARDELT_DOMAIN must be set` and a non-zero exit.

- [ ] **Step 3: Verify it substitutes correctly**

```bash
STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh /tmp/tok.yaml
```
Expected output:
```
host: nova.lab.stardelt.io
```

- [ ] **Step 4: Commit**

```bash
git add scripts/render.sh
git commit -m "feat: add render.sh token-substitution helper for ingress manifests"
```

---

### Task 1B: Environment files (prod-default / lab-override)

**Files:**
- Create: `environments/prod.env`
- Create: `environments/lab.env`

- [ ] **Step 1: Write the prod defaults**

`environments/prod.env`:
```bash
# Production defaults. This is the canonical path — `make ingress` with no
# STARDELT_ENV targets prod. Keep this minimal and stable; rarely edit it.
STARDELT_DOMAIN=cloud.stardelt.io
STARDELT_ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory
# Prod has a stable IP/LB, so DNS is set once and never re-synced.
STARDELT_DNS_SYNC=false
```

- [ ] **Step 2: Write the lab override**

`environments/lab.env`:
```bash
# Lab (dev) overrides. Opt in with: STARDELT_ENV=lab make ingress
# Edit this freely while developing.
STARDELT_DOMAIN=lab.stardelt.io
STARDELT_ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory
# Switch to LE staging during heavy cert churn to avoid rate limits:
#   STARDELT_ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
# The lab master IP changes on every hetzner-k3s recreate, so re-point DNS.
STARDELT_DNS_SYNC=true
```

- [ ] **Step 3: Verify both files source cleanly and expose the expected vars**

```bash
( set -a; . environments/prod.env; set +a; echo "prod: $STARDELT_DOMAIN dns=$STARDELT_DNS_SYNC" )
( set -a; . environments/lab.env;  set +a; echo "lab:  $STARDELT_DOMAIN dns=$STARDELT_DNS_SYNC" )
```
Expected:
```
prod: cloud.stardelt.io dns=false
lab:  lab.stardelt.io dns=true
```

- [ ] **Step 4: Commit**

```bash
git add environments/prod.env environments/lab.env
git commit -m "feat: add prod-default/lab-override environment files"
```

---

### Task 2: Secret templates + .gitignore

**Files:**
- Create: `manifests/cloudflare-api-token.example.yaml`
- Create: `manifests/oauth2-proxy-creds.example.yaml`
- Modify: `.gitignore`

- [ ] **Step 1: Write the Cloudflare token template**

`manifests/cloudflare-api-token.example.yaml`:
```yaml
# Cloudflare API token used by cert-manager (DNS-01) and scripts/dns-sync.sh.
# Scope: DNS:Edit on the stardelt.io zone.
# Copy to manifests/cloudflare-api-token.yaml, fill in, then:
#   kubectl apply -f manifests/cloudflare-api-token.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: stardelt
type: Opaque
stringData:
  api-token: "REPLACE_WITH_CLOUDFLARE_DNS_EDIT_TOKEN"
```

- [ ] **Step 2: Write the oauth2-proxy creds template**

`manifests/oauth2-proxy-creds.example.yaml`:
```yaml
# GitHub OAuth app credentials for oauth2-proxy.
# Create a GitHub OAuth App in the stardelt org:
#   Homepage URL:              https://nova.<STARDELT_DOMAIN>
#   Authorization callback URL: https://auth.<STARDELT_DOMAIN>/oauth2/callback
# cookie-secret must be a 32-byte base64 value:
#   openssl rand -base64 32
# Copy to manifests/oauth2-proxy-creds.yaml, fill in, then:
#   kubectl apply -f manifests/oauth2-proxy-creds.yaml
apiVersion: v1
kind: Secret
metadata:
  name: oauth2-proxy-creds
  namespace: stardelt
type: Opaque
stringData:
  client-id: "REPLACE_WITH_GITHUB_OAUTH_CLIENT_ID"
  client-secret: "REPLACE_WITH_GITHUB_OAUTH_CLIENT_SECRET"
  cookie-secret: "REPLACE_WITH_OPENSSL_RAND_BASE64_32"
```

- [ ] **Step 3: Ignore the real secret files and rendered output**

Append to `.gitignore`:
```
# Filled-in secrets (never commit) — only the *.example.yaml templates are tracked
manifests/cloudflare-api-token.yaml
manifests/oauth2-proxy-creds.yaml
# Rendered ingress manifests
manifests/ingress/*.rendered.yaml
```

- [ ] **Step 4: Verify the real names are ignored**

```bash
touch manifests/cloudflare-api-token.yaml manifests/oauth2-proxy-creds.yaml
git status --porcelain manifests/ | grep -E 'cloudflare-api-token.yaml|oauth2-proxy-creds.yaml' || echo "correctly ignored"
rm manifests/cloudflare-api-token.yaml manifests/oauth2-proxy-creds.yaml
```
Expected: prints `correctly ignored` (the non-example files do not show up).

- [ ] **Step 5: Commit**

```bash
git add manifests/cloudflare-api-token.example.yaml manifests/oauth2-proxy-creds.example.yaml .gitignore
git commit -m "feat: add secret templates for cloudflare token + oauth2-proxy creds"
```

---

### Task 3: cert-manager ClusterIssuer + wildcard Certificate

**Files:**
- Create: `manifests/ingress/cluster-issuer.yaml`
- Create: `manifests/ingress/certificate.yaml`

**Note:** cert-manager itself is installed via Helm in Task 8. These manifests are applied *after* the cert-manager CRDs exist. This task only authors and render-checks them.

- [ ] **Step 1: Write the ClusterIssuer**

`manifests/ingress/cluster-issuer.yaml`:
```yaml
# Lets-Encrypt production issuer using ACME DNS-01 via Cloudflare.
# DNS-01 (not HTTP-01) so we can issue a wildcard cert and need no inbound :80.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: __STARDELT_ACME_SERVER__
    email: admin@stardelt.io
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

- [ ] **Step 2: Write the wildcard Certificate**

`manifests/ingress/certificate.yaml`:
```yaml
# One wildcard cert covering every per-service subdomain plus the apex.
# Stored in secret stardelt-wildcard-tls; every Ingress references it.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: stardelt-wildcard
  namespace: stardelt
spec:
  secretName: stardelt-wildcard-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  commonName: "*.__STARDELT_DOMAIN__"
  dnsNames:
    - "*.__STARDELT_DOMAIN__"
    - "__STARDELT_DOMAIN__"
```

- [ ] **Step 3: Render-check both files**

```bash
STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh manifests/ingress/certificate.yaml | grep -E 'dnsNames|stardelt.io|\*'
```
Expected: shows `*.lab.stardelt.io` and `lab.stardelt.io` with no remaining `__STARDELT_DOMAIN__` token.

- [ ] **Step 4: Validate YAML well-formedness (offline, no cluster needed)**

```bash
STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh manifests/ingress/cluster-issuer.yaml | kubectl apply --dry-run=client -f - 2>&1 | head
```
Expected: either `clusterissuer.cert-manager.io/letsencrypt-prod created (dry run)` if CRDs are present, OR an error containing `no matches for kind "ClusterIssuer"` (acceptable here — it confirms the YAML parsed; CRDs arrive in Task 8). A YAML *syntax* error is a failure.

- [ ] **Step 5: Commit**

```bash
git add manifests/ingress/cluster-issuer.yaml manifests/ingress/certificate.yaml
git commit -m "feat: add cert-manager ClusterIssuer + wildcard Certificate (DNS-01)"
```

---

### Task 4: oauth2-proxy Deployment + Service

**Files:**
- Create: `manifests/ingress/oauth2-proxy.yaml`

- [ ] **Step 1: Write the manifest**

`manifests/ingress/oauth2-proxy.yaml`:
```yaml
# oauth2-proxy — GitHub provider, restricted to the stardelt org.
# Fronts every stardelt UI via a Traefik forward-auth middleware (see
# middleware-auth.yaml). Emits identity headers consumed at the edge.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy
  namespace: stardelt
  labels: { app.kubernetes.io/name: oauth2-proxy }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: oauth2-proxy }
  template:
    metadata:
      labels: { app.kubernetes.io/name: oauth2-proxy }
    spec:
      containers:
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
          args:
            - --provider=github
            - --github-org=stardelt
            - --http-address=0.0.0.0:4180
            - --reverse-proxy=true
            - --cookie-domain=.__STARDELT_DOMAIN__
            - --whitelist-domain=.__STARDELT_DOMAIN__
            - --cookie-secure=true
            - --email-domain=*
            - --upstream=static://202
            - --redirect-url=https://auth.__STARDELT_DOMAIN__/oauth2/callback
            - --set-xauthrequest=true
            - --pass-access-token=false
            - --skip-provider-button=false
          env:
            - name: OAUTH2_PROXY_CLIENT_ID
              valueFrom: { secretKeyRef: { name: oauth2-proxy-creds, key: client-id } }
            - name: OAUTH2_PROXY_CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: oauth2-proxy-creds, key: client-secret } }
            - name: OAUTH2_PROXY_COOKIE_SECRET
              valueFrom: { secretKeyRef: { name: oauth2-proxy-creds, key: cookie-secret } }
          ports:
            - containerPort: 4180
              name: http
          resources:
            requests: { cpu: "10m", memory: "32Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: oauth2-proxy
  namespace: stardelt
  labels: { app.kubernetes.io/name: oauth2-proxy }
spec:
  type: ClusterIP
  selector: { app.kubernetes.io/name: oauth2-proxy }
  ports:
    - name: http
      port: 4180
      targetPort: http
```

- [ ] **Step 2: Render + dry-run validate**

```bash
STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh manifests/ingress/oauth2-proxy.yaml | kubectl apply --dry-run=client -f -
```
Expected: `deployment.apps/oauth2-proxy created (dry run)` and `service/oauth2-proxy created (dry run)`. No remaining `__STARDELT_DOMAIN__` token (verify visually).

- [ ] **Step 3: Commit**

```bash
git add manifests/ingress/oauth2-proxy.yaml
git commit -m "feat: add oauth2-proxy deployment + service (GitHub org SSO)"
```

---

### Task 5: Traefik forward-auth Middleware

**Files:**
- Create: `manifests/ingress/middleware-auth.yaml`

- [ ] **Step 1: Write the Middleware**

`manifests/ingress/middleware-auth.yaml`:
```yaml
# Traefik forward-auth: every protected Ingress delegates auth to oauth2-proxy.
# authResponseHeaders copies the GitHub identity onto the upstream request
# (Layer-1 passthrough). This is the ONLY Traefik-specific CRD in the design.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: oauth2-forward-auth
  namespace: stardelt
spec:
  forwardAuth:
    address: http://oauth2-proxy.stardelt.svc.cluster.local:4180/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
```

This file has no domain token, so it is applied directly (not rendered).

- [ ] **Step 2: Dry-run validate**

```bash
kubectl apply --dry-run=client -f manifests/ingress/middleware-auth.yaml 2>&1 | head
```
Expected: `middleware.traefik.io/oauth2-forward-auth created (dry run)` if Traefik CRDs are present, OR `no matches for kind "Middleware"` (acceptable offline — confirms YAML parsed). A YAML syntax error is a failure.

- [ ] **Step 3: Commit**

```bash
git add manifests/ingress/middleware-auth.yaml
git commit -m "feat: add Traefik forward-auth middleware with identity passthrough"
```

---

### Task 6: Ingress routes (host-based, TLS, auth middleware)

**Files:**
- Create: `manifests/ingress/ingress-routes.yaml`

- [ ] **Step 1: Write the Ingress manifest**

`manifests/ingress/ingress-routes.yaml`:
```yaml
# Host-routed ingress for every stardelt UI. All share the wildcard cert
# (stardelt-wildcard-tls) and the oauth2 forward-auth middleware, EXCEPT the
# auth host itself (it must stay reachable to perform the login/callback).
#
# Traefik middleware is attached via the namespaced annotation
# <namespace>-<middleware-name>@kubernetescrd.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stardelt-auth
  namespace: stardelt
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  tls:
    - hosts: ["auth.__STARDELT_DOMAIN__"]
      secretName: stardelt-wildcard-tls
  rules:
    - host: auth.__STARDELT_DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy
                port: { number: 4180 }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stardelt-uis
  namespace: stardelt
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: stardelt-oauth2-forward-auth@kubernetescrd
spec:
  tls:
    - hosts:
        - nova.__STARDELT_DOMAIN__
        - superset.__STARDELT_DOMAIN__
        - airflow.__STARDELT_DOMAIN__
        - trino.__STARDELT_DOMAIN__
      secretName: stardelt-wildcard-tls
  rules:
    - host: nova.__STARDELT_DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nova
                port: { number: 8080 }
    - host: superset.__STARDELT_DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: superset
                port: { number: 8088 }
    - host: airflow.__STARDELT_DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: airflow-api-server
                port: { number: 8080 }
    - host: trino.__STARDELT_DOMAIN__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: trino
                port: { number: 8080 }
```

- [ ] **Step 2: Render + dry-run validate; confirm all four backends + auth host**

```bash
STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh manifests/ingress/ingress-routes.yaml | kubectl apply --dry-run=client -f -
STARDELT_DOMAIN=lab.stardelt.io scripts/render.sh manifests/ingress/ingress-routes.yaml | grep -E 'host:|name: (nova|superset|airflow-api-server|trino|oauth2-proxy)'
```
Expected: dry-run reports `ingress.networking.k8s.io/stardelt-auth created (dry run)` and `ingress.networking.k8s.io/stardelt-uis created (dry run)`; the grep shows the five hosts and the five backend service names, with no `__STARDELT_DOMAIN__` token left.

- [ ] **Step 3: Commit**

```bash
git add manifests/ingress/ingress-routes.yaml
git commit -m "feat: add host-routed ingress with TLS + oauth2 middleware"
```

---

### Task 7: `dns-sync.sh` — point the wildcard A-record at the master IP

**Files:**
- Create: `scripts/dns-sync.sh`

- [ ] **Step 1: Write the script**

`scripts/dns-sync.sh`:
```bash
#!/usr/bin/env bash
# Point *.${STARDELT_DOMAIN} at the current k3s master public IP via Cloudflare.
# Idempotent: creates the A-record if missing, updates it if the IP changed.
#
# Requires:
#   STARDELT_DOMAIN     e.g. lab.stardelt.io
#   CLOUDFLARE_API_TOKEN  DNS:Edit token for the stardelt.io zone
#                         (falls back to reading the in-cluster secret)
#   kubectl context pointing at the target cluster; curl + jq installed.
set -euo pipefail

: "${STARDELT_DOMAIN:?STARDELT_DOMAIN must be set (e.g. lab.stardelt.io)}"
NAMESPACE="${NAMESPACE:-stardelt}"
record="*.${STARDELT_DOMAIN}"
# Zone is the registrable domain: strip all but the last two labels.
zone="$(echo "$STARDELT_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"

# Token: prefer env, else read the in-cluster secret created from the template.
token="${CLOUDFLARE_API_TOKEN:-}"
if [ -z "$token" ]; then
  token="$(kubectl -n "$NAMESPACE" get secret cloudflare-api-token \
    -o jsonpath='{.data.api-token}' | base64 -d)"
fi
[ -n "$token" ] || { echo "no Cloudflare token (set CLOUDFLARE_API_TOKEN or apply the secret)" >&2; exit 1; }

# Current master public IP: the node labeled control-plane, ExternalIP.
ip="$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
[ -n "$ip" ] || { echo "could not determine master ExternalIP from kubectl" >&2; exit 1; }
echo "› master IP: $ip"

cf() { curl -sf -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$@"; }
api="https://api.cloudflare.com/client/v4"

zone_id="$(cf "$api/zones?name=$zone" | jq -r '.result[0].id')"
[ -n "$zone_id" ] && [ "$zone_id" != "null" ] || { echo "zone $zone not found in Cloudflare" >&2; exit 1; }

rec_id="$(cf "$api/zones/$zone_id/dns_records?type=A&name=$record" | jq -r '.result[0].id // empty')"
payload="$(jq -nc --arg ip "$ip" --arg name "$record" \
  '{type:"A", name:$name, content:$ip, ttl:120, proxied:false}')"

if [ -n "$rec_id" ]; then
  cf -X PUT "$api/zones/$zone_id/dns_records/$rec_id" --data "$payload" >/dev/null
  echo "› updated $record → $ip"
else
  cf -X POST "$api/zones/$zone_id/dns_records" --data "$payload" >/dev/null
  echo "› created $record → $ip"
fi
```

Note: `proxied:false` is required — Cloudflare's orange-cloud proxy would intercept TLS and break cert-manager's DNS-01 challenge expectations and the wildcard cert handshake.

- [ ] **Step 2: Make executable and verify it fails without the domain var**

```bash
chmod +x scripts/dns-sync.sh
unset STARDELT_DOMAIN; scripts/dns-sync.sh; echo "exit=$?"
```
Expected: error `STARDELT_DOMAIN must be set` and non-zero exit.

- [ ] **Step 3: Verify zone-derivation logic offline**

```bash
STARDELT_DOMAIN=lab.stardelt.io bash -c 'echo "$STARDELT_DOMAIN" | awk -F. "{print \$(NF-1)\".\"\$NF}"'
```
Expected output: `stardelt.io`

- [ ] **Step 4: Commit**

```bash
git add scripts/dns-sync.sh
git commit -m "feat: add dns-sync.sh to point wildcard A-record at master IP"
```

---

### Task 8: Makefile wiring — env layering, versions, repos, `ingress` + `dns-sync` targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add env layering at the top of the Makefile**

In `Makefile`, immediately after the `NAMESPACE ?= stardelt` line, add:
```makefile
# Environment layering: prod is the default (runs on committed defaults);
# `STARDELT_ENV=lab make ingress` opts into the edited dev cluster.
# environments/<env>.env sets STARDELT_DOMAIN, STARDELT_ACME_SERVER, STARDELT_DNS_SYNC.
STARDELT_ENV ?= prod
include environments/$(STARDELT_ENV).env
export STARDELT_DOMAIN STARDELT_ACME_SERVER STARDELT_DNS_SYNC
```
`include` makes the env file's `KEY=value` lines into Make variables; `export`
pushes them into the environment of every recipe shell (so `render.sh` and
`dns-sync.sh` see them). A missing env file makes `include` fail loudly, which
is the desired guard against a typo'd `STARDELT_ENV`.

- [ ] **Step 2: Add pinned chart versions**

After the `SUPERSET_VERSION := 0.15.5` line, add:
```makefile
CERT_MANAGER_VERSION := 1.16.2
OAUTH2_PROXY_VERSION := 7.7.1
```
(`OAUTH2_PROXY_VERSION` is reserved for a future Helm-based oauth2-proxy install; this plan deploys oauth2-proxy via the manifest in Task 4, with its container image tag pinned there. The variable is added now so the pin lives alongside the others.)

- [ ] **Step 3: Add helm repo for cert-manager**

In the `_helm-repos:` recipe, before the `@helm repo update` line, add:
```makefile
	@helm repo add jetstack       https://charts.jetstack.io                         2>/dev/null || true
```

- [ ] **Step 4: Add the `ingress`, `dns-sync`, and `uninstall-ingress` targets**

Add to the `.PHONY` line: `ingress dns-sync uninstall-ingress`. Then append this block to the end of `Makefile`:
```makefile
# ---------------------------------------------------------------------------
# Ingress: cert-manager + oauth2-proxy + Traefik routes
# ---------------------------------------------------------------------------
# Config comes from environments/$(STARDELT_ENV).env (default: prod).
# Lab cluster:  STARDELT_ENV=lab make ingress
# Before running, apply the two secrets:
#   kubectl apply -f manifests/cloudflare-api-token.yaml
#   kubectl apply -f manifests/oauth2-proxy-creds.yaml
ingress: deps _helm-repos ## Install ingress stack (STARDELT_ENV=prod|lab)
	@echo "› env=$(STARDELT_ENV) domain=$(STARDELT_DOMAIN) dns-sync=$(STARDELT_DNS_SYNC)"
	@echo "› [1/6] cert-manager"
	@helm upgrade --install cert-manager jetstack/cert-manager \
	  --version $(CERT_MANAGER_VERSION) \
	  --namespace cert-manager --create-namespace --wait --timeout 5m \
	  --set crds.enabled=true

	@echo "› [2/6] ClusterIssuer + wildcard Certificate"
	@bash scripts/render.sh manifests/ingress/cluster-issuer.yaml | kubectl apply -f -
	@bash scripts/render.sh manifests/ingress/certificate.yaml    | kubectl apply -f -

	@echo "› [3/6] oauth2-proxy"
	@bash scripts/render.sh manifests/ingress/oauth2-proxy.yaml | kubectl apply -f -

	@echo "› [4/6] Traefik forward-auth middleware"
	@kubectl apply -f manifests/ingress/middleware-auth.yaml

	@echo "› [5/6] Ingress routes"
	@bash scripts/render.sh manifests/ingress/ingress-routes.yaml | kubectl apply -f -

	@echo "› [6/6] DNS sync"
	@if [ "$(STARDELT_DNS_SYNC)" = "true" ]; then \
	  NAMESPACE=$(NAMESPACE) bash scripts/dns-sync.sh; \
	else \
	  echo "  skipped (STARDELT_DNS_SYNC=$(STARDELT_DNS_SYNC); prod uses a static IP)"; \
	fi

	@echo ""
	@echo "Ingress installed for *.$(STARDELT_DOMAIN). Check: kubectl get certificate -n $(NAMESPACE)"

dns-sync: ## Re-point the wildcard A-record at the current master IP (lab)
	@NAMESPACE=$(NAMESPACE) bash scripts/dns-sync.sh

uninstall-ingress: ## Remove the ingress stack (keeps cert-manager CRDs)
	@bash scripts/render.sh manifests/ingress/ingress-routes.yaml | kubectl delete --ignore-not-found -f -
	@kubectl delete --ignore-not-found -f manifests/ingress/middleware-auth.yaml
	@bash scripts/render.sh manifests/ingress/oauth2-proxy.yaml | kubectl delete --ignore-not-found -f -
	@bash scripts/render.sh manifests/ingress/certificate.yaml  | kubectl delete --ignore-not-found -f -
	@bash scripts/render.sh manifests/ingress/cluster-issuer.yaml | kubectl delete --ignore-not-found -f -
	@helm uninstall cert-manager --namespace cert-manager --ignore-not-found 2>/dev/null || true
	@echo "Ingress stack removed."
```
`STARDELT_DOMAIN` and `STARDELT_ACME_SERVER` are exported (Step 1), so the
`render.sh` invocations pick them up from the environment without explicit
pass-through.

- [ ] **Step 5: Verify env layering resolves and targets show in help**

```bash
make help | grep -E 'ingress|dns-sync'
make -np STARDELT_ENV=prod 2>/dev/null | grep -E 'STARDELT_DOMAIN|STARDELT_DNS_SYNC' | head -2
make -np STARDELT_ENV=lab  2>/dev/null | grep -E 'STARDELT_DOMAIN|STARDELT_DNS_SYNC' | head -2
```
Expected: help shows `ingress`, `dns-sync`, `uninstall-ingress`; the prod dump shows `cloud.stardelt.io` + `false`; the lab dump shows `lab.stardelt.io` + `true`.

- [ ] **Step 6: Verify a bad env fails loudly**

```bash
make ingress STARDELT_ENV=nope 2>&1 | head -3; echo "rc=${PIPESTATUS[0]}"
```
Expected: fails with a "No such file" error for `environments/nope.env` and a non-zero `rc` — it must not reach the helm step.

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "feat: add env-layered make ingress/dns-sync targets + chart pins"
```

---

### Task 9: Sync cert-manager version pin into demos

**Files:**
- Modify: `../stardelt-demos/kind/up.sh`

Per `CLAUDE.md`, chart versions are pinned in two repos that must stay in sync. The kind demo does **not** enable ingress, but the pin must still be recorded.

- [ ] **Step 1: Inspect where versions are pinned in up.sh**

```bash
grep -nE 'VERSION|version|cert-manager' ../stardelt-demos/kind/up.sh | head -30
```
Read the surrounding lines to match the existing style (variable block vs inline).

- [ ] **Step 2: Add the cert-manager pin in the same style**

If `up.sh` uses a version variable block, add (matching the file's existing formatting):
```bash
# Pinned to stardelt-platform/Makefile CERT_MANAGER_VERSION.
# kind demo does NOT enable ingress; recorded here only to satisfy the
# platform/demos version-sync rule in CLAUDE.md.
CERT_MANAGER_VERSION="1.16.2"
```
If `up.sh` pins versions inline at the `helm install` call sites instead, add the same two comment lines (without the variable) next to the other version pins so the value is discoverable. Do not wire an actual cert-manager install into the kind flow.

- [ ] **Step 3: Verify the pin is present and the script still parses**

```bash
grep -n 'CERT_MANAGER_VERSION\|cert-manager' ../stardelt-demos/kind/up.sh
bash -n ../stardelt-demos/kind/up.sh && echo "syntax ok"
```
Expected: the grep shows the new pin/comment; `syntax ok` prints.

- [ ] **Step 4: Commit (in the demos repo)**

```bash
cd ../stardelt-demos
git add kind/up.sh
git commit -m "chore: record cert-manager version pin (sync with stardelt-platform)"
cd ../stardelt-platform
```

---

### Task 10: Document the ingress flow + recreate runbook

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add an "Internet access (ingress + SSO)" section**

Insert after the existing "Quickstart" section in `README.md`:
````markdown
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
````

- [ ] **Step 2: Verify the section renders and links are consistent**

```bash
grep -nE 'STARDELT_ENV|make ingress|make dns-sync|oauth2|stardelt-wildcard' README.md | head
```
Expected: shows the new commands and host references; no stray `__STARDELT_DOMAIN__` token (the README uses concrete hostnames, not the manifest token).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document ingress + SSO setup and cluster-recreate runbook"
```

---

### Task 11: End-to-end verification on the live lab cluster

This task is **operational** — run against the real `stardelt-lab` cluster. It has no code; it confirms the whole design works and surfaces config mistakes (callback URL, cookie domain, token scope).

**Pre-req:** `stardelt-lab` is up, `export KUBECONFIG=./kubeconfig` (per the hetzner-k3s memory), the platform is installed (`make install`), and the two secrets are applied.

- [ ] **Step 1: Install ingress and watch the cert issue**

```bash
export STARDELT_ENV=lab
make ingress
kubectl get certificate -n stardelt -w   # wait until stardelt-wildcard READY=True (DNS-01 can take 1-3 min)
```
Expected: `stardelt-wildcard` reaches `READY=True`. If stuck, check `kubectl describe certificate stardelt-wildcard -n stardelt` and `kubectl get challenges -A` — a stuck challenge means the Cloudflare token scope or zone is wrong.

- [ ] **Step 2: Confirm DNS resolves to the master IP**

```bash
dig +short nova.lab.stardelt.io
kubectl get nodes -l node-role.kubernetes.io/control-plane=true -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'; echo
```
Expected: the two values match.

- [ ] **Step 3: Confirm logged-out requests redirect to GitHub**

```bash
for h in nova superset airflow trino; do
  printf '%s -> ' "$h"; curl -sI "https://$h.lab.stardelt.io" | head -1
done
```
Expected: each returns `HTTP/2 302` (redirect toward GitHub / the auth host). A `200` for `trino` would mean the middleware is not attached — re-check the annotation in `ingress-routes.yaml`.

- [ ] **Step 4: Confirm the full login works in a browser**

Open `https://nova.lab.stardelt.io`, complete GitHub login as a `stardelt` org member.
Expected: Nova UI loads. Then open `https://superset.lab.stardelt.io` in the same browser — it should **not** prompt for GitHub again (shared cookie on `.lab.stardelt.io`), confirming SSO. Each app may still show its *own* login.

- [ ] **Step 5: Confirm identity headers reach an upstream**

```bash
kubectl logs -n stardelt deploy/oauth2-proxy | grep -i 'authenticated\|AuthSuccess' | tail -3
```
Expected: log lines showing a successful GitHub authentication for your user. (This confirms `--set-xauthrequest=true` is active; the headers are then copied by the middleware's `authResponseHeaders`.)

- [ ] **Step 6: Record the result**

No commit (operational task). If any step failed, fix the relevant manifest/secret, re-run `make ingress`, and repeat. Note the outcome in the PR description when finishing the branch.

---

## Self-Review

**Spec coverage:**
- Per-service subdomains → Task 6. ✓
- Env layering (prod-default / lab-override, `STARDELT_ENV`) → Tasks 1B, 8. ✓
- `STARDELT_DOMAIN` + `STARDELT_ACME_SERVER` token substitution → Tasks 1, 8. ✓
- k3s Traefik (entrypoints/middleware annotations, no chart install) → Tasks 5, 6. ✓
- cert-manager + DNS-01 wildcard cert (env-selected ACME server) → Tasks 3, 8. ✓
- oauth2-proxy GitHub-org SSO → Task 4. ✓
- Forward-auth + Layer-1 identity headers → Task 5. ✓
- Secrets inventory (cloudflare-api-token, oauth2-proxy-creds, auto wildcard tls) + example templates + gitignore → Task 2. ✓
- dns-sync for ephemeral IP, env-conditional (lab only) → Tasks 7, 8. ✓
- Install order in make target → Task 8. ✓
- Recreate runbook + verification checklist + failure modes → Tasks 10, 11. ✓
- demos/platform version-sync rule → Task 9. ✓
- Layer-2 explicitly out of scope → not implemented (correct). ✓

**Placeholder scan:** No TBD/TODO. `__STARDELT_DOMAIN__` / `__STARDELT_ACME_SERVER__` (manifest tokens) and `$STARDELT_DOMAIN` / `$STARDELT_ENV` (shell/Make vars) are intentional and consistently distinguished. `REPLACE_WITH_*` strings live only in `*.example.yaml` templates by design.

**Type/name consistency:** Service backends (`nova:8080`, `superset:8088`, `airflow-api-server:8080`, `trino:8080`, `oauth2-proxy:4180`) are identical across Tasks 4, 6, and the spec. Middleware name `oauth2-forward-auth` matches its annotation reference `stardelt-oauth2-forward-auth@kubernetescrd` in Task 6. Env var names (`STARDELT_ENV`, `STARDELT_DOMAIN`, `STARDELT_ACME_SERVER`, `STARDELT_DNS_SYNC`) match across the env files (Task 1B), `render.sh` (Task 1), and the Makefile (Task 8). Secret keys (`api-token`; `client-id`/`client-secret`/`cookie-secret`) match between Task 2 templates and their consumers in Tasks 3, 4. Cert secret `stardelt-wildcard-tls` matches between Tasks 3 and 6.

**Task numbering note:** tasks run 1, 1B, 2–11 (1B inserted to keep the original numbering stable). Execute in that order.
