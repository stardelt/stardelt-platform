# stardelt-platform

Production-shape deployment artifacts. Helm values, manifests, and scripts to install stardelt on any conformant Kubernetes cluster.

> A laptop demo does not exist: the platform needs a real node (see docs getting-started).
> Full documentation: [stardelt.io](https://stardelt.io)

---

## Prerequisites

| Tool | Minimum version | Notes |
|------|----------------|-------|
| `kubectl` | 1.28+ | Must be configured with a valid kubeconfig pointing at your cluster |
| `helm` | 3.18+ | The `stardelt-dedupe` post-renderer plugin is installed automatically |
| `docker` | any recent | Required only for the local image targets (`make build-superset-image`, `make build-jupyter-image`) |
| `cert-manager` | 1.15+ | Required by `make install-identity`: the Trino coordinator's in-cluster TLS certificate is issued by a namespace-local CA (`manifests/trino-tls.yaml`). The playground installs it with the ingress (see `dev/playground/README.md`). `make install-core` without identity does not need it. |

Your `kubectl` current-context determines the target cluster. Verify with:

```sh
kubectl config current-context
```

Every installing or uninstalling `make` target prints the context it is about to act on.
Set `EXPECT_CONTEXT` to make it refuse any other cluster:

```sh
EXPECT_CONTEXT=stardelt-dev make install-core
```

---

## S3 credentials (generated)

All components that touch object storage read credentials from the `stardelt-s3-creds` Secret.
`make install` and `make install-core` generate it on the first run (`scripts/s3-secrets.sh`:
a random key pair, also written to `seaweedfs-s3-config` for the SeaweedFS gateway) and never
overwrite an existing one. To bring your own, create **both** Secrets before installing;
`manifests/s3-credentials.example.yaml` shows the first, and `seaweedfs_s3_config` is
`{"identities":[{"name":"stardelt","credentials":[{"accessKey":"…","secretKey":"…"}],"actions":["Admin","Read","Write"]}]}`.

The object store also ships its own web UI (buckets, users and policies, a file browser). It is
**for cluster administrators only**, reached with `make seaweedfs-admin` (a port-forward to
`http://127.0.0.1:23646`; the login is the generated Secret `seaweedfs-admin-ui`, never printed). It
has no ingress — and none may be added — because it can change storage identities and read every
object, so it is exactly as sensitive as `kubectl`. Normal users do not get raw storage access; they
get the governed *Volumes* view in Nova (later).

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

### Who may use notebooks

The hub is default-closed. Two groups are admitted: `stardelt-admins`, and
**`stardelt-users` — the realm's default group**, so an account created in the
Keycloak console can open a notebook without an administrator doing anything.
`make sync-realm-user-management` guarantees the group exists and stays a default
group; membership is the only switch.

## Helm chart (baseline)

`chart/` is the declarative alternative to `make install`: one umbrella chart
(`stardelt-platform`) with every component as a sub-chart, plus Nova, the CNPG
Postgres cluster, the S3 credentials Secret and the Lakekeeper bootstrap Job as
templates. Same chart versions, same values and same object names as the
Makefile path — use **one or the other** per namespace, not both.

```sh
make chart-deps     # helm dependency update chart (fetches the sub-charts)
make chart-template # render to stdout, change nothing
make chart-install  # helm upgrade --install stardelt chart -n stardelt
```

What is on by default (same shape as `make install-core`): the CNPG operator and
its `lakekeeper-pg` Cluster, SeaweedFS, Lakekeeper, the Lakekeeper bootstrap Job,
Trino, the `stardelt-s3-creds` Secret and Nova. Off by default: Superset,
Airflow and JupyterHub. Turn them on via `--set` or your own values file:

```sh
make chart-install CHART_EXTRA="--set superset.enabled=true -f my-values.yaml"
```

Two things to know before enabling the heavy components: Superset and Airflow
cannot both be enabled in one release — the Superset chart's bundled Redis defines
the same Helm template names as the Airflow chart, so the render fails — and their
objects are named after the release (`stardelt-api-server`, `stardelt-postgresql`,
...) rather than `airflow-api-server`, so the playground ingress needs the matching
name.

For a small single node (cx33 / 8 GB), `chart/values-slim.yaml` mirrors
`helm-values/slim/trino.yaml`:

```sh
make chart-install CHART_EXTRA="-f chart/values-slim.yaml"
```

With ingress.enabled=true only Nova (and Keycloak in identity.mode=platform) get an Ingress; list components in ingress.exposeUnauthenticated (e.g. [trino]) to expose a UI that has no sign-in.

`stardelt-s3-creds` is generated on first install (random key pair, also written to
`seaweedfs-s3-config` for the SeaweedFS gateway), kept across upgrades and on uninstall.
Set `s3Credentials.accessKey` / `secretKey` to choose your own, or `s3Credentials.create=false`
and create both Secrets yourself (`manifests/s3-credentials.example.yaml` shows the first).

A chart install also gets the catalog's continuous backups (`postgres.backup`,
on by default): the `lakekeeper-pg` Cluster declares `spec.backup.barmanObjectStore`
writing to `s3://<postgres.backup.bucket>/` on `s3Credentials.endpoint`, and the
daily `ScheduledBackup` `lakekeeper-pg-daily` (`immediate: true`) adds base
backups. The destination bucket must exist — the SeaweedFS sub-chart creates
`backups`, but with `s3Credentials.create=false` create it in your own store
first. The #59 backup guards describe a chart install as well; point them at the
release namespace: `NAMESPACE=<release ns> make verify-backup-config` / `verify-backups`.

Keycloak's database (`keycloak-pg`) is backed up the same way as the catalog (WAL streaming plus a daily base backup into `s3://backups/keycloak-pg/`); check it with `make verify-backups-identity`.

Nova's state store (`nova-pg`, database `nova`: saved queries, personal settings) is a third CloudNative-PG Cluster, installed with Nova (`manifests/nova-pg.yaml`, or the chart with `nova.database.enabled`, on by default). The operator generates its password into Secret `nova-pg-app`; Nova reads the complete URL from the Secret's `uri` key as `NOVA_DATABASE_URL`. It is backed up like the other two (`s3://backups/nova-pg/`); check it with `make verify-backups-nova`.

| Value | Default | Effect |
|---|---|---|
| `nova.secretStore.url` | `""` | Address of the secret store Nova signs in to with the person's own token, passed as `NOVA_SECRET_STORE_URL`. Empty = the Connections API answers 503 and no extra RBAC is rendered. |
| `nova.secretStore.role` | `platform-users` | `NOVA_SECRET_STORE_ROLE` — the store role a person's token is exchanged for. |
| `nova.secretStore.mount` | `secret` | `NOVA_SECRET_STORE_MOUNT` — the store mount connection secrets are written under. |
| `nova.airflow.*` | url `""`, user `nova-api`, passwordSecret `airflow-nova-api`/`password` | Airflow REST API for pipeline runs and logs, passed as `NOVA_AIRFLOW_URL`, `NOVA_AIRFLOW_USER` and `NOVA_AIRFLOW_PASSWORD` (a `secretKeyRef`, never a value). Empty `url` = the Pipelines API answers 503 and no extra RBAC is rendered. With `url` set, the chart also renders the `nova-pipelines` Role and RoleBinding: `get`, `list` and `watch` on `pipelines.stardelt.io` in the release namespace — no create, no delete. Example: `--set nova.airflow.url=http://airflow-api-server:8080`. |

With `nova.secretStore.url` set, the chart also renders the `nova-connections` Role and RoleBinding: `get`, `list`, `create`, `delete` and `patch` on `connections.stardelt.io` in the release namespace — nothing else, no Secrets access. `patch` is for the break-glass notice Nova sets as an annotation on the `Connection`. Example: `--set nova.secretStore.url=http://openbao.<namespace>.svc.cluster.local:8200`.

