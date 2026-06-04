# Ingress, Domain Routing & GitHub SSO — Design Spec

**Date:** 2026-06-04
**Repo:** `stardelt-platform` (with documented touchpoints in `stardelt-demos`)
**Status:** Approved design, pre-implementation

## Goal

Expose Nova and the stardelt subservices (Superset, Airflow, Trino) on the
internet under stable hostnames so colleagues can reach them, fronted by a
single GitHub-org-restricted sign-in. Treat the existing Hetzner k3s
`stardelt-lab` cluster as the **dev** environment. Shape the design so a future
**prod** cluster (e.g. `cloud.stardelt.io`) reuses the same manifests, differing
only by one variable and two secrets.

## Context / starting state

- **No ingress exists today.** Every service is `ClusterIP`, reachable only via
  `kubectl port-forward` (`stardelt-platform/scripts/port-forwards.sh`).
- **Nova** (`manifests/nova-deployment.yaml`) serves its own SPA and proxies
  **only** Trino + Lakekeeper under `/api/*`. Superset and Airflow have their
  own separate web UIs that Nova does **not** front.
- **Cluster:** single-master hetzner-k3s `stardelt-lab` (1× master, 2× workers,
  `fsn1`), k3s `v1.36.1+k3s1`. k3s ships **Traefik** as the built-in ingress
  controller and **ServiceLB (klipper)**, which exposes Traefik directly on the
  node public IPs (host ports 80/443). **There is no Hetzner LoadBalancer** —
  so the master's public IP changes every time the throwaway cluster is
  recreated.
- **DNS:** `stardelt.io` is hosted at **Cloudflare** with full API control,
  including wildcard records.
- **cert-manager** is already named as a planned component in
  `stardelt-docs/docs/architecture/services.md` and `overview.md`.
- **Auth today:** none shared. Nova uses a static dev user (`NOVA_DEV_USER`),
  Airflow has a static admin (`webserverSecretKey` + admin user), Superset has
  its own login, **Trino has no UI auth at all**.

## Decisions (locked during brainstorming)

| Topic | Decision |
|---|---|
| DNS control | Cloudflare, full API control, wildcard allowed |
| Topology | **Per-service subdomains** (one hostname per UI) |
| Access control | **SSO via oauth2-proxy** |
| Identity provider | **GitHub**, restricted to the `stardelt` org |
| Domain scheme | **Env subdomain + base var** (`STARDELT_DOMAIN`) |
| Env layering | **`STARDELT_ENV` defaults to `prod`** — prod runs on committed defaults; `lab` is the edited override layer |
| Ingress controller | **k3s built-in Traefik** |
| IP→DNS strategy | **Approach A** — manual/scripted single wildcard A-record + DNS-01 wildcard cert |
| Identity passthrough | **Layer 1 only** — edge forwards identity headers to all upstreams; apps consume them later |

## Architecture

```
                          Cloudflare DNS
                    *.lab.stardelt.io  →  A  →  <master public IP>
                                                      │
                                          (ServiceLB / klipper, host :80/:443)
                                                      ▼
   Browser ───TLS───▶  Traefik (k3s built-in ingress)
                         │  1. terminates TLS (wildcard cert from cert-manager)
                         │  2. forward-auth middleware ──▶ oauth2-proxy ──▶ GitHub (stardelt org)
                         │       (unauthenticated → 302 to GitHub login)
                         │  3. routes by Host header:
                         ├─ nova.lab.stardelt.io      ──▶ svc/nova:8080
                         ├─ superset.lab.stardelt.io  ──▶ svc/superset:8088
                         ├─ airflow.lab.stardelt.io   ──▶ svc/airflow-api-server:8080
                         ├─ trino.lab.stardelt.io     ──▶ svc/trino:8080
                         └─ auth.lab.stardelt.io      ──▶ svc/oauth2-proxy:4180  (callback host)
```

**New platform components:** `cert-manager` and `oauth2-proxy`. Everything else
is Ingress objects plus a Traefik `Middleware`. Services remain `ClusterIP` —
we add ingress in front, we do not change the services themselves.

**Ephemeral-cluster concession:** on every `hetzner-k3s create`, the master gets
a new public IP. `scripts/dns-sync.sh` reads it and updates the single Cloudflare
**wildcard** A-record. Because the record is a wildcard, adding a new service
later requires zero DNS work — just a new Ingress object.

## Environment layering (prod-default, lab-override)

The guiding principle: **prod is the canonical path that runs on committed
defaults; lab is the deviation you actively edit.** This keeps prod boring and
safe while the lab stays fast to hack on, and it inverts the common failure mode
where prod becomes the special-cased thing.

- **`STARDELT_ENV` defaults to `prod`.** A bare `make ingress` targets prod. The
  dev cluster is an explicit opt-in: `STARDELT_ENV=lab make ingress`.
