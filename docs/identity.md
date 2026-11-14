# Identity (optional platform IdP)

Part of the [stardelt-platform](../README.md) manual.

stardelt has two identity modes (contract: `docs/architecture/identity` in stardelt-docs):
an **external** OIDC provider (Entra ID, Okta, a corporate Keycloak) or the **platform** IdP,
Keycloak, that every building block authenticates against. Either way the platform publishes
the same ConfigMap, `stardelt-identity`, with `issuerUrl`, `tokenEndpoint`, `groupClaim`
(`groups`) and `adminGroup` (`stardelt-admins`). The platforms' own installer adds `authMode`,
`publicUrl` and `trinoUrl` (the coordinator's in-cluster TLS endpoint, which exists under exactly
the same condition — see "TLS on the coordinator"). `tokenEndpoint` is the provider's OAuth2
client-credentials endpoint, resolved once here so no component builds the realm path itself:
`platform` derives it from the Keycloak this platform deploys, `external` takes it from
`identity.tokenEndpoint` (the `token_endpoint` of `<issuerUrl>/.well-known/openid-configuration`).

| Umbrella chart | Makefile | What is deployed |
|---|---|---|
| `identity.mode: none` (default) | — | nothing |
| `identity.mode: platform` | `make install-identity` | Keycloak (official `quay.io/keycloak/keycloak`, Apache-2.0) + its own CNPG Cluster `keycloak-pg`, realm `stardelt`; Ingress `id.<baseDomain>` when `ingress.enabled` (playground: `dev/playground/ingress.yaml`) |
| `identity.mode: external` + `identity.issuerUrl` + `identity.tokenEndpoint` | — | only `stardelt-identity` (render fails without an https issuer and token endpoint) |

```sh
make install-core SLIM=1                                    # CNPG operator first
make install-identity BASE_DOMAIN=alpha.dev.stardelt.io     # Keycloak at https://id.<BASE_DOMAIN>
# or: make chart-install CHART_EXTRA="--set identity.mode=platform --set platform.baseDomain=example.com"
```

## Embedding JupyterHub in Nova

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

## Notebooks: the user's own identity, inside the pod

Spawning a server is more than starting JupyterLab: the single-user pod gets the user's workspace
and, with it, a way to query the warehouse **as themselves**.

* **Image.** `helm-values/jupyterhub.yaml` points the single-user pods at
  `ghcr.io/stardelt/jupyter-singleuser:dev` (built by the `Image` workflow from
  `images/jupyter/Dockerfile`): `scipy-notebook` plus the `trino` Python client,
  `pyspark-client`, `pandas` and `pyarrow`, the git extensions `jupyterlab-git`
  and `nbgitpuller` (both BSD-3-Clause), `stardelt-jupyterlab` (the stardelt Graphite and
  Silver themes, Graphite the default, plus a top bar with the link back to Nova, the user and
  the runtime), and the `warehouse-quickstart` notebook under
  `/opt/stardelt/notebooks/` — it queries the catalog the account may write to (`shared` for a
  member, `playground` in the public demo) and never drops a table. `jupyterlab-sql` is
  deliberately absent — its last release predates JupyterLab 4 and it cannot carry the per-user
  token. The package is private, like Superset, so
  the pod pulls with the `ghcr-creds` secret.