`make verify-backups` expects recent write activity on the catalog: its WAL-freshness check fails on an idle cluster, which is correct. The SeaweedFS filer needs **512Mi** of memory — at 256Mi it was OOM-killed in a loop and took S3 writes down with it (platform#230); raise it only with a measured peak, never by lowering another limit.

---

## Airflow and Superset credentials

Neither values file contains a secret. `scripts/app-secrets.sh` generates them on the
cluster and every install path runs it first (`make install`, `make chart-install`);
`make install-core` does not need it. It is idempotent — a Secret that already exists is
left untouched, so re-running an install never rotates a key under a running stack.

| Secret | Keys | Read by |
|---|---|---|
| `airflow-fernet-key` | `fernet-key` | `fernetKeySecretName` |
| `airflow-webserver-key` | `webserver-secret-key`, `api-secret-key` | `webserverSecretKeySecretName` (Airflow <3) and `apiSecretKeySecretName` (Airflow 3) |
| `airflow-jwt-secret` | `jwt-secret` | `jwtSecretName` |
| `airflow-admin` | `username`, `password` | create-user Job env → `airflow users create` |
| `superset-secret-key` | `secret-key` | `SUPERSET_SECRET_KEY` via `extraEnvRaw` |
| `superset-admin` | `username`, `password`, `firstname`, `lastname`, `email` | Superset init Job (password) |

The Airflow chart has no Secret reference for `createUserJob.defaultUser` and the Superset
chart has no `supersetSecretKeySecretName` (its `extraSecretEnv` writes literals), so both
values files use the charts' next-smallest hooks instead: `createUserJob.env` plus custom
`args`, and `extraEnvRaw` plus a copy of the default `init.initscript` that reads the
password from the environment. Usernames and profile fields stay in values; only
credentials come from Secrets.

The Secrets carry `app.kubernetes.io/part-of=stardelt` and belong to no Helm release, so
`make uninstall` / `helm uninstall` keep them (like the PVCs). Read one back deliberately —
the script never prints a value:

```sh
kubectl -n stardelt get secret airflow-admin -o jsonpath='{.data.password}' | base64 -d
kubectl -n stardelt get secret airflow-fernet-key -o jsonpath='{.data}' | jq 'keys'
```

To rotate, delete the Secret and re-run the step — `NAMESPACE=stardelt bash
scripts/app-secrets.sh` (or the next `make install`). Two things to know:

- **The fernet key is not like the others.** Rotating `airflow-fernet-key` makes every
  connection Airflow stored encrypted in its metadata database undecryptable; the stored
  credentials have to be re-entered. Rotating the API/JWT/session keys only ends sessions
  (Superset users get logged out).
- **The Airflow create-user Job only creates the user.** Changing an existing user's
  password is Airflow CLI work, not a Secret edit. And because Job specs are immutable,
  delete the two Airflow Jobs before the first upgrade that carries this change:
  `kubectl -n stardelt delete job airflow-create-user airflow-run-airflow-migrations`.

---

## Identity (optional platform IdP)

stardelt has two identity modes (contract: `docs/architecture/identity` in stardelt-docs):
an **external** OIDC provider (Entra ID, Okta, a corporate Keycloak) or the **platform** IdP,
Keycloak, that every building block authenticates against. Either way the platform publishes
the same ConfigMap, `stardelt-identity`, with `issuerUrl`, `groupClaim` (`groups`) and
`adminGroup` (`stardelt-admins`). The platforms' own installer adds `authMode`, `publicUrl` and
`trinoUrl` (the coordinator's in-cluster TLS endpoint, which exists under exactly the same
condition — see "TLS on the coordinator").

| Umbrella chart | Makefile | What is deployed |
|---|---|---|
| `identity.mode: none` (default) | — | nothing |
| `identity.mode: platform` | `make install-identity` | Keycloak (official `quay.io/keycloak/keycloak`, Apache-2.0) + its own CNPG Cluster `keycloak-pg`, realm `stardelt`; Ingress `id.<baseDomain>` when `ingress.enabled` (playground: `dev/playground/ingress.yaml`) |
| `identity.mode: external` + `identity.issuerUrl` | — | only `stardelt-identity` (render fails without an https issuer) |

```sh
make install-core SLIM=1                                    # CNPG operator first
make install-identity BASE_DOMAIN=alpha.dev.stardelt.io     # Keycloak at https://id.<BASE_DOMAIN>
# or: make chart-install CHART_EXTRA="--set identity.mode=platform --set platform.baseDomain=example.com"
```

### Embedding JupyterHub in Nova

Nova's Notebooks page frames the hub, and the hub sends a signed-in person on to their own
single-user server — JupyterLab, which executes code and refuses framing harder than any
dashboard. Both apps refuse framing by default (`frame-ancestors 'none'`), so both get the same
narrow exception: **Nova's own origin, and only that origin**, read from the identity contract
(`stardelt-identity.publicUrl`) instead of being written into a values file. The origin reaches
the server at spawn (`STARDELT_NOVA_ORIGIN`) and the image's `jupyter_server_config.py` turns it
into the server's CSP. Hub and server cookies are set `SameSite=None; Secure`, because a frame is
a third-party context for the app inside it.

The sign-in page is the one thing that must stay unframeable: Keycloak refuses framing, so a
visitor without a hub session gets Nova's explicit **open in a new tab and sign in** call to
action instead of a blank frame. `/api/embeds` reports exactly that: Nova stops following
redirects at the app's own origin, judges the app's own headers, and names the sign-in host the
signed-out journey lands on. Without the identity contract nothing is made frameable and Nova
says so rather than showing an empty box.

### Notebooks: the user's own identity, inside the pod

Spawning a server is more than starting JupyterLab: the single-user pod gets the user's workspace
and, with it, a way to query the warehouse **as themselves**.

* **Image.** `helm-values/jupyterhub.yaml` points the single-user pods at
  `ghcr.io/stardelt/jupyter-singleuser:dev` (built by the `Image` workflow from
  `images/jupyter/Dockerfile`): `scipy-notebook` plus the `trino` Python client,
  `pyspark[connect]`, `pandas` and `pyarrow`, the git extensions `jupyterlab-git`
  and `nbgitpuller` (both BSD-3-Clause), and the `warehouse-quickstart` notebook under
  `/opt/stardelt/notebooks/`. `jupyterlab-sql` is deliberately absent — its last release predates
  JupyterLab 4 and it cannot carry the per-user token. The package is private, like Superset, so
  the pod pulls with the `ghcr-creds` secret.
* **Framing.** The same image installs `/usr/local/etc/jupyter/jupyter_server_config.py`, which
  allows exactly Nova's origin to frame this server — the origin the hub passes as
  `STARDELT_NOVA_ORIGIN` at spawn (from the identity contract). With no IdP the variable is
  absent and the server keeps JupyterHub's `frame-ancestors 'none'`. See "Embedding JupyterHub
  in Nova".
* **Token.** The hub enables `enable_auth_state` and an `auth_state_hook` copies the user's
  Keycloak access token into the pod's environment as `TRINO_TOKEN` at spawn
  (`20-notebook-identity` in `hub.extraConfig`). Nothing is shared between users and nothing is
  baked into the image; Trino sees the hub user, not a service account.
* **Notebook.** A `postStart` hook copies `/opt/stardelt/notebooks/*.ipynb` into the home
  directory the first time only (`cp -n`), so a user's edits survive restarts. The quickstart
  connects with `trino.auth.JWTAuthentication(os.environ["TRINO_TOKEN"])`, asserts
  `SELECT current_user` equals the hub user, lists schemas and queries `warehouse.demo.trips`.
* **Endpoint.** With an IdP the hub overrides `TRINO_URL` at spawn
  (`25-notebook-trino` in `hub.extraConfig`) to the coordinator's **in-cluster HTTPS**
  endpoint, `https://trino.stardelt.svc.cluster.local:8443`, and points the `trino` Python
  client's `REQUESTS_CA_BUNDLE` at the internal CA that signs it
  (`manifests/trino-tls.yaml`, mounted from Secret `trino-ca`). No public hostname, no
  hairpin through the ingress, and no disabled certificate check. Without an IdP the static
  `singleuser.extraEnv.TRINO_URL` — the public HTTPS origin — applies, because there is no
  TLS listener and no certificate.
* **Lifetime.** The realm's `jupyterhub` client gets `access.token.lifespan=28800` (8 h) — a
  notebook holds the token in its environment for a whole session, where the realm's 5-minute
  default would mean 401s minutes after spawn. Restarting the server re-mints it
  (`refresh_pre_spawn`); after the 10 h SSO session the user signs in again.
* **Spark.** The quickstart's Spark cell reads `warehouse.demo.trips` through Spark Connect, the
  second engine over the same catalog. Spark is optional (`make install-spark`); the cell reports
  what it found when the endpoint is absent. The singleuser NetworkPolicy grants egress to exactly
  two private destinations — the `spark-connect` pods on 15002 (see "Spark") and the Trino
  coordinator on 8443 (the in-cluster TLS endpoint above) — everything else private stays denied.
* **Git.** The image ships the `git` binary plus `jupyterlab-git` (Git panel in JupyterLab) and
  `nbgitpuller` (one-click clone of a repository into the user's home via a hub link, for
  training sessions). Users authenticate with their **own** tokens, kept in the notebook
  environment (e.g. `GITHUB_TOKEN` exported in a terminal, or a credential helper) — no token
  and no repository URL ever enters the image. Public git hosts work out of the box (user pods
  may egress to public IPs); a *private* git server needs its CIDRs listed — `notebooks.gitHosts`
  in the umbrella chart, `singleuser.networkPolicy.egress` in `helm-values/jupyterhub.yaml` —
  granted HTTPS-only (TCP 443), never open-all. The two workflows (a notebook repository cloned
  into the user's home and pushed from the Git panel; pipeline resources kept in git, validated
  in CI (`kubectl apply --dry-run=server` against the operator's CRDs) and applied by CI or a
  GitOps controller) are documented in the developer guide.

`scripts/verify-notebook-identity.py` is the acceptance test for all of this: it signs in at the
hub headlessly, restarts the server, runs the quickstart inside the pod and then runs it again
with `TRINO_TOKEN` unset to prove the 401.

```sh
HUB_URL=https://jupyter.alpha.dev.stardelt.io NOTEBOOK_USER=analyst NOTEBOOK_PASSWORD=... \
  python3 scripts/verify-notebook-identity.py
```

### Trino: the query engine behind the identity

Trino is the one building block whose authentication state is derived from the platform:
`make trino` (and therefore `make install`, `install-core` and `install-identity`) applies
`helm-values/trino-identity.yaml` **when the `stardelt-identity` ConfigMap exists**, and the
plain development default when it does not.

| Property (`helm-values/trino-identity.yaml`) | Effect |
|---|---|
| `http-server.authentication.type=PASSWORD,OAUTH2` | every statement needs credentials; anonymous `POST /v1/statement` answers `401` with no query id |
| `web-ui.authentication.type=oauth2` | the Trino web UI redirects to Keycloak; `<trino host>/oauth2/callback` is the registered redirect |
| `web-ui.preview.enabled=false` | the preview UI (`/ui/preview/`) is off; the classic UI at `/ui/` stays, for administrators |
| `http-server.authentication.oauth2.issuer` / `client-id=trino` / `client-secret` | validates the caller's **own** Keycloak access token and sets `current_user` to its `preferred_username` |
| `…oidc.use-userinfo-endpoint=false` | local JWT validation against the realm JWKS, so the `aud` claim is enforced |
| `server.config.https` (port 8443, PKCS12 keystore mounted from Secret `trino-coordinator-tls`) | the in-cluster TLS listener; clients carry the user's bearer token to it (`manifests/trino-tls.yaml`) |
| `http-server.authentication.allow-insecure-over-http=false` | a plain-HTTP statement is refused (403, no query id) **before** any authenticator runs, so the insecure authenticator — the one that trusts `X-Trino-User` — is unreachable |
| `http-server.process-forwarded=true` | the ingress still terminates Let's Encrypt TLS and forwards HTTP to 8080 with `X-Forwarded-Proto`, which Trino treats as secure; the public path is unchanged |
| `internal-communication.shared-secret=${ENV:…}` | required as soon as an authenticator is enabled |
| `accessControl` (file `rules.json`: `queries` and `tables`) | query visibility is owner-only: each user sees and kills only their own queries, members of `stardelt-admins` see and kill all (viewing/killing one's own needs no rule — it is built-in). The `tables` rules deny everyone but `stardelt-admins` the cluster-wide `system.runtime.tasks`, `.transactions` and `.optimizer_rule_stats` (`tasks` lists other users' queries) and grant every other table as before; `system.runtime.queries` (own queries only) and `.nodes` stay open (platform#181) |
| `coordinator.additionalConfigFiles` (`group-provider.properties`) + `trino-groups` volume | the file group provider reads `stardelt-admins` membership from ConfigMap `trino-group-file` (written by `scripts/sync-trino-groups.sh`, never committed); `file.refresh-period=30s` picks remounts up with no restart |

**What the public host serves (platform#181).** The `trino.<baseDomain>` Ingress
(`dev/playground/ingress.yaml`, and `chart/templates/ingress.yaml` when `trino` is listed in
`ingress.exposeUnauthenticated`) publishes only `/v1/statement` (SQL clients) and `/oauth2`
(the token and callback endpoints of `--external-authentication`). The engine UI, `/v1/query` and
`/v1/info` answer the ingress controller's `404`. Administrators open the UI through a
port-forward to the TLS listener:

```sh
kubectl -n stardelt port-forward svc/trino 8443:8443   # then open https://localhost:8443/ui/
```

The browser warns about the certificate (it comes from the namespace-local CA and does not list
`localhost`): accept it for the session, then sign in as a member of `stardelt-admins`. Keycloak
client `trino` has `https://localhost:8443/oauth2/callback` registered for this. Use 8443, not the
plain-HTTP port 8080 that `make pf` forwards: Trino answers statements there with `403`, and the
UI's sign-in would return to an origin Keycloak does not know.

**One token, several resources.** Trino trusts audience `trino` (its own client id); client `nova`
carries an `aud-trino` mapper, so the token Nova forwards — the user's, not a service account's —
is accepted at Trino and names the person in the query audit trail (`NOVA_FORWARD_IDENTITY=1`,
set in both the manifest and the chart). A token without `aud: trino` is rejected with `401`.

*Continuous group sync (platform#167).* `make trino` writes the group file once, but membership
changes between applies used to wait for the next one — a removed admin kept their all-queries
view with no bound. CronJob `trino-group-sync` (`manifests/trino-group-sync.yaml`, every
5 minutes) re-runs the sync from `scripts/trino-group-sync-job.py` and rewrites ConfigMap
`trino-group-file` when members changed, so both directions land within 10 minutes with no
apply and no restart. It authenticates as the dedicated `trino-group-sync` service-account
client with exactly `view-users` on `realm-management` (converged by
`scripts/keycloak-sync-trino-group-sync-client.sh`, run by `make install-identity`; the realm
import declares the client for fresh installs) — read-only group membership, nothing broader —
and its RBAC may only read that client secret and converge that one ConfigMap. Its logs state
counts, never principals.

*Service principal for scheduled pipelines (platform#118).* Scheduled `Pipeline` tasks run SQL on
the query engine as the confidential service-account client `pipeline-runner`, not as a person:
the engine's policies apply to scheduled work like to any user, and the run does not depend on a
user token that would expire. Its tokens carry the audience `trino` (mapper `aud-trino`); its
service account holds **no** admin-API role. The secret is key `pipeline-runner` in Secret
`stardelt-oidc-clients` (generated by `scripts/identity-bootstrap.sh`); the realm import declares the
client for fresh installs and `scripts/keycloak-sync-pipeline-runner-client.sh` (`make
sync-pipeline-runner-client`, run by `make install-identity`) converges a live realm: creates the
client when missing, re-applies the secret, restores the audience mapper, refuses a too powerful
service account and proves the result with the client's own token. Rotate by changing the Secret
key and re-running the target.

*One principal per owner group (scheduled jobs D20/D21, platform#244).* A `ServicePrincipal`
resource names a principal per owner group, and scheduled work runs as that group, not as the one
shared `pipeline-runner`. `make sync-principal NAME=analytics GROUP=analytics` converges the
confidential client `sp-analytics`: service account only, no interactive flow, one audience mapper
per requested audience (`AUDIENCES=trino,lakekeeper`, default `trino`) and a `groups` mapper, so
its token carries the owner group exactly as a person's does. Its service-account user is a member
of `GROUP` and of no other group, and holds no admin-API role. The client secret lives in Secret
`sp-analytics` in the namespace, keys `client-id` and `client-secret`, labels
`app.kubernetes.io/part-of: stardelt` and `stardelt.io/principal: analytics`; the scheduled workload
mounts it, and members of the group never read it. `ROTATE=1` generates a new secret, updates
Keycloak first and then the Secret, and proves the new value with a fresh token. `make
delete-principal NAME=analytics YES=1` removes the client and the Secret, but only for a client
that carries `stardelt-managed=principal`; anything else is refused.

*Catalog service clients (platform#282, step 1 of the catalog's authentication).* Every component
that calls the Iceberg REST catalog has its own confidential service client instead of sharing one:
`svc-catalog-trino` (the Trino coordinator), `svc-catalog-nova`, `svc-catalog-spark` (the Spark
Connect driver), `svc-catalog-airflow` (the task pods) and `svc-catalog-bootstrap` (the Lakekeeper
bootstrap Job). `make sync-catalog-clients` converges all five through the same script with
`KIND=service`: no owner group and no `groups` claim (each is a component, not a person), an
`aud-lakekeeper` audience mapper, the attribute `stardelt-managed=service`, and a Secret named after
the client in namespace `stardelt`, whose keys `client-id`, `client-secret` and `token-url` (the
realm's endpoint, written for a service client) are the source of truth. Rotation is a principal's:
`ROTATE=1 make sync-catalog-clients` writes a new value to Keycloak first, then to each Secret, and
proves every new value with a client-credentials token.
`make delete-catalog-clients YES=1` removes them, and only clients carrying
`stardelt-managed=service` are accepted. Lakekeeper still runs `allowall` and does not check these
tokens yet — the callers start sending them in the follow-up steps (#283, #284); only then can one
caller be revoked at a time.

*Catalog sign-in for Trino, Spark Connect and the bootstrap Job (platform#283, step 2).* Those
three callers now obtain a token from the realm's token endpoint and send it as
`Authorization: Bearer` on every catalog call; Lakekeeper ignores it until it validates tokens.
Trino's `warehouse` catalog gains `iceberg.rest-catalog.security=OAUTH2` plus the credential and
token-endpoint properties in `helm-values/trino-identity.yaml` (not in the base values: Trino
refuses to load a catalog with `security=OAUTH2` and no credential, and the base values are also
the `install-core` path, which has no IdP). Coordinator and workers read `client-id` and
`client-secret` from Secret `svc-catalog-trino` through their environment, so each JVM does its own
exchange, and Reloader restarts them when that Secret rotates. The Spark Connect driver builds
`spark.sql.catalog.warehouse.credential` and `.oauth2-server-uri` at startup from Secret
`svc-catalog-spark` (`images/spark/spark-connect-entrypoint.sh`) — the credential never enters
`spark-defaults.conf`. The bootstrap Job mounts Secret `svc-catalog-bootstrap` as files and sends
the token on every management call (`--data-urlencode client_secret@file`, `-H @file`), so neither
the secret nor the token appears in argv or a log line. **The requested scope is
`openid`**: the realm has neither a `lakekeeper` client scope nor Iceberg's default
`catalog` one and answers both with `400 invalid_scope`, so the caller would never get a
token; `openid` is a default scope of every client and is accepted, while the
`aud-lakekeeper` audience mapper still puts `aud=lakekeeper` on the token — the claim
Lakekeeper will check. Evidence that a caller asked for a token is Keycloak's own event log —
`kubectl -n stardelt logs deploy/keycloak | grep 'type="CLIENT_LOGIN"'` names the client id and the
grant type, never the token.

*Catalog sign-in for Nova and the Airflow task pods (platform#284, step 4).* The last two interactive
callers of the catalog now have their own service clients too. Nova reads
`NOVA_CATALOG_CLIENT_ID`, `NOVA_CATALOG_CLIENT_SECRET` and `NOVA_CATALOG_TOKEN_URL` from Secret
`svc-catalog-nova` (manifest and chart), and every Airflow pod — the KubernetesExecutor task pods
included — reads `CATALOG_CLIENT_ID`, `CATALOG_CLIENT_SECRET` and `CATALOG_TOKEN_URL` from
`svc-catalog-airflow`, rendered in `helm-values/airflow.yaml` and the umbrella chart's
`airflow.extraEnv`. Two details matter. All three variables come from the **same** Secret, because
Nova refuses to start on a partial configuration (`stardelt-nova#222`) and an optional
`secretKeyRef` cannot make one variable conditional on another; that is why a service client's
Secret also carries `token-url`, derived from the identity contract's issuer by
`make sync-catalog-clients`. And every reference is `optional`, so an install without an IdP (no
Secret) keeps Nova and Airflow running and both keep calling Lakekeeper anonymously — the
`install-core` shape. No cluster permission changes: the Role is the same as before.

*Sandbox secret store (opt-in, platform#160).* `make openbao` installs OpenBao (MPL-2.0, the one documented
non-permissive component, see the licence page) as the secret store of a sandbox, the store that External Secrets and the
platform's connections read (decision D23). It is not part of `make install`; production installs use the customer's own
store. Standalone with embedded storage on a 10 GiB volume, **auto-unseal by a static key** from Secret
`openbao-seal-key` (verified by replacing the pod), KV v2 at `secret/`, and JWT sign-in against the platform's identity
provider (role `platform-users`: audience `openbao`, user = the token's `sub`, `preferred_username` kept as metadata
`username`, groups from the `groups` claim, 15 minute tokens, default policy `connections-user`). `scripts/openbao-bootstrap.sh`
initialises once and is idempotent; the recovery key and the initial root token live
in Secret `openbao-init`, which is acceptable for a sandbox and for nothing else. The seal key and the volume belong
together: deleting the Secret while the volume exists makes the data unreadable. `make uninstall` removes the release and keeps
the volume and both Secrets. The audience mapper for `openbao` on the clients is a separate step.

*Connections in the store (platform#160).* Three scopes with different rules, one policy per rule, kept as files in
`scripts/openbao-policies/` and wired to the groups in the person's token by `scripts/openbao-connections.sh`:

| Path | Who | May |
|---|---|---|
| `connections/user/<sub>/…` | the person whose `sub` it is | create, read, update, delete, list |
| `connections/group/<g>/…` | every member of group `<g>` | create, read, update, delete, list |
| `connections/managed/…` | the admin group | create and update only (**write-only**, no read), list, inspect metadata, destroy |
| `connections/managed/…` | platform-run code (policy `connections-platform-read`, attached to a token or role later) | read |
| any group or personal path | the admin group | list, inspect metadata, destroy; **no read, no write** |

`make openbao OWNER_GROUPS="analytics finance"` writes the three shared policies, gives every owner group an external
group `owner-<g>` with the group alias `<g>` (the name exactly as the token's `groups` claim carries it) and the policy
`connections-group-<g>`, and makes `ADMIN_GROUP` (default `stardelt-admins`) the alias of `platform-admins`; it only
adds and updates, so a second run changes nothing. `make test-openbao-policies` proves every rule against a throwaway
local OpenBao in dev mode; it needs the `bao` binary (2.7.x), for example
`gh release download v2.7.0 --repo openbao/openbao --pattern 'openbao_2.7.0_linux_amd64.tar.gz'` (verify it against
the release's `checksums.txt`).

*Break-glass (decision D27, platform#225).* An administrator can read the value of a *group* connection in an
emergency — the owner left, the credential must be recovered or checked — but never quietly: the sign-in role
`breakglass` only accepts tokens issued to **Nova** (bound claim `azp` = `nova`, a member of the admin group), it
issues a 15 minute token that cannot be renewed, and `connections-breakglass` reads `connections/group/*` and nothing
else, so personal and managed values stay unreadable for everybody. The endpoint that demands the reason and notifies
the group is Nova's (stardelt-nova#151); this repository ships the role and the policy. Every sign-in and every read
is recorded by the audit device in `helm-values/openbao.yaml`, which writes one JSON object per line to the pod's
standard output: `kubectl -n stardelt logs openbao-0`, filter for `"role":"breakglass"`. In this sandbox the log is
only as durable as the pod's log — a log shipper is a later step, and the first alert should fire on a break-glass
sign-in (stardelt-platform#94).

*External Secrets and one store per owner group (platform#220).* External Secrets Operator
(Apache-2.0) is the one contract between the platform and any store: it syncs a store path into a
Kubernetes Secret, so workflows read a Secret and never the store itself (decision D23). Opt-in,
never part of `install`: `make external-secrets` installs the operator, `make eso-stores
STORE_GROUPS="analytics finance"` creates one `SecretStore` per owner group plus `openbao-managed`,
each with its own ServiceAccount, Kubernetes sign-in role and policy that may read only that
group's prefix (`connections/group/<g>/`, `connections/managed/`). Isolation is the role, not the
name: an `ExternalSecret` that points at `openbao-finance` but names
`connections/group/analytics/…` ends in `SecretSyncedError` and creates no Secret. A `SecretStore`
is namespaced, so it can only be used by `ExternalSecret`s in its own namespace — the stores live in
the workload namespace, and personal paths (`connections/user/`) never reach a Kubernetes Secret.

*Developer sign-in (platform#157).* Tools on a laptop (an editor extension, a notebook kernel, a
script) sign in as the person with the public client `stardelt-dev`: **device grant** (the tool shows a
code, the person approves it in a browser) or the authorization code flow with PKCE to a loopback
address (`http://127.0.0.1:<any port>/...`). Both need PKCE. Tokens carry the audiences `trino`,
`lakekeeper` and `nova` and the `groups` claim; the client has no secret and no service account, and its
scope is limited, so a laptop can do what the person can do in the browser, no more. The realm import
declares it for fresh installs; `scripts/keycloak-sync-dev-client.sh` (`make sync-dev-client`, run by
`make install-identity`) converges a live realm and proves the endpoints. Switch it off with
`make sync-dev-client DEV_CLIENT_ENABLED=false`. By hand:

```bash
ISSUER=https://id.<baseDomain>/realms/stardelt
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
curl -s "$ISSUER/protocol/openid-connect/auth/device" -d client_id=stardelt-dev -d scope=openid \
  -d code_challenge="$CHALLENGE" -d code_challenge_method=S256      # open verification_uri_complete in a browser
curl -s "$ISSUER/protocol/openid-connect/token" -d client_id=stardelt-dev \
  -d grant_type=urn:ietf:params:oauth:grant-type:device_code -d device_code=<device_code> -d code_verifier="$VERIFIER"
```

For an external provider register a public client with the same two flows (Entra: enable "Allow public
client flows") and the same audiences.

#### TLS on the coordinator (why the in-cluster path is safe)

Two listeners, one behavior:

```text
browser / BI  ──https──▶  ingress-nginx  ──http + X-Forwarded-Proto──▶  coordinator :8080
                              (Let's Encrypt)     (process-forwarded → "secure", 401 without credentials)

Nova, notebook pods  ──https──▶  coordinator :8443   (PKCS12 keystore from cert-manager)
```

*The in-cluster listener* is what makes a bearer token usable inside the cluster, and it is why
`allow-insecure-over-http=false` could be turned on: before this, a plain-HTTP request to 8080 ran
only the insecure authenticator, which trusts the caller's `X-Trino-User` — any pod could submit
SQL as anybody (`anonymous → 200`), while the ingress path was protected. A plain-HTTP statement
is now refused before an authenticator runs, and in-cluster clients use the HTTPS endpoint with
the user's own token. The HTTP listener stays because workers talk to the coordinator over it
(internal communication uses the shared secret, never the user authenticators) and because the
public path must keep working; changing it would not close the in-cluster hole.

*What signs the certificate:* the public issuer cannot. `letsencrypt-prod` is HTTP-01 only and
never covers `trino.stardelt.svc.cluster.local`, so a public certificate would force in-cluster
clients to resolve the public name and hairpin through the ingress (and fail on an air-gapped
install). `manifests/trino-tls.yaml` instead creates a namespace-local chain with cert-manager:
`Issuer/trino-selfsigned` → `Certificate/trino-ca` (a 5-year CA, Secret `trino-ca`) →
`Issuer/trino-ca` → `Certificate/trino-coordinator-tls` (90 days, DNS names `trino`,
`trino.stardelt`, `trino.stardelt.svc`, `trino.stardelt.svc.cluster.local`). cert-manager writes
the PKCS12 keystore into Secret `trino-coordinator-tls`; its password is Secret
`trino-tls-keystore`, generated once by `scripts/trino-tls-secret.sh` (`make trino` runs it).

*How clients trust it, without weakening anything:* each client gets that one anchor.
Nova reads Secret `trino-ca` (`tls.crt`) as `NOVA_TRINO_CA_PEM` and adds it to its TLS roots on
top of the public WebPKI roots; the notebook pods mount the same key as `ca.crt` and pass it as
`REQUESTS_CA_BUNDLE`; nothing sets `verify=False` and no global trust store is replaced.
Superset keeps the public host (`trino.<baseDomain>:443`) with the `superset` service account —
moving it to the in-cluster endpoint is a follow-up, and it is unaffected by this change.

*Rotation.* The leaf renews 30 days before its 90-day expiry and the CA renews a year before its
5-year expiry; a renewed **keystore** is loaded at startup, so pick it up with
`kubectl -n stardelt rollout restart deploy/trino-coordinator` — deliberately not automatic,
because a rollout kills running queries. Nova and the notebook pods read the CA as a file, so a CA
rotation is a restart of those clients.

```sh
# the in-cluster half: refusal over http and https, the certificate chain, and a
# real user token over the in-cluster TLS endpoint
NAMESPACE=stardelt TRINO_VERIFY_USER=analyst TRINO_VERIFY_USER_PASSWORD=… \
  bash scripts/verify-trino-tls.sh
```

Machine clients use the file password authenticator: user `superset` with a bcrypt hash in
Secret `trino-password-db` (key `password.db`, generated by `scripts/identity-bootstrap.sh`).
No password for a person is stored anywhere. The `superset` account falls in the
`execute`-only access-control rule, which is exactly what it needs; its path is unchanged.

Query visibility is enforced by Trino itself, not by hiding the UI: `make trino` syncs the
live realm's `stardelt-admins` membership into ConfigMap `trino-group-file` before the
upgrade (`make sync-trino-groups` runs the same step alone — idempotent, never prints a
value). Removing a user from `stardelt-admins` plus `make trino` removes their all-queries
view. Membership changes take effect on the next sync, not instantly — continuous sync is
a follow-up, not this mechanism.

```sh
# what the installer runs (idempotent)
make install-identity BASE_DOMAIN=alpha.dev.stardelt.io
# realm import skips an existing realm, so its Trino client is synced through the
# admin API by scripts/keycloak-sync-trino-client.sh (confidential secret, PKCE off,
# redirect URIs, aud-trino mapper on `nova`)

# all four acceptance checks, against the running cluster
NAMESPACE=stardelt TRINO_URL=https://trino.alpha.dev.stardelt.io \
  TRINO_VERIFY_USER=analyst TRINO_VERIFY_USER_PASSWORD=… \
  bash scripts/verify-trino-auth.sh
#  1/4 anonymous          → HTTP 401, no query id
#  2/4 service account    → current_user = superset   (the Secret behind Superset)
#  3/4 user identity      → current_user = analyst    (the user's own token)
#  4/4 stored connection  → current_user = superset   (the datasource Superset queries with)

# read the service-account password deliberately if a machine client needs it
kubectl -n stardelt get secret trino-password-db -o jsonpath='{.data.superset-password}' | base64 -d
```

Superset queries as the **`superset` service account**: the tracked datasource URI points at the
public host (`trino.<baseDomain>:443`) and carries **no password** —
`trino://superset@trino.<baseDomain>:443/warehouse`. The password never reaches a tracked file
*or Superset's metadata database*: `SQLALCHEMY_CUSTOM_PASSWORD_STORE`
(`helm-values/superset.yaml`, `configOverrides`) answers for the `trino` driver and the `superset`
user with `TRINO_SUPERSET_PASSWORD` from the environment, read from Secret
`trino-password-db` (key `superset-password`) every time Superset builds an engine — for SQL Lab,
for charts, and in the worker that runs async queries and alerts. The public host is a deliberate choice: the driver
needs TLS for password auth, and Superset's path did not have to move for the in-cluster hole to
close (`manifests/trino-tls.yaml`); pointing it at the in-cluster TLS endpoint is a follow-up. The
umbrella chart needs the same Trino overlay nested under `trino:` (the file above is flat for the
per-component install) — still a follow-up.

*Upgrading from the previous layout.* The old init Job copied the password into
`database.sqlalchemy_uri`, and Superset keeps a second copy in `database.password`. Re-setting the
URI without a password (`superset set-database-uri -d "Trino Warehouse" -u
"trino://superset@trino.<baseDomain>:443/warehouse"` inside the pod) is not enough: with a custom
password store configured, `set_sqlalchemy_uri` leaves the `password` column alone. Clear it once on
the same row (`d.password = None`) and check that `database.sqlalchemy_uri` prints
`trino://superset@…` — the store fills it in at connect time, so SQL Lab keeps working.

*Rotation.* Delete Secret `trino-password-db` and re-run `scripts/identity-bootstrap.sh`
(`make install-identity` calls it), then restart Trino so its password file is reloaded
(`kubectl -n stardelt rollout restart deploy/trino-coordinator deploy/trino-worker`). **Superset
needs nothing else**: its node and worker pods carry
`secret.reloader.stakater.com/reload: trino-password-db`, so Reloader (`make reloader`) rolls them
when the Secret changes — `helm-values/reloader.yaml` also enables `reloadOnCreate`, because the
rotation replaces the Secret (delete, then re-create) and Reloader ignores create events by default.
No init Job, no stored URI to rewrite. `make verify-trino-auth` proves
the result, including step 4/4, which runs `SELECT current_user` through Superset's own stored
connection. Without `make install-identity` there is no service account and no Trino
authentication, so the datasource stays credential-free and the password store has nothing to
inject.

### Turning on sign-in

`make install-identity` (or the chart's `identity.mode: platform`) is what wires the apps'
logins: Nova gets it from `nova.auth.mode`, while Superset, Airflow and JupyterHub read the
same `stardelt-identity` ConfigMap and `stardelt-oidc-clients` Secret with credentials only
they can see. Deploying the IdP alone (before those values landed) signed nobody in.

```sh
# chart path — the IdP and the login in one install
helm upgrade --install stardelt chart -n stardelt \
  --set identity.mode=platform --set platform.baseDomain=example.com \
  --set nova.auth.mode=oidc

# manifest path — set two values on the Deployment after `make install-identity`
kubectl -n stardelt set env deploy/nova \
  NOVA_AUTH_MODE=oidc NOVA_PUBLIC_URL=https://example.com
```

The issuer, client secret and session secret are read from `stardelt-identity`,
`stardelt-oidc-clients` (key `nova`) and `stardelt-nova-session` — all created by
`scripts/identity-bootstrap.sh` (manifest path) or by the chart (identity mode ≠ none), so
the only thing an operator supplies is the mode and Nova's public URL. The redirect URI
`<publicUrl>/api/auth/callback` must be registered at the IdP; the realm import does that
for the `nova` client already.

Two deliberate behaviours: the render **fails** when `nova.auth.mode=oidc` is set without
an issuer (rather than shipping a pod that crash-loops), and `dev` stays the default
everywhere, because CI and the Nova demo mode have no IdP.

JupyterHub is behind that same login: `helm-values/jupyterhub.yaml` (and the chart's
`jupyterhub:` block) uses `GenericOAuthenticator` with the realm's `jupyterhub` client,
reads the issuer from `stardelt-identity` and the client secret from `stardelt-oidc-clients`
(key `jupyterhub`), and admits the admin group (`allowed_groups`/`admin_groups`,
`stardelt-admins`) only. No password is in the values files; without an issuer the hub starts
but signs nobody in. Keycloak's realm `stardelt` admin console is published at
`https://id.<baseDomain>/admin/stardelt/console/` for platform admins (Nova links to it, see
[Managing users](#managing-users)); the master realm stays unreachable.

Superset and Airflow sign in through the same realm, via Flask-AppBuilder's OAuth provider
(`helm-values/superset.yaml`, `helm-values/airflow.yaml`): the issuer and admin group come
from `stardelt-identity`, the client secret from `stardelt-oidc-clients` (keys `superset` /
`airflow`) — as env for Superset's appended `superset_config.py`, and as projected files on
Airflow's api-server only, which is the pod that builds the FAB app. Both map the realm group
`stardelt-admins` to `Admin` (`AUTH_ROLES_MAPPING`, synced at every login) and register
other realm users read-only (`Gamma` in Superset, `Viewer` in Airflow).

Members of `stardelt-users` get SQL Lab and the warehouse's datasets in Superset: the group
maps to `Gamma` plus `stardelt-analyst`, a role the init Job creates and converges
(`scripts/superset-analyst-role.py`) — the built-in `sql_lab` and `Gamma` permission sets,
Alpha's dataset/datasource additions, and `database_access` on the `Trino Warehouse` database,
with no database write, upload or `all_database_access`/`all_datasource_access` permission.
That one `database_access` also exposes every dataset of that database, because Superset has
no SQL-Lab-without-Explore split at database level. The role is synced at every login, so
removing someone from the group removes it at their next sign-in. Queries still run as the
shared `superset` service account (`impersonate_logged_in_user` is off), so Trino records that
account for every Superset user; per-user execution is the impersonation step decided in
platform#279. That step must enable `CACHE_IMPERSONATION` in the same change: with
impersonation on and the flag off, the result cache serves one user's cached chart to another
(measured in platform#279).

Two consequences worth knowing:

- Any realm user can reach both UIs. Only `stardelt-admins` can administer them.
- FAB selects exactly one login view from `AUTH_TYPE`: OAuth and the local username/password
  form cannot both be live. The local admin rows and their Secrets are kept, and
  `STARDELT_AUTH_LOCAL_ONLY=1` on the Deployment switches back to the local form without
  touching the database — the way back in if the IdP is unreachable:

  ```sh
  kubectl -n stardelt set env deploy/superset STARDELT_AUTH_LOCAL_ONLY=1   # break-glass
  kubectl -n stardelt set env deploy/superset STARDELT_AUTH_LOCAL_ONLY-    # back to OAuth
  kubectl -n stardelt set env deploy/airflow-api-server STARDELT_AUTH_LOCAL_ONLY=1
  ```

  The same values files keep `AUTH_TYPE = AUTH_DB` when `stardelt-identity` is absent, so an
  install without `make install-identity` behaves exactly as before.

Rotating the session secret logs everyone out: delete the Secret and re-run the installer
(the chart regenerates it and keeps it across upgrades — `helm.sh/resource-policy: keep`).

The realm import (`chart/files/keycloak-realm.json`, shared by both paths) defines group
`stardelt-admins` (with the `realm-management` user-management roles), user `admin` in it, a
`groups` claim (group names, full path off) and these clients:

| Client | Type | Redirect URI |
|---|---|---|
| `nova` | confidential, code + PKCE | `https://<baseDomain>/api/auth/callback` |
| `trino` | confidential, code, device grant (no PKCE: Trino 480 never sends a challenge) | `https://trino.<baseDomain>/oauth2/callback`, and `https://localhost:8443/oauth2/callback` for the administrators' port-forward to the engine UI |
| `lakekeeper` | confidential | `https://lakekeeper.<baseDomain>/ui/*` |
| `superset` | confidential | `https://superset.<baseDomain>/oauth-authorized/keycloak` |
| `airflow` | confidential | `https://airflow.<baseDomain>/auth/oauth-authorized/keycloak` |
| `jupyterhub` | confidential | `https://jupyter.<baseDomain>/hub/oauth_callback` |

Trino only accepts tokens whose audience contains `trino`, so the `nova` and `jupyterhub` clients
carry an `aud-trino` audience mapper; `jupyterhub` also gets `access.token.lifespan=28800`
(8 hours) because a spawned notebook keeps its token in the pod environment for a whole session
(Nova refreshes its own token and keeps the realm default). On a fresh realm the import applies
both; `scripts/keycloak-sync-trino-client.sh` applies them to a running one. The same
fresh-only rule covers `fullScopeAllowed: false` on the six clients: existing installs must
either flip the "Full scope allowed" switch off per client in the admin console or recreate
realm `stardelt`, otherwise the realm file change never reaches the running realm.

**No committed credentials.** On first install the Keycloak bootstrap-admin password, the realm
`admin` password and the six client secrets are generated (`openssl rand` in
`scripts/identity-bootstrap.sh`; `randAlphaNum` + `lookup` in the chart) into the Secrets
`keycloak-admin`, `stardelt-realm-admin` and `stardelt-oidc-clients` (one key per client). They are
never printed, the realm ConfigMap only holds `${ENV}` placeholders, and re-runs keep existing
values. `make uninstall` (and `helm uninstall`) leave the Secrets in place. The realm is imported
only when it does not exist yet, so later edits to the realm file are not applied to a running
realm — and a regenerated Secret is not either, which is what the sync/verify pair in
[The client secrets are the source of truth too](#the-client-secrets-are-the-source-of-truth-too)
repairs.

### The realm-admin Secret is the source of truth

The documented way into realm `stardelt` is the generated Secret:

```sh
kubectl -n stardelt get secret stardelt-realm-admin -o jsonpath='{.data.password}' | base64 -d
```

Sign in with it at the realm's admin console — also linked from Nova's **Users** item
under *Platform*, visible to platform admins only:

```text
https://id.<baseDomain>/admin/stardelt/console/
```

Only realm `stardelt` is published (#53, reopened narrowly for this console): the master
realm, `/admin/master/console/` and `/realms/master` stay 404. `make sync-realm-user-management`
grants `stardelt-admins` the roles the Users page needs on a **live** realm (the import only runs
when the realm is created) and enforces the realm's brute-force protection; see
[Managing users](#managing-users).

`--import-realm` substitutes `${STARDELT_REALM_ADMIN_PASSWORD}` **once**, on the first start that
creates the realm, and never looks at it again. Regenerating the Secret — deleting it to rotate, or
re-running `scripts/identity-bootstrap.sh` after a re-provision — therefore used to leave the realm
on the old password: the command above failed with **"Invalid username or password"** while
`analyst` and every app sign-in stayed healthy (#81). The installer now heals that drift instead of
leaving it for a failed login to reveal:

```sh
make sync-realm-admin     # re-apply the Secret's current value through the master-realm API
make verify-realm-admin   # real password grant as the realm admin, from inside the cluster
```

`make install-identity` runs both after Keycloak is up (and `make chart-install` does whenever the
release ships Keycloak), so the Secret wins on every install and rotation is a supported operation:
change `stardelt-realm-admin` (or delete it and re-run `scripts/identity-bootstrap.sh`), then run
`make sync-realm-admin` — or just re-run the installer. `sync-realm-admin` is idempotent: it probes
the existing password first and does nothing when the Secret already works. The probe and
`verify-realm-admin` both use client `admin-cli`, Keycloak's per-realm default that allows direct
access grants (the app clients genuinely need them off), and reach Keycloak through `svc/keycloak`
— never the public `id.` host. Neither script prints a secret.

### The client secrets are the source of truth too

Secret `stardelt-oidc-clients` holds one secret per confidential client (`nova`, `superset`,
`airflow`, `jupyterhub`, `trino`); the apps read it (`nova` and `jupyterhub` via environment,
Superset and Airflow through their Helm values). The realm import substitutes
`${STARDELT_<CLIENT>_CLIENT_SECRET}` **once**, when it creates realm `stardelt` — so regenerating the
Secret used to leave the clients on the imported values, and **sign-in failed for every app at once
while each `/health` returned 200** — that is what happened live on 2026-10-18, when a re-run of the
identity bootstrap regenerated the Secret while Keycloak kept the imported values (#85). The
installer now re-applies the Secret instead of leaving the drift for a failed login to reveal:

```sh
make sync-oidc-clients     # re-apply each client's current Secret value through the admin API
make verify-oidc-clients   # prove every one of them against the token endpoint, in-cluster
```

`make install-identity` runs `sync-oidc-clients` (the four app clients), then
`keycloak-sync-trino-client.sh` (which owns the `trino` client and its token settings), then
`verify-oidc-clients` (all five); `make chart-install` runs `sync-oidc-clients` and
`verify-oidc-clients` whenever the release ships Keycloak, next to the realm-admin pair.
`sync-oidc-clients` delegates `trino` to `keycloak-sync-trino-client.sh` rather than duplicating
it; `SYNC_TRINO=0` skips that delegation.

Rotation is a supported operation: change a value in `stardelt-oidc-clients` (or delete the Secret
and re-run `scripts/identity-bootstrap.sh`), then run `make sync-oidc-clients` — or just re-run the
installer. The sync is idempotent: it asks the token endpoint first and writes nothing when the
Secret's value already authenticates; a value it does write is read back from the admin API and
probed again before the script reports `updated`. The verify check is browser-independent — a
client-credentials token request with a bogus authorization code, which Keycloak answers
`invalid_grant` for the right secret and `unauthorized_client` for a wrong one — so it names the
offending client and prints the fix instead of waiting for a user to hit the login page.
`verify-oidc-clients` fails when a client is missing from the realm as well; `sync-oidc-clients`
then stops instead of creating a half-configured client (creation belongs to the realm import and
`keycloak-sync-trino-client.sh`). Like the realm-admin pair, both reach Keycloak through
`svc/keycloak` and never print a secret value.

### Managing users

Platform admins manage people in the Keycloak admin console for realm `stardelt`, not in a Nova
screen of its own. Nova's **Users** item (Platform group, administrators only) opens
`https://id.<baseDomain>/admin/stardelt/console/` in a new tab; the backend derives that URL
from `NOVA_OIDC_ISSUER` (`…/realms/<realm>` → `/admin/<realm>/console/`) and returns it as
`admin_console_url` on `/api/me`, so no host is hard-coded in the frontend and any
Keycloak-compatible issuer works. `admin_console_url` is `null` in `dev` mode, for a non-Keycloak
issuer, and for the master realm — Nova never links to a console it cannot address.

What makes the console usable is a narrow grant. Group `stardelt-admins` holds four
`realm-management` client roles — `view-users`, `query-users`, `query-groups`, `manage-users` —
and nothing else: members manage users, non-members get `403` from the admin API. It deliberately
does **not** hold `realm-admin`, `manage-clients` or `manage-realm`; those are realm ownership,
not user management. The same grant is in the realm import and applied to a live realm by an
idempotent script, because `--import-realm` skips an existing realm:

```sh
make sync-realm-user-management   # roles above + brute-force thresholds; prints what it read back
```

The script also sets `bruteForceProtected` with explicit thresholds (ten failures, 60 s increments,
15 min maximum wait, 12 h window) — the console login is internet-facing. Both install paths run
it: `make install-identity` after the realm-admin guard, and `make chart-install` whenever the
release ships Keycloak.

The `id.` Ingress publishes exactly the realm console and its API, as
ingress-nginx regexes: `/admin/stardelt(/|$)` (the console app) and
`/admin/realms/stardelt(/|$)` (the REST calls the console makes), plus the realm's existing
`/realms/stardelt`, `/resources` and `/robots.txt`. The `(/|$)` group keeps each match on its
exact path segment (Kubernetes requires the path to start with `/`, so a leading `^` cannot be
written), so `/admin/master/console/`, `/realms/master` and `/admin/realms/master/...` stay
`404`. The umbrella chart carries the same list in `chart/templates/ingress.yaml`.

If a future Keycloak version needs another endpoint for the console (an extra `/admin/...` call),
add the narrowest regex path — never `/admin`.

Sizing (single node): Keycloak 100m / 512Mi request, 1 CPU / 1Gi limit, one replica,
`KC_CACHE=local`; its Postgres 50m / 128Mi request, 256Mi limit, 1Gi volume. The Keycloak image is
pinned as `KEYCLOAK_VERSION` in the Makefile and mirrored in `manifests/keycloak.yaml` and
`identity.keycloak.image.tag`; `scripts/check-version-parity.sh` checks all three and Renovate
updates them together. Behind ingress-nginx, raise `proxy-buffer-size` for the `id.` host (the
playground Ingress sets `16k`; for the chart pass it through `ingress.annotations`), since Keycloak's
login responses outgrow nginx's default 4k header buffer.

---

## Spark — heavy compute on the same Iceberg tables

Spark is the heavy-compute plug of the master spec (§5 #14): a **Spark Connect**
endpoint in the cluster, wired to the same `warehouse` catalog as Trino. A table
written by one engine is a table of the other — no copy, no second catalog, no
second credential store for table data.

```sh
make install-spark     # manifests/spark.yaml: Deployment + Service + ConfigMap + RBAC
```

Endpoint (ClusterIP only — there is deliberately no Ingress):

```text
sc://spark-connect.stardelt.svc.cluster.local:15002
```

From a notebook or a scheduled job (PySpark Connect client,
`pip install pyspark-client==4.1.3`), the catalog is the server-side default:

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.remote(
    "sc://spark-connect.stardelt.svc.cluster.local:15002"
).getOrCreate()

spark.sql("SELECT borough, count(*) AS n FROM warehouse.demo.trips GROUP BY borough ORDER BY n DESC").show()
spark.sql("SELECT * FROM warehouse.demo.trips").count()
```

The quickstart notebook in the single-user image runs exactly that — it reads
`warehouse.demo.trips` through Spark and prints the row count, so one click in Nova's Notebooks
page proves the second engine as well as the first.

Notebook pods reach the endpoint because the JupyterHub chart's singleuser NetworkPolicy carries
one egress rule for it (`helm-values/jupyterhub.yaml`): `podSelector:
app.kubernetes.io/name=spark-connect`, port 15002. The chart default denies **all** private
addresses, and the one-line alternative (`egressAllowRules.privateIPs: true`) would have opened
Trino, Lakekeeper, S3 and the Kubernetes API to every user pod for the same feature — the narrow
rule is the point (stardelt-platform#90). Spark pods are not part of the umbrella chart; when
they are absent the rule matches nothing.

The image is `ghcr.io/stardelt/spark` (`images/spark/Dockerfile`): Apache Spark 4.1.3
plus the Iceberg 1.12 runtime and AWS bundle. The jars are baked in at image build
time (checksum-verified from Maven Central), so a pod never downloads dependencies —
the install stays air-gap-friendly when the registry is mirrored.

### Shape and the memory budget

One Deployment runs the Connect server as a long-running driver with **Kubernetes as
the cluster manager**. Executors are pods the driver creates on demand and releases
when a query finishes (`spark.dynamicAllocation`, shuffle tracking — no shuffle
service), so an idle platform pays for the driver only:

| Part | Request | Limit | Steady state |
|------|---------|-------|--------------|
| Driver (`spark-connect`) | 250m / 1 GiB | 1 CPU / 2 GiB | ~0.5 GiB measured |
| Executor, each (max 2) | 1 CPU / 1.4 GiB | JVM heap `1g` + `384m` overhead | 0.6–1.4 GiB, only while querying |

On the shared 16 GB dev node the driver measured 529 MiB and the node stayed at
~64–69 % with an executor running, well inside the headroom left by Trino,
Airflow, Superset and JupyterHub. Executors are released after
`shuffleTracking.timeout` (180 s) plus the idle timeout, so a query leaves the
node as it was a few minutes later.
Change the numbers in `manifests/spark.yaml` (ConfigMap `spark-connect-config` +
the driver's `resources`) and re-run `make install-spark`; the target restarts the
driver only when the ConfigMap actually changed.

### Catalog wiring

The `spark-defaults.conf` keys mirror `helm-values/trino.yaml`, property for property:

| Spark | Trino | Value |
|---|---|---|
| `spark.sql.catalog.warehouse.type` | `iceberg.catalog.type` | `rest` |
| `spark.sql.catalog.warehouse.uri` | `iceberg.rest-catalog.uri` | `http://lakekeeper.stardelt.svc.cluster.local:8181/catalog` |
| `spark.sql.catalog.warehouse.warehouse` | `iceberg.rest-catalog.warehouse` | `warehouse` |
| `spark.sql.catalog.warehouse.s3.endpoint` | `s3.endpoint` | `http://seaweedfs-s3.stardelt.svc.cluster.local:8333` |
| `spark.sql.catalog.warehouse.s3.path-style-access` | `s3.path-style-access` | `true` |

Lakekeeper runs without vended credentials, so both engines sign their own S3
requests. Spark gets the credentials from Secret `stardelt-s3-creds` through
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` on the driver and through
`spark.kubernetes.executor.secretKeyRef.*` on every executor; nothing is written
into a config file.

### Catalog network access (interim)

Lakekeeper has no authentication yet (`authz.backend: allowall`), so the network is the
only control on who may read or change table metadata. `make install` and
`make install-core` apply `manifests/lakekeeper-network-policy.yaml`
(`NetworkPolicy lakekeeper-ingress`): only the Trino coordinator, Nova, the Spark Connect
driver, Airflow task pods and the Lakekeeper bootstrap Job may open TCP 8181. Trino
workers read Parquet from S3 and Spark executors read data files, so neither calls the
catalog; the JupyterHub single-user egress policy already denies it. The policy is
ingress-only — it does not touch what Lakekeeper reaches (Postgres, S3) — and it has no
namespace-wide or CIDR rule. Kubelet probes come from the node, so the pod stays Ready.

It needs a CNI that enforces NetworkPolicy: k3s does (the JupyterHub policies already
rely on its controller), while plain Flannel does not. To remove the interim restriction,
e.g. while debugging the catalog:

```sh
kubectl delete networkpolicy lakekeeper-ingress -n stardelt
```

Re-apply it with `kubectl apply -f manifests/lakekeeper-network-policy.yaml`; `make
uninstall` removes it. A new consumer of the catalog needs its own `podSelector` entry —
do not widen the policy with a namespace selector.

### Verifying the spine

`scripts/verify-spark-iceberg.py` is the repeatable proof: it compares `count(*)`
and a `GROUP BY` on `warehouse.demo.trips` between Spark and Trino, then runs a
two-way round trip — Trino writes a table Spark reads, Spark writes a table Trino
reads — in a scratch namespace it drops again. Run it from any pod that can reach
both services:

```sh
kubectl -n stardelt run spark-verify --image=python:3.11-slim --restart=Never --command -- sleep infinity
kubectl -n stardelt exec spark-verify -- pip install pyspark-client==4.1.3
kubectl -n stardelt cp scripts/verify-spark-iceberg.py spark-verify:/tmp/verify.py
kubectl -n stardelt exec spark-verify -- python3 /tmp/verify.py
kubectl -n stardelt delete pod spark-verify
```

### Why a Deployment, not the Spark Kubernetes Operator

The Apache Spark Kubernetes Operator is the right controller once several Spark
applications share a cluster, and it is where the stardelt operator's
`Workspace`/`Pipeline` reconciliation will point. For one long-running app on one
node it is not: its controller alone requests 2 GiB by default, permanently, and
adds CRDs and a webhook to operate a single endpoint Kubernetes can already run.
The CRD path is the follow-up, not a reason to make this node heavier today.

### Limits

Spark Connect has no built-in authentication (upstream points at authenticating
proxies). The endpoint is therefore ClusterIP-only: anyone who can create pods in
`stardelt` can query through it, exactly like the current Lakekeeper `allowall`
catalog. Wiring Connect behind the platform IdP is a follow-up with the CRD work,
not something to expose on an Ingress before then.

If the driver is killed hard, its executor pods can outlive it. They are labelled
and safe to delete:

```sh
kubectl -n stardelt delete pods -l spark-role=executor
```

---

## Makefile targets

| Target | Description |
|--------|-------------|
| `help` | List all targets with descriptions |
| `deps` | Run `scripts/check-deps.sh` to verify CLI tools |
| `lint` | `bash -n` + ShellCheck every script under `scripts/` and `dev/` (ShellCheck only if installed) |
| `install` | Add helm repos, deploy the full stack (11 steps; generates the Airflow/Superset Secrets first) |
| `install-core` | Core only (storage + catalog + query + Nova) — fits a small node; `SLIM=1` for 8 GB |
| `verify-backup-config` | Post-apply guard (also run by both install targets): the live `lakekeeper-pg` Cluster must still declare `spec.backup`, or the command fails loudly |
| `verify-backups-nova` | Same full WAL check for `nova-pg` (`s3://backups/nova-pg/wals/`) |
| `verify-backups` | Full WAL check: `spec.backup` + the newest object in `s3://backups/lakekeeper-pg/wals/` is younger than `MAX_AGE_SECONDS` (900) + it matches `pg_stat_archiver.last_archived_wal`. `SKIP_OBJECTS=1` skips the S3 half |
| `verify-backups-identity` | Same full WAL check for `keycloak-pg` (`s3://backups/keycloak-pg/wals/`) |
| `install-notebooks` | JupyterHub (notebooks) |
| `install-spark` | Spark Connect endpoint (`manifests/spark.yaml`), wired to the same Lakekeeper catalog as Trino; restarts the driver only when its ConfigMap changed |
| `install-identity` | Platform IdP: Keycloak + CNPG Postgres + realm `stardelt`, then the realm-admin sync + guard, the user-management roles/brute-force sync, the client-secret sync + guard, the live-realm Trino client and the Trino OAuth2 overlay (`BASE_DOMAIN=…`, see [Identity](#identity-optional-platform-idp)) |
| `sync-realm-admin` | Point realm `stardelt`'s `admin` at Secret `stardelt-realm-admin` through the master-realm API; idempotent, runs as part of `install-identity`/`chart-install` (#81) |
| `verify-realm-admin` | Prove the realm-admin Secret still signs in — a real password grant as that user through `svc/keycloak`; fails with the fix in the message |
| `sync-realm-user-management` | Grant `stardelt-admins` the four `realm-management` user-management roles and enforce brute-force protection on the live realm; idempotent, runs with both install paths |
| `sync-oidc-clients` | Point the realm's confidential clients (`nova`, `superset`, `airflow`, `jupyterhub`; delegates `trino`) at Secret `stardelt-oidc-clients`; probe-first, idempotent, never prints a value (#85) |
| `verify-oidc-clients` | Prove every client secret still authenticates at the token endpoint (`invalid_grant` vs `unauthorized_client`) and matches what the realm stores; names the drifting clients and the fix |
| `sync-catalog-clients` | Create/converge the five catalog-caller service clients (`svc-catalog-*`) and their Secrets, audience `lakekeeper`, no group; idempotent (#282) |
| `delete-catalog-clients` | Delete those five clients and Secrets; only `stardelt-managed=service` clients, needs `YES=1` |
| `trino` | Install/upgrade Trino; adds `helm-values/trino-identity.yaml` (Keycloak OAuth2 + service-account password) when `stardelt-identity` exists |
| `sync-trino-groups` | Sync the live realm's `stardelt-admins` membership into ConfigMap `trino-group-file` (Trino query visibility); idempotent, runs inside `make trino` (#125) |
| `install-operator` | Install the stardelt Operator from `../stardelt-operator/chart` (dev path) |
| `pin` | Pin a deployment to the newest published digest **and write it back into the manifest** (`make pin APP=nova`, `APP=spark DEPLOY=spark-connect`), so a later `kubectl apply` cannot put the mutable tag back |
| `pin-images` | Pin Nova, the operator and Spark to their digests (the install targets do this themselves) |
| `upgrade` | Re-run `install` (helm upgrade is idempotent) |
| `uninstall` | Remove all helm releases and manifests in reverse order |
| `chart-deps` | `helm dependency update chart` — fetch/refresh the umbrella chart's sub-charts |
| `chart-template` | Render the umbrella chart (`helm template stardelt chart -n <ns>`) |
| `chart-install` | Install/upgrade the umbrella chart as release `stardelt` (see [Helm chart](#helm-chart-baseline)) |
| `build-superset-image` | Build `ghcr.io/stardelt/superset:dev` locally |
| `push-superset-image` | Push that image to ghcr.io |
| `build-jupyter-image` | Build `ghcr.io/stardelt/jupyter-singleuser:dev` locally |
| `push-jupyter-image` | Push that image to ghcr.io |
| `pf` | Open port-forwards to Nova, Trino, Lakekeeper, Superset |
| `dev-up` / `dev-down` | Create / delete the Hetzner k3s development cluster |
| `dev-dns` / `dev-dns-down` | Point / remove the playground DNS records |

---

## Repository layout

```
chart/                Umbrella Helm chart (see "Helm chart (baseline)")
  Chart.yaml            Dependencies + conditions; versions mirror the Makefile pins
  values.yaml           Per-sub-chart values, mirrored from helm-values/
  values-slim.yaml      Small-node Trino overrides (mirrors helm-values/slim/)
  templates/            Nova, CNPG Cluster + ScheduledBackup, S3 Secret, Lakekeeper bootstrap Job, Keycloak/identity
  files/                keycloak-realm.json — realm import shared with make install-identity
  charts/               Sub-charts, fetched by `make chart-deps` (not committed)

helm-values/          Helm values files, one per chart
  airflow.yaml          Apache Airflow 3.x (KubernetesExecutor)
  jupyterhub.yaml       JupyterHub multi-user notebooks
  lakekeeper.yaml       Lakekeeper Iceberg REST catalog
  seaweedfs.yaml        SeaweedFS S3-compatible storage
  superset.yaml         Apache Superset BI
  trino.yaml            Trino MPP SQL engine
  slim/                 Small-node overrides (see `SLIM=1`)

manifests/            Plain Kubernetes manifests (kubectl apply)
  cnpg-postgres.yaml    CloudNative-PG Cluster for Lakekeeper metadata
  keycloak.yaml         Platform IdP: Keycloak + its CNPG Cluster (make install-identity)
  lakekeeper-bootstrap.yaml  Job: accept ToS + create default warehouse
  nova-deployment.yaml  stardelt Nova UI + backend
  spark.yaml            Spark Connect endpoint + Spark configuration (make install-spark)
  s3-credentials.example.yaml  Template for the stardelt-s3-creds Secret

images/
  spark/Dockerfile      Spark 4.1.3 + Iceberg 1.12 runtime + AWS bundle
  superset/Dockerfile   Superset 5.0.0 + psycopg2 + trino driver
  jupyter/Dockerfile    scipy-notebook + trino, pyspark, pandas, pyarrow
  jupyter/notebooks/    warehouse-quickstart.ipynb (seeded into each user's home)

scripts/
  app-secrets.sh        Generate the Airflow/Superset Secrets (idempotent, never printed)
  check-deps.sh         Verify required CLI tools
  identity-bootstrap.sh Generate the IdP Secrets + render realm/identity ConfigMaps
  keycloak-sync-trino-client.sh  Sync the live realm's Trino token settings (import skips an existing realm)
  lint.sh               bash -n + ShellCheck the shell scripts (make lint)
  port-forwards.sh      Background port-forwards to all services
  protect-branches.sh   Apply `main` branch protection in all five stardelt repos
  superset-probe.py     Run `SELECT current_user` through Superset's own stored connection (verify-trino-auth 4/4)
  sync-realm-admin.sh   Re-apply Secret stardelt-realm-admin to the live realm's admin (import skips an existing realm)
  sync-realm-user-management.sh  Grant stardelt-admins the user-management roles + enforce brute force on the live realm
  sync-oidc-clients.sh  Re-apply Secret stardelt-oidc-clients to the live realm's clients (import skips an existing realm; trino delegated)
  sync-trino-groups.sh  Write the live realm's stardelt-admins membership into ConfigMap trino-group-file (Trino query visibility, #125)
  verify-backups.sh     Backup guards: post-apply spec.backup assert + bucket-vs-database WAL check
  verify-notebook-identity.py  Headless hub login + run the quickstart in the pod (positive and 401 negative)
  verify-oidc-clients.sh Assert every client secret in Secret stardelt-oidc-clients authenticates at the token endpoint
  verify-realm-admin.sh Assert the realm-admin Secret still signs in to realm `stardelt`
  verify-trino-auth.sh  Assert Trino refuses anonymous SQL, accepts user tokens + the service account, and Superset's stored connection works
  helm-plugins/
    stardelt-dedupe/    Helm v4 post-renderer: deduplicates env lists
```

---

## Branch protection

`main` is protected in every stardelt repo (`stardelt-docs`, `stardelt-platform`, `stardelt-nova`,
`stardelt-operator`, `stardelt-demos`) by [`scripts/protect-branches.sh`](scripts/protect-branches.sh)
(`bash scripts/protect-branches.sh`, `--dry-run` to preview). Each repo requires the CI job names its
pull requests report — validated against checks actually seen on recent PRs, because a wrong name would
silently block every merge — plus no force pushes, no deletions and linear history. Pull requests are
required but no approvals: the maintainer and AI agents merge under one owner account, so CI is the gate;
`enforce_admins` stays off for emergencies. Re-run it after a workflow job name changes.
Collaboration/release branches are planned later (issue #38).

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
| Apache Spark (image, no chart) | — | 4.1.3 (Iceberg 1.12.0) |
| Keycloak (image, no chart) | — | 26.8.1 |

---

## Version pins

Chart and application versions are pinned in the root [`Makefile`](Makefile) — one
`<COMPONENT>_VERSION := x.y.z` line per chart. Every Makefile install path
(`make install`, `make install-core`) reads the pin from there, so that file is the
source of truth for what gets deployed and a version bump is a one-line change.

The umbrella chart needs the same numbers again as literal `dependencies[].version`
entries in [`chart/Chart.yaml`](chart/Chart.yaml) (Helm cannot read a Make variable).
Renovate reads that file natively and the `helm charts` group below covers it, so a
bump normally arrives as one PR touching both files.

Dependencies are kept current by [Renovate](https://docs.renovatebot.com/), configured in
[`renovate.json`](renovate.json). It opens grouped pull requests for:

- the `*_VERSION` chart pins in the `Makefile` (read as Helm chart versions — see the
  per-pin comments in `renovate.json` for why each one uses the `helm` datasource),
- the `dependencies` in `chart/Chart.yaml` (Helm datasource, same group),
- the base images in `images/**/Dockerfile`,
- the action versions in `.github/workflows/**`,

on a weekly schedule. Renovate keeps the versions exact (`rangeStrategy: pin`); major chart
bumps are held back until they are approved on the Dependency Dashboard, since a chart major
is what usually breaks a values file. Upgrading a component is therefore normally a review of
a Renovate PR rather than a manual edit.

Note that the table above and the `--version` flags in `.github/workflows/ci.yml` are still
hand-maintained copies of the `Makefile` pins — keep them in sync when reviewing a chart bump.

One pin Renovate does not own: `ICEBERG_VERSION` in `images/spark/Dockerfile`. The Iceberg
runtime is matched to the Spark minor (`iceberg-spark-runtime-4.1_2.13`), so a Spark
major/minor bump is a deliberate edit of the base image and the runtime together.

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

`manifests/nova-deployment.yaml` uses `ghcr.io/stardelt/nova:dev` with
`imagePullPolicy: Always`, and pulls through the `ghcr-creds` secret.

### Superset image

The Superset image adds `psycopg2-binary` and the `trino` SQLAlchemy driver to the
upstream Superset 5.0.0 base. **CI builds it** — the `Image` workflow in this repo
publishes `ghcr.io/stardelt/superset:dev` (plus `sha-<short>`) on merge to `main`, and
`helm-values/superset.yaml` points at it with the `ghcr-creds` pull secret. A local
`make build-superset-image` + `make push-superset-image` is only for iteration.

### Jupyter single-user image

`images/jupyter/Dockerfile` adds `trino`, `pyspark[connect]`, `pandas` and `pyarrow` to
`quay.io/jupyter/scipy-notebook` and ships `warehouse-quickstart.ipynb`. Same workflow:
CI publishes `ghcr.io/stardelt/jupyter-singleuser:dev` on merge to `main`, and
`helm-values/jupyterhub.yaml` points `singleuser.image` at it with the `ghcr-creds`
pull secret; `make build-jupyter-image` + `make push-jupyter-image` are for local
iteration. It never carries credentials — the user's token is copied into the pod at
spawn (see [Notebooks](#notebooks-the-users-own-identity-inside-the-pod)).

---

## Container images

stardelt images live under `ghcr.io/stardelt/*` and are built by CI, not by the
cluster: merge to `main` publishes `dev` and an immutable `sha-<short>` tag, and the
job summary prints the digest. **Pin deployments by digest** — a moving tag may keep
serving a cached layer.

`nova` is public; `operator`, `superset`, `jupyter-singleuser` and `spark` are internal/private until
someone flips them in the package settings (the API refuses), so the cluster needs a pull
secret named `ghcr-creds` in the namespace:

```sh
./dev/ghcr-pull-secret.sh          # uses your `gh auth token`
GHCR_TOKEN=<read:packages PAT> ./dev/ghcr-pull-secret.sh   # preferred
```

The secret lives in the cluster, so give it a token that can only read packages
(`GHCR_TOKEN`) rather than your full `gh` login token. It acts on the current kube-context
(or `KUBE_CONTEXT`) and prints it first.

Alternatively, make the packages public in the GitHub package settings and drop the
`imagePullSecrets` entry. `nova:dev` is a mutable tag — pin by digest for reproducible installs.

## Uninstalling

```sh
make uninstall
```

This removes helm releases in reverse dependency order and deletes the manifests. PVCs
are intentionally left in place; delete them manually if you want to reclaim storage:

```sh
kubectl delete pvc --all -n stardelt
```