- **Per-environment config lives in `environments/<env>.env`**, sourced by the
  Makefile. Each file sets `STARDELT_DOMAIN` and a small set of named knobs:
  - **`environments/prod.env`** — the *defaults*. Minimal, set-and-forget:
    `STARDELT_DOMAIN=cloud.stardelt.io`, static DNS (no IP tracking),
    Let's Encrypt **prod** issuer. You should rarely touch this.
  - **`environments/lab.env`** — the *override layer* you edit freely:
    `STARDELT_DOMAIN=lab.stardelt.io`, `dns-sync` **on** (ephemeral Hetzner master
    IP re-pointed each rebuild), issuer switchable to LE **staging** during heavy
    cert churn.
- **The honest prod↔lab differences, named explicitly:**

  | Knob | `prod` (default) | `lab` (edited) |
  |---|---|---|
  | `STARDELT_DOMAIN` | `cloud.stardelt.io` | `lab.stardelt.io` |
  | `STARDELT_DNS_SYNC` | `false` (static IP/LB) | `true` (re-point each rebuild) |
  | `STARDELT_ACME_SERVER` | LE prod | LE prod (switchable to staging) |
  | GitHub org gate | `stardelt` | `stardelt` |

- **`STARDELT_DOMAIN`** remains the single variable driving every hostname:
  `nova.${STARDELT_DOMAIN}`, `superset.${STARDELT_DOMAIN}`,
  `airflow.${STARDELT_DOMAIN}`, `trino.${STARDELT_DOMAIN}`,
  `auth.${STARDELT_DOMAIN}`.
- **Injection mechanism:** the platform uses plain manifests + `helm upgrade`
  via a `Makefile`, not a templating engine. To avoid pulling in Helm/Kustomize
  solely for this, ingress manifests live as `manifests/ingress/*.yaml` with
  literal `__STARDELT_DOMAIN__` / `__STARDELT_ACME_SERVER__` tokens, and the
  `make ingress` target performs `sed` substitution at apply time — the same
  copy-and-fill spirit as the existing `s3-credentials.example.yaml` convention.
  Helm-chart services (Superset, Airflow, Trino) receive ingress via a standalone
  Ingress manifest rather than chart-specific `ingress:` blocks, to keep all
  routing in one place and controller-portable.
- **Forward-looking:** this same `environments/<env>.env` rail is where future
  prod-vs-lab divergence belongs (replica counts, resource requests — the current
  values files are lab/kind-tuned, e.g. Trino "1 worker"). Out of scope now
  (YAGNI), but the structure exists so adding those is a new line in the env
  file, not a new mechanism.
- **Per-cluster secrets** are still out-of-band and differ per environment: the
  Cloudflare token (same zone, fine to reuse) and the oauth2-proxy GitHub OAuth
  app (lab and prod need different callback URLs → separate OAuth apps).

## TLS, cert-manager & secrets

- **cert-manager** installed via its Helm chart. Its chart version is pinned in
  the two canonical places per `CLAUDE.md`: `stardelt-platform/Makefile` and
  `stardelt-demos/kind/up.sh` (even though the kind demo does not enable
  ingress — see parity note below).
- **One `ClusterIssuer`** (`letsencrypt-prod`) using **ACME DNS-01** against
  Cloudflare. DNS-01 is chosen over HTTP-01 because it (a) supports a **wildcard**
  certificate and (b) never requires inbound port 80 reachable during issuance.
- **One `Certificate`**: `*.${STARDELT_DOMAIN}` (plus the apex
  `${STARDELT_DOMAIN}`), stored in Secret `stardelt-wildcard-tls` in the
  `stardelt` namespace. Every Ingress references this single secret — no per-host
  issuance, no Let's Encrypt rate-limit risk.
- **Secrets inventory** (all provided out-of-band; real files git-ignored,
  `*.example.yaml` templates committed — mirrors `s3-credentials.example.yaml`):

  | Secret | Used by | Contents |
  |---|---|---|
  | `cloudflare-api-token` | cert-manager DNS-01 + `dns-sync.sh` | Cloudflare API token scoped to **DNS-edit on the `stardelt.io` zone** (needed to write `_acme-challenge` TXT records) |
  | `oauth2-proxy-creds` | oauth2-proxy | GitHub OAuth app client-id + client-secret + a generated cookie secret |
  | `stardelt-wildcard-tls` | Traefik ingress | Auto-managed by cert-manager — **not** created by hand |

## oauth2-proxy & GitHub SSO

- **oauth2-proxy** deployed in the `stardelt` namespace (`svc/oauth2-proxy:4180`),
  provider = **GitHub**, restricted to the **`stardelt` org**
  (`--github-org=stardelt`; can be tightened to a team later).
- **Enforcement = Traefik forward-auth middleware.** A `Middleware` CRD points at
  oauth2-proxy's `/oauth2/auth` endpoint; every protected Ingress attaches it via
  annotation. Unauthenticated request → Traefik calls oauth2-proxy → 302 to
  GitHub → callback → cookie set → request proceeds. This is the **only**
  Traefik-specific CRD in the design; it is isolated to one middleware object, so
  swapping ingress controllers later means rewriting one file, not the routes.