* **The helper (`import stardelt`).** The notebook helper lives in its own repository,
  [`stardelt/stardelt-python`](https://github.com/stardelt/stardelt-python) (MIT): the `stardelt`
  package (`sql`, `write_df`, `spark`, `spark_tips`, `connection`), its tests and its releases.
  The image installs **one pinned release** of it, not a vendored copy. The pin lives in the
  `Makefile` — `STARDELT_LIB_REF` (the commit) and `STARDELT_LIB_TAG` (the release it belongs to,
  `v0.1.0`) — and the Dockerfile installs that commit as a build arg. It is pinned by **commit
  SHA, not by tag**: a moving tag is not an upgrade path, the same rule the image pins follow
  (`scripts/pin-image.sh`). `scripts/check-stardelt-pin.sh` (run by `make lint`, and therefore by
  CI) fails the build when the Dockerfile's pin and the Makefile's disagree, when the pin is not a
  full SHA, or when the Dockerfile stops installing that pin. To bump it: change both places
  (the Makefile and the `ARG` default in `images/jupyter/Dockerfile`), merge, and pin the new
  image digest as described under [Jupyter single-user image](development.md#jupyter-single-user-image).
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
  `SELECT current_user` equals the hub user, lists schemas and queries
  `warehouse.covid.covid_summary`.
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
* **Spark.** The quickstart's Spark cell reads `warehouse.covid.covid_summary` through Spark
  Connect with the person's token and the catalogs Trino lists for them (platform#317). Spark is
  optional (`make install-spark`); the cell reports what it found when the endpoint is absent. The singleuser NetworkPolicy grants egress to exactly
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
hub headlessly (with `auto_login` that signs-in already starts a spawn, which the script waits
for instead of interrupting; only a server that was running before sign-in is restarted), runs
the quickstart inside the pod and then runs it again with `TRINO_TOKEN` and the hub's
`JUPYTERHUB_API_TOKEN` unset to prove the 401 — with either one present the library re-mints the
token from the person's `auth_state`.

```sh
HUB_URL=https://jupyter.alpha.dev.stardelt.io NOTEBOOK_USER=analyst NOTEBOOK_PASSWORD=... \
  python3 scripts/verify-notebook-identity.py
```

## Trino: the query engine behind the identity

Trino is the one building block whose authentication state is derived from the platform:
`make trino` (and therefore `make install`, `install-core` and `install-identity`) applies
`helm-values/trino-identity.yaml` **when the `stardelt-identity` ConfigMap exists**, and the
plain development default when it does not.

| Property (`helm-values/trino-identity.yaml`) | Effect |
|---|---|
| `http-server.authentication.type=PASSWORD,OAUTH2` | every statement needs credentials; anonymous `POST /v1/statement` answers `401` with no query id |
| `web-ui.authentication.type=oauth2` | the Trino web UI redirects to Keycloak; `<trino host>/oauth2/callback` is the registered redirect |
| `http-server.authentication.oauth2.issuer` / `client-id=trino` / `client-secret` | validates the caller's **own** Keycloak access token and sets `current_user` to its `sub` (the Keycloak user id — `principal-field`, platform#311) |
| `…oidc.use-userinfo-endpoint=false` | local JWT validation against the realm JWKS, so the `aud` claim is enforced |
| `server.config.https` (port 8443, PKCS12 keystore mounted from Secret `trino-coordinator-tls`) | the in-cluster TLS listener; clients carry the user's bearer token to it (`manifests/trino-tls.yaml`) |
| `http-server.authentication.allow-insecure-over-http=false` | a plain-HTTP statement is refused (403, no query id) **before** any authenticator runs, so the insecure authenticator — the one that trusts `X-Trino-User` — is unreachable |
| `http-server.process-forwarded=true` | the ingress still terminates Let's Encrypt TLS and forwards HTTP to 8080 with `X-Forwarded-Proto`, which Trino treats as secure; the public path is unchanged |
| `internal-communication.shared-secret=${ENV:…}` | required as soon as an authenticator is enabled |
| `accessControl` (file `rules.json`: `catalogs`, `queries`, `tables`, `impersonation`) | query visibility is owner-only: each user sees and kills only their own queries, members of `stardelt-admins` see and kill all (viewing/killing one's own needs no rule — it is built-in). The `catalogs` rules (platform#363) reserve `system`, `tpch` and `tpcds` for administrators: a non-administrator's `SHOW CATALOGS` no longer lists them and a statement against one is refused by the engine (`Access Denied: Cannot access catalog …`); the last rule grants `all` to every other catalog, which is Trino's own default (the bridge and Lakekeeper decide those). The `tables` rules deny everyone but `stardelt-admins` the cluster-wide `system.runtime.tasks`, `.transactions` and `.optimizer_rule_stats` (`tasks` lists other users' queries), so even an administrator-only `system` catalog keeps its worst tables out of reach of a non-admin (platform#181). `system.runtime.queries` and `.nodes` are inside that administrator-only catalog now |
| `coordinatorExtraConfig: access-control.config-files` + `coordinator.additionalConfigFiles` (`access-control-opa.properties`) | the second access control, platform#311: Trino also asks the catalog's OPA bridge (`lakekeeper-opa:8282`) before every catalog/schema/table/column operation, so the `Catalog` grants decide who reads what — see "Who may read what" below. Both systems have to allow a statement; the bridge therefore only ever removes access. Fail-closed: an unreachable bridge denies every statement |
| `coordinator.additionalConfigFiles` (`group-provider.properties`) + `trino-groups` volume | the file group provider reads ConfigMap `trino-group-file` (written by CronJob `access-sync`, never committed): the `stardelt-admins` line the query rules read, and one `wh-<name>` line per `SqlWarehouse`, which is what the resource-group selectors match; `file.refresh-period=30s` picks remounts up with no restart. The strings are Keycloak user ids, matching `principal-field=sub` |
| `coordinator.additionalConfigFiles` (`resource-groups.properties`) + `trino-warehouses` volume, `configmap.reloader.stakater.com/reload` | the resource-group file manager (`configuration-manager=file`) reads `/etc/trino/warehouses/resource-groups.json` from ConfigMap `trino-warehouses` — the file CronJob `access-sync` renders from the `SqlWarehouse` objects (platform#312, platform#313). It is loaded **once** at startup, so Reloader restarts the coordinator when that ConfigMap changes; the chart's own `resourceGroups` block stays unset (it would render and mount a file of its own). See "Warehouses" below |

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

*Continuous group and warehouse sync (platform#167, platform#312).* Membership changes used to
wait for the next apply — a removed admin kept their all-queries view with no bound. CronJob
`access-sync` (`manifests/access-sync.yaml`, every 2 minutes) now converges ConfigMap
`trino-group-file` (the `stardelt-admins` line, re-read within 30 s, no restart) and the
resource groups of ConfigMap `trino-warehouses` (loaded once — a changed file restarts the
coordinator, platform#313), so a membership change lands without an apply. It
authenticates as the dedicated `trino-group-sync` service-account client with exactly
`view-users` on `realm-management` (converged by
`scripts/keycloak-sync-trino-group-sync-client.sh`, run by `make install-identity`; the realm
import declares the client for fresh installs) — read-only group membership, nothing broader —
and its RBAC may only read that client secret, patch status and converge those two ConfigMaps.
Its logs state counts, never principals.

*Warehouses (platform#312, platform#313).* A `SqlWarehouse` object is a named compute class inside
the one Trino: `access-sync` renders every valid object into a resource group of ConfigMap
`trino-warehouses` (key `resource-groups.json`) and one `wh-<name>` line of
`trino-group-file`, and writes `status.phase`/`renderedGroup`/`engine` back. The class
defaults are `xs` 2 running / 10 queued / 10 % memory, `small` 10/100/20 %, `medium`
5/50/40 %, `large` 6/70/70 %, scheduling `fair`; `spec.concurrency` overrides any of them.

The dev cluster ships three classes (`dev/seed/warehouses.yaml`, applied by `make seed-dev-access
YES=1`; `make unseed-dev-access YES=1` deletes `medium` and `large` and keeps `small`, the default
class, which any install needs):

| Class | Who lands in it | running / queued / memory |
|---|---|---|
| `small` — the one `default: true` | everybody in `stardelt-users`, `dev-outsider` included, and any principal that matches no group at all; administrators are routed to `admin` before a class selector is read | 10 / 100 / 20 % |
| `medium` | `finops` — the seeded `dev-finops` | 5 / 50 / 40 % |
| `large` | `analytics` — the seeded `dev-analytics` and the pre-existing `analyst` | 6 / 70 / 70 % |

The class is chosen by identity, never by a header a client sends: the coordinator reads its
selectors top to bottom and the first match wins — the admin group into its own `admin` root
group, then one `userGroup: wh-<name>` selector per warehouse from the **largest** class to the
smallest, then a catch-all into the one `default: true` warehouse. A person in two granted groups
therefore lands in the bigger class, and a selector that matches only on `clientTags` is refused by
the renderer because a client sets its own tags. With no default warehouse the catch-all goes to
the zero-concurrency `no-warehouse` root group instead, which answers `Too many queued queries for
"no-warehouse"`; with `small` marked default, a principal that nobody granted — a throwaway
Keycloak user outside `stardelt-users` — runs in `wh-small` rather than in a queue that never
moves.

Nova repeats that answer instead of deciding it (`GET /api/warehouses`, nova#236): the SQL editor
shows `Warehouse: <name> (<class>)` next to **Run**, and your Profile page shows the same line as
`SQL warehouse` — the largest class your groups are granted, the default class when none is, and
`Administrators` for a member of `stardelt-admins`, who lands in the `admin` root group. Nova reads
the `SqlWarehouse` objects and says what the selector will do; calling Trino directly still lands
you in the same class, because the choice reads the identity and never a header.

Which class a query ran in is visible in `system.runtime.queries` as an administrator — the
catalog is administrator-only since platform#363 (an ordinary person's query log is Nova's,
which reads its own store):

```sql
SELECT "user", resource_group_id FROM system.runtime.queries ORDER BY created DESC LIMIT 20
```

`resource_group_id` is the selector path the coordinator walked — an `array(varchar)` of the group
names, so the CLI prints `[global, wh-medium]` for `dev-finops`, `[global, wh-large]` for
`dev-analytics`, `[global, wh-small]` for `dev-outsider` (the default class) and `[admin]` for an
administrator. The `user` column is the Keycloak `sub` (the engine's principal, platform#311), so
match it against the `wh-<name>` lines of `trino-group-file` or look the person up in Nova's
session list.

The classes partition the one coordinator and worker (2 GiB heaps each) — a `large` class on a
one-node cluster means few concurrent queries with a bigger share of memory, not more hardware.
Queueing is real: a class at its `hardConcurrencyLimit` puts further queries into its queue, and a
query past `maxQueued` fails with `QUERY_QUEUE_FULL` instead of waiting forever.

The file manager loads `/etc/trino/warehouses/resource-groups.json` **once**, at startup (spike
platform#273 R6) — there is no live reload. A changed class therefore restarts the coordinator:
ConfigMap `trino-warehouses` is in the coordinator's `configmap.reloader.stakater.com/reload`
annotation (`helm-values/trino.yaml`), Reloader restarts the pod when the rendered file changes,
and `access-sync` writes the file only when the document differs, so a tick that changes nothing
does not bounce the engine. The restart ends the queries that are running — pick a quiet moment for
a class change. The group file (`trino-group-file`) is deliberately *not* in that annotation: the
file group provider re-reads it every 30 s, so a membership change needs no restart.

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

*The first pipeline of a group in one command (demo plan, platform#469).* Nova lets a person publish a pipeline for a group only
when that group has a ready principal `pipeline-<group>`; until then `stardelt bundle plan` refuses with "No principal for this
group yet". `make demo-access` does what that sentence asks an administrator to do: it checks that the Catalogs `bronze`, `silver`
and `gold` exist (it never creates a Catalog), makes sure the realm group exists (default `demo`, marked
`stardelt-managed=demo-access`), adds the people in `MEMBERS=ada,bo` to it (they must exist; it creates no user), runs
`sync-principal` for `pipeline-<group>`, applies the `ServicePrincipal` of that name and waits until the operator reports it ready,
then runs one access sync. Without `YES=1` it prints the plan and exits 1; a second run changes nothing and says so per step; it
deletes nothing. `bash scripts/demo-access.sh --manifest` prints the `ServicePrincipal` it would apply.

*The public demo (lab only).* `make public-demo YES=1` converges, in one idempotent command, the account a public demo
signs in with: the realm group `visitors`; the person `demo` with the password `demo` (public on purpose — it protects
nothing), enabled, in `visitors` and in no other group, and without the realm role `default-roles-stardelt`, so it does
not even get the account console; the `ServicePrincipal` `pipeline-visitors`, which a visitor's pipeline runs as and
which belongs to `visitors` (so a pipeline reaches the playground and never the tables `demo` owns); browse and select
for `visitors` on the Catalogs `bronze`, `silver` and `gold`; the
Catalog `playground` and the SqlWarehouse `demo` (`xs`) it may write to; the ConfigMap `stardelt-public-demo` that tells
Nova the account is shared (Nova restarts once, the first time); and one access sync plus `make catalogs`. **Everything in
`bronze`, `silver` and `gold` becomes readable by anyone on the internet**, which is why it prints that warning and why it
needs `YES=1`; it refuses to run before the Catalogs and the principal `pipeline-demo` (`make demo-access YES=1`) exist.
The kill switch is `make public-demo-off YES=1`: it disables `demo` and signs it out, and deletes nothing. A second run
changes nothing and says so per step, except the password reset. `make public-demo-check` reports every prerequisite of
that rollout in one read-only pass — the checkout, the CLI, the Catalogs, the principal, the realm group and person,
their memberships and roles, the grants, the playground, the warehouse, the ConfigMap and the nightly reset — one
`PASS`/`MISSING` line each, with the command that fixes a missing one, and exits 1 while anything is missing.
The nightly reset runs as `pipeline-demo` and also holds the `playground` warehouse's `modify` role: dropping a
table or a schema is an administrator action since the grant was scoped down (platform#1130), so the reset
principal is given `modify` on that one warehouse, and `make demo-reset-grant` re-applies it.

*Catalog service clients (platform#282, step 1 of the catalog's authentication).* Every component
that calls the Iceberg REST catalog has its own confidential service client instead of sharing one:

| Secret | Used by |
|---|---|
| `svc-catalog-trino` | the Trino coordinator |
| `svc-catalog-nova` | Nova |
| `svc-catalog-spark` | reserved for a future platform-side Spark path; the Spark Connect driver now uses the person's token (#317) |
| `svc-catalog-airflow` | the Airflow task pods |
| `svc-catalog-bootstrap` | the Lakekeeper bootstrap Job |
| `svc-catalog-bridge` | the OPA bridge sidecar in the Lakekeeper pod (platform#303) |
| `svc-catalog-operator` | the stardelt operator's Catalog controller (platform#303) |

`make sync-catalog-clients` converges all seven through the same script with
`KIND=service`: no owner group and no `groups` claim (each is a component, not a person), an
`aud-lakekeeper` audience mapper, the attribute `stardelt-managed=service`, and a Secret named after
the client in namespace `stardelt`, whose keys `client-id`, `client-secret` and `token-url` (the
realm's endpoint, written for a service client) are the source of truth. Rotation is a principal's:
`ROTATE=1 make sync-catalog-clients` writes a new value to Keycloak first, then to each Secret, and
proves every new value with a client-credentials token.
`make delete-catalog-clients YES=1` removes them, and only clients carrying
`stardelt-managed=service` are accepted. The bridge's Secret also carries `scope: openid`, because
the Lakekeeper chart takes the bridge's requested scope from that Secret and its default, the client
scope `lakekeeper`, does not exist in this realm (`400 invalid_scope`); after the cutover (#304) the
bridge's client holds `project_admin`, since it checks *other* principals' permissions and therefore
has to be more than a reader. Lakekeeper validates these tokens since platform#285 — an
anonymous request is `401` and the audience must be `lakekeeper` — but authorisation is still
`allowall`, so a valid client may read and change every table's metadata. The seven-client split
is what makes the next step possible: one caller can be narrowed or revoked at a time.

*Catalog sign-in for Trino and the bootstrap Job (platform#283, step 2).* Those
callers obtain a token from the realm's token endpoint and send it as
`Authorization: Bearer` on every catalog call; Lakekeeper validates it since platform#285.
Trino's `warehouse` catalog gains `iceberg.rest-catalog.security=OAUTH2` plus the credential and
token-endpoint properties in `helm-values/trino-identity.yaml` (not in the base values: Trino
refuses to load a catalog with `security=OAUTH2` and no credential, and the base values are also
the `install-core` path, which has no IdP). Coordinator and workers read `client-id` and
`client-secret` from Secret `svc-catalog-trino` through their environment, so each JVM does its own
exchange, and Reloader restarts them when that Secret rotates. The Spark Connect driver does not
sign in as a service client any more: since platform#317 each session carries the person's token
(`stardelt.spark()`), and `svc-catalog-spark` remains a realm client for a future platform-side
path. The bootstrap Job mounts Secret `svc-catalog-bootstrap` as files and sends
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
Secret also carries `token-url`, which `make sync-catalog-clients` writes (platform mode only —
with an external provider there is no Keycloak to sync against). Trino's catalog client does not
read that key: it takes `CATALOG_TOKEN_URL` from ConfigMap `stardelt-identity` key
`tokenEndpoint` (#611), so with an external provider it signs in at the provider's own token
endpoint instead of the realm path. And every reference is `optional`, so an install without an
IdP (no Secret) keeps Nova and Airflow running and both keep calling Lakekeeper anonymously — the
`install-core` shape. No cluster permission changes: the Role is the same as before.

*Catalog authentication is enforced (platform#285, step 5).* Lakekeeper is no longer anonymous:
it validates the bearer token on every request and answers `401` when the header is missing, the
signature is wrong, or the token is for another issuer or audience. The two settings are the ones
the spike verified (`stardelt-platform#271`, P1.1) and they live in `helm-values/lakekeeper.yaml`
as `catalog.extraEnv`: `LAKEKEEPER__OPENID_PROVIDER_URI` from ConfigMap `stardelt-identity`
(`issuerUrl`) and `LAKEKEEPER__OPENID_AUDIENCE=lakekeeper`. They are extra env vars rather than
`auth.oauth2.providerUri` because the issuer is install-time state and Helm cannot read a ConfigMap
in a values file; every other component reads the identity contract the same way, and
`optional: true` keeps an install without an IdP (`install-core`) anonymous. **Authorisation is
still `allowall`**: authentication says *who* you are, not *what* you may do — a valid token still
reaches every table's metadata until platform#304 turns on OpenFGA. The NetworkPolicy
([Catalog network access](spark.md#catalog-network-access-interim)) stays as defence in depth.

A new caller gets its own client; never share one:

```sh
make sync-principal KIND=service NAME=catalog-<caller> AUDIENCES=lakekeeper
# Secret catalog-<caller> in namespace stardelt: client-id, client-secret, token-url
```

The caller exchanges those for a token at `token-url` with scope `openid` (the realm has no
`lakekeeper` client scope; the `aud-lakekeeper` mapper adds the audience the catalog checks) and
sends `Authorization: Bearer` on every catalog request. Its pod must also be admitted by
`lakekeeper-ingress` — add a `podSelector` entry, never a namespace selector. The full list of
platform callers is `make sync-catalog-clients` (`svc-catalog-*`, platform#282).

Proof, from a pod the NetworkPolicy admits:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://lakekeeper:8181/management/v1/info          # 401
curl -s -H @auth-header http://lakekeeper:8181/management/v1/info                            # 200
```

Rollback: `helm rollback lakekeeper` (the previous revision has no OPENID settings) and the
catalog is anonymous again; re-apply with the `make install` step to turn validation back on.
The Lakekeeper UI client is unchanged: the UI is not published (no Ingress) and keeps no
sign-in wiring.

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
`make verify-external-secrets` proves that mechanism end to end on a cluster where
`make external-secrets` has run: a Fake-provider `ClusterSecretStore`, one `ExternalSecret`, and
the Secret it creates — then deletes both. Run it after any ESO or chart change.

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

### TLS on the coordinator (why the in-cluster path is safe)

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

Query visibility is enforced by Trino itself, not by hiding the UI: CronJob `access-sync`
keeps the live realm's `stardelt-admins` membership in ConfigMap `trino-group-file` (every 2
minutes, never printing a value), and `make trino` runs one sync before the upgrade.
Removing a user from `stardelt-admins` removes their all-queries view on the next tick —
within 2 minutes plus the file's 30 s refresh, no apply and no restart.

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

## Turning on sign-in

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
removing someone from the group removes it at their next sign-in. Queries run as the person who
signed in, not as the shared service account — see
[Superset runs queries as the person](#superset-runs-queries-as-the-person).

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

## Superset runs queries as the person

Every query Superset sends to Trino runs as the signed-in person, never as the shared
`superset` service account. Superset still *authenticates* with the service account's
password (PASSWORD authenticator, `SQLALCHEMY_CUSTOM_PASSWORD_STORE`), but the database row
now carries `impersonate_user: true`
(`helm-values/superset.yaml`, `extraConfigs/import_datasources.yaml`), so Superset sends the
person as `X-Trino-User`; Trino's file access control authorizes that through exactly one
`impersonation` rule (`helm-values/trino-identity.yaml`):

```json
{"original_user": "superset", "new_user": "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "allow": true}
```

Trino's access control denies impersonation by default, so the rule is the whole grant: the
service account may act only for a UUID-shaped principal. `admin`, `stardelt-admins` and the
service account itself stay refused, which is why the rule is a pattern and not `.*` — and why
the break-glass local login (above) can administer Superset but cannot run SQL Lab on Trino.

**Why the username is a UUID.** The person's Superset username is their Keycloak `sub`
(`CUSTOM_SECURITY_MANAGER = StardeltSecurityManager` in the same values file, overriding FAB's
Keycloak branch, which returns `preferred_username`). That is the identity the rest of the
platform keys on: Trino's OAuth principal after the identity turn-on is the token's `sub` and
the permission bridge maps a Trino principal to the Lakekeeper user `oidc~<sub>`, so the
impersonated name must be that same string or catalog permissions would apply to a name nobody
holds. Readable names do not disappear — `first_name`/`last_name` come from the same userinfo
response and Superset renders those. People who signed in before this change keep their rows and
their roles; their next sign-in renames the existing row to the `sub`, so their saved queries
and dashboards stay attached. It is a rename, not a second row, because FAB's `ab_user.email`
is unique *and* not null and the old row holds the person's address — a second row for the same
address fails with `duplicate key value violates unique constraint "ab_user_email_key"` and the
sign-in ends 401 (measured on the dev cluster). The local `admin` row is untouched: its address
(`admin@stardelt.local`) differs from the realm user's.

**The result cache is per person.** `FEATURE_FLAGS = {"CACHE_IMPERSONATION": True}`
(`helm-values/superset.yaml`, applied in every mode) adds the impersonated identity to
Superset's cache key. Without it, Superset keys a chart's cached result by the query alone and
serves user A's chart to user B — measured in platform#279, Q6, and a real cross-user data
leak once charts run as the viewer.

**Who ran what.** Trino records the person, not the shared account:

```sql
SELECT query_id, "user", source, state, created
FROM system.runtime.queries
WHERE source LIKE '%Superset%'
ORDER BY created DESC LIMIT 20;
```

`user` is the person's `sub`; Nova's query log resolves it to the display name from its own
session. `system.runtime.queries` is in the administrator-only `system` catalog since
platform#363; among administrators, the `queries` rules decide who may view or kill which
query (`helm-values/trino-identity.yaml`), and an ordinary person sees their own queries in
Nova's log instead. Async SQL Lab (Celery worker) carries the same person, so a `runAsync`
query and a
chart load agree.

Applying it to the live cluster is two rolled releases (`make trino` and the Superset upgrade
in `make install`), with no manual SQL: the init Job's datasource import updates the existing
`Trino Warehouse` row, because the v0 importer sets every known field on a row it finds by
`database_name`.

## The realm-admin Secret is the source of truth

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

## The client secrets are the source of truth too

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

## Managing users

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