- **Callback host:** `auth.${STARDELT_DOMAIN}` registered as the GitHub OAuth
  app's callback URL. Cookie domain `.${STARDELT_DOMAIN}` so a single login covers
  all subdomains — **this delivers SSO across Nova, Superset, Airflow, and Trino
  in one GitHub sign-in.**
- **GitHub OAuth app:** one per cluster (lab and prod need different callback
  URLs). Created manually in the `stardelt` org settings; client-id/secret land in
  `oauth2-proxy-creds`. Documented as a per-cluster setup step.
- **App-level auth underneath:** oauth2-proxy gates *network* access. The apps
  keep their own logins (Superset, Airflow admin, Nova static-dev) behind that
  gate. Trino — which has no UI auth — becomes safe because nothing reaches it
  without passing GitHub first.

## Identity passthrough (Layer 1 only)

- oauth2-proxy emits `X-Auth-Request-User` and `X-Auth-Request-Email`.
- The Traefik forward-auth middleware lists those in `authResponseHeaders`, so
  **every upstream receives the authenticated GitHub identity on every request.**
- Apps do **not** consume the header yet — that is explicit future work (see
  appendix). This keeps the current change platform-only with zero app rebuilds.

## DNS sync, operations & cluster lifecycle

- **`scripts/dns-sync.sh`** (in `stardelt-platform/scripts/`): reads the master's
  public IP (via `kubectl get nodes -o wide`, falling back to the Hetzner API),
  then idempotently `PATCH`es the single Cloudflare wildcard A-record
  `*.${STARDELT_DOMAIN}` using `cloudflare-api-token`. Safe to re-run; domain and
  record name come from `STARDELT_DOMAIN`.
- **Install order** (in a new `make ingress`, after sourcing `environments/<env>.env`):
  cert-manager → `ClusterIssuer` + `Certificate` → oauth2-proxy + `Middleware`
  → Ingress objects → `dns-sync.sh` **only when `STARDELT_DNS_SYNC=true`** (lab).
  In prod the DNS step is skipped because the IP is static.
- **Cluster-recreate runbook (lab only):** `hetzner-k3s create` →
  `STARDELT_ENV=lab make ingress` (or just `STARDELT_ENV=lab make dns-sync` if
  ingress is already installed) → wait for the certificate to be re-issued
  automatically → done. One command beyond cluster creation. Prod never needs
  this — its IP does not change.
- **kind/demos parity:** the kind demo cannot do real public DNS/TLS, so ingress
  there stays **optional and disabled by default**, documented as "lab cluster
  only" to avoid breaking the laptop demo. The cert-manager chart version pin is
  still added to `stardelt-demos/kind/up.sh` to satisfy the `CLAUDE.md`
  version-sync rule, even though the demo does not enable it.

## Error handling & testing

This is declarative infrastructure; the runbook + verification checklist is the
test. No automated suite.

**Verification checklist (manual):**
1. `kubectl get certificate -n stardelt` → `stardelt-wildcard-tls` is `Ready`.
2. Logged out, each host (`nova`, `superset`, `airflow`, `trino`) returns a
   302 to GitHub.
3. After GitHub login (as a `stardelt` org member), each host serves its app.
4. `trino.${STARDELT_DOMAIN}` is unreachable without completing GitHub auth.
5. A debug upstream confirms `X-Auth-Request-User` / `-Email` arrive on requests.

**Documented failure modes:**
- Cert stuck `not Ready` → check DNS-01 TXT propagation and Cloudflare token
  scope.
- 502 at a host → service name/port mismatch in the Ingress backend.
- Redirect loop → cookie-domain or callback-URL mismatch in oauth2-proxy.
- Wrong IP after a recreate → re-run `dns-sync.sh`.

## Out of scope (future work)

- **Layer 2 identity consumption** — wiring each app to log the user in from the
  forwarded header, in rough order of effort:
  1. **Trino** — trust `X-Trino-User` / header authenticator in `trino.yaml` (low).
  2. **Nova** — read `X-Auth-Request-Email` instead of `NOVA_DEV_USER`; Rust
     change in `stardelt-nova`, requires an image rebuild (medium; note: Nova
     cannot currently be developed locally on this machine).
  3. **Superset** — `AUTH_REMOTE_USER` custom security manager in
     `superset_config.py`; requires rebuilding the superset image (medium).
  4. **Airflow** — Airflow 3.x FAB auth-manager header/proxy auth (high; fiddly).
- **external-dns** (Approach B) and a **stable Hetzner LoadBalancer / floating
  IP** (Approach C) — both are purely additive for the future prod cluster
  because this design uses a wildcard host and standard Ingress objects.
- **Self-hosted IdP** (Keycloak/Authentik) for full sovereignty.
