# Prerequisites

Part of the [stardelt-platform](../README.md) manual.

| Tool | Minimum version | Notes |
|------|----------------|-------|
| `kubectl` | 1.28+ | Must be configured with a valid kubeconfig pointing at your cluster |
| `helm` | 3.19+ | The `stardelt-dedupe` post-renderer plugin is installed automatically |
| `docker` | any recent | Required only for the local image targets (`make build-superset-image`, `make build-jupyter-image`) |
| `cert-manager` | 1.15+ | Required by the platform IdP (`make platform` with `IDENTITY=1`): the query engine's in-cluster TLS certificate is issued by a namespace-local CA (`manifests/trino-tls.yaml`). The playground installs it with the ingress (see `dev/playground/README.md`). `make install-core` without identity does not need it. |

Your `kubectl` current-context determines the target cluster. Verify with:

```sh
kubectl config current-context
```

Every installing or uninstalling `make` target prints the context it is about to act on.
Set `EXPECT_CONTEXT` to make it refuse any other cluster:

```sh
EXPECT_CONTEXT=stardelt-dev make install-core
```

New here? Start with the [runbook](#runbook) — one command installs the platform,
one command upgrades it.

---

# Runbook

*For an operator who has never seen the platform. One command installs it, one
command upgrades it, and nothing in between is your job.*

Everything below acts on the kube-context `kubectl` points at. Pin it so a
stale context cannot send an install to the wrong cluster:

```sh
export EXPECT_CONTEXT=stardelt-dev
```

## Before you start

| | |
|---|---|
| A Kubernetes cluster | 1.28+, any conformant distribution (EKS, GKE, AKS, RKE2, k3s, kind, …) — stardelt does not ship a distribution |
| `kubectl` | 1.28+ |
| `helm` | 3.19+ |
| A domain | the IdP's issuer is `https://id.<your-domain>/realms/stardelt`; without one the platform runs in the development shape (no sign-in) |
| `cert-manager` | only with the IdP: the query engine's in-cluster TLS certificate is issued by a namespace-local CA (`manifests/trino-tls.yaml`) |
| Memory on the node | ~8 GB for the core profile, 16 GB for the full one (Airflow, Superset, notebooks and Spark) |

## Install — one command

```sh
git clone https://github.com/stardelt/stardelt-platform
cd stardelt-platform
IDENTITY=1 BASE_DOMAIN=platform.example.com make platform
```

`make platform` runs twelve steps in order — storage, the databases, the
permission store, the IdP, the catalog, the access-sync, the query engine, the
apps, the notebooks, Spark and the image pins — then waits for every workload
and prints what is running. It is safe to run twice: every step converges the
live state to what this repository declares and leaves it alone when it is
already there.

* `IDENTITY=1` installs the platform IdP (Keycloak) with the realm, the client
  secrets and the audiences. Leave it out and the platform runs without
  sign-in — the development shape, for a cluster where you only want the
  catalog and the query engine.
* `BASE_DOMAIN` is the domain the IdP and the apps are served on. It is
  substituted into the realm, so a wrong value means a wrong issuer URL.
* `NAMESPACE=other` puts the whole platform in another namespace.
* `SLIM=1` applies the small-node overrides.

Preview what a run would do — the commands, nothing written:

```sh
make platform-dry-run
```

## What it creates

| | |
|---|---|
| Helm releases | `reloader`, `cnpg`, `seaweedfs`, `openfga`, `lakekeeper`, `trino`, `airflow`, `superset`, `jupyterhub` |
| Deployments / StatefulSets from the manifests | `keycloak`, `nova`, `spark-connect` |
| Postgres clusters (CloudNative-PG) | `lakekeeper-pg`, `nova-pg`, `keycloak-pg`, `openfga-pg` — with WAL archiving and a daily base backup into the object store |
| CronJobs | `access-sync` (every 2 minutes: the warehouses, the grants, the group file, the decision table), `airflow-pg-dump`, `superset-pg-dump`, `lakehouse-backup` |
| ConfigMaps | `stardelt-identity` (the identity contract every component reads), `trino-group-file`, `trino-warehouses`, `access-sync-script` |
| Secrets | `stardelt-s3-creds` (generated once), `keycloak-admin`, `stardelt-realm-admin`, `stardelt-oidc-clients`, `trino-internal-secret`, `trino-password-db`, `airflow-*`, `superset-*` |
| Buckets | the data bucket and the versioned `notebooks` bucket in the object store |

It does **not** create: the `Catalog` objects (those are the operator's own
resources — `make seed-dev-access` makes a dev set), the stardelt Operator
(`make install-operator`, needs a sibling checkout), OpenBao or the External
Secrets Operator (both opt-in).

## Upgrade — one command

```sh
git pull                       # the new release
make upgrade
```

`make upgrade` converges everything to the new release, moves the image pins to
the digests CI published, runs the schema migrations (CloudNative-PG,
Lakekeeper's own migration job, the query engine's upgrade and the catalog's
bootstrap), converges the access-sync and then runs the verify targets
(`verify-trino-auth`, `verify-catalog-permissions`, `verify-backups-all`). It
is safe to run twice.

Prove that for yourself — the gate snapshots every object of the platform,
runs the flow again and compares:

```sh
make platform-idempotence    # the install changes nothing on a converged cluster
make upgrade-idempotence     # the same for the upgrade
```

The gate prints the objects that moved, or `✓ the install flow changed nothing`.

## Two channels: iterate fast, pin deliberately

The dev cluster is meant to track `main`, but a repository that is pinned for a
reproducible install should not be rewritten on every merge. The two are separate
targets:

```sh
make dev-refresh    # the fast channel: every stardelt image to the newest `dev` build
make pin-images     # the stable channel: the same, and write the digests into manifests/
```

`make dev-refresh` resolves the `dev` tag and patches the running Deployments only —
nothing is written to the checkout, so there is no branch and no PR in the loop. Use
it after a merge on `main` when you want the cluster to have the change now.

```sh
APP=nova   make dev-refresh    # one image only (seconds, not a minute)
NOWAIT=1   make dev-refresh    # fire and forget: do not block on the rollout
TAG=sha-a8737e5 make dev-refresh APP=nova   # a specific merged commit, not the newest
make dev-watch                 # follow nova's `dev` tag and roll when CI publishes
APP=nova INTERVAL=5 make dev-watch   # a tighter tick, another image
ONESHOT=1  make dev-watch      # one check, then exit — this is what a timer runs
make dev-status                # what the cluster runs vs what the manifests pin
```

`TAG=` matters when "the newest" is not what you want: every merged commit keeps an
immutable `sha-<short>` tag (`git -C stardelt-nova log origin/main --format=%h -1`),
so you can put one specific commit on the cluster — to check a fix, or to bisect a
regression — without a branch and without moving `dev`. Pull-request builds are *not*
published (`Image` pushes only off `main` and `v*`), so a branch is tested by merging
and then pinning that commit.

`make dev-status` answers the question the two channels create — *is the cluster
ahead of the pin, or behind it*:

```text
  app                  cluster        pinned         state
  nova                 33dbe9854f36   a3f4e0450c12   cluster ahead of the pin
  spark                a36a9a8f1a8a   a36a9a8f1a8a   in sync
  stardelt-operator    575b89c47077   (chart)        pinned by the chart
```

It is read-only and always exits 0, so it is safe in a prompt or a CI step.

"Differs from the pin" alone would be ambiguous — the same output for the fast
channel working and for a Deployment someone rolled back to an old build. So the
registry's current digest of `TAG` is the third point, and only *cluster == tag !=
pin* counts as ahead. Anything else is reported in red, with what to run:

```text
  nova     deadbeefdead   a3f4e0450c12   differs from the pin AND from dev
```

`NO_REGISTRY=1` skips that lookup (offline); the state then says it did not ask.

`make dev-watch` is the inner loop: each tick asks the registry for the tag's digest
and compares it with what the Deployment runs, so it is one request and silent until
something changed. Ctrl-C stops it; it never writes the repository either.

`make pin-images` does the same and then records the digest in
`manifests/nova-deployment.yaml` / `manifests/spark.yaml`. That is the state a
reproducible install carries, and it is a deliberate act: run it when a build is
worth freezing, not on every merge.

Two consequences worth knowing:

- **An install wins over a refresh.** `make install` and `make upgrade` apply the
  manifests, so they converge the cluster back to the pinned digests. After a
  `make dev-refresh`, the next install moves the images back — deliberately, because
  an install is reproducible. To keep a build, `make pin-images` and commit.
- **`make platform-idempotence` reports the first run after a refresh.** The gate runs
  the flow and compares, and the flow applies the manifests — so a cluster that is
  ahead of the pins is converged back to them, which is a real change. Measure it
  instead of trusting the sentence: after `make dev-refresh`, the first gate run names
  `deployments/nova` (and its resourceVersion) and the second one passes, because by
  then the cluster matches. `SKIP_PINS=1` only stops the gate from *re-pinning*, not
  from applying what is pinned; that is what makes it a proof of convergence rather
  than of "nothing happened".

## When a step fails

Every step is named, and a failure says which one broke, what it does, how to
undo it, the command to look at and the next action:

```
✗ step query failed (exit 2)

  what this step does : installs the query engine (Trino) — with OAuth2 and the in-cluster TLS listener when the platform has an IdP
  how to undo it      : helm uninstall trino -n stardelt (the PVC stays)
  look at             : kubectl -n stardelt logs deploy/trino-coordinator --tail=100
  next                : fix the cause the command above shows, then run the
                        command again. Every step is idempotent, so the run
                        continues where it stopped and changes nothing else.
```

Read the log the message points at, fix the cause, run the same command again.
There is no silent retry and no `|| true` in the flow: a step that cannot
finish stops the run there.

## Remove it

```sh
make uninstall
```

That removes the Helm releases and the manifests in reverse order. **The
PersistentVolumeClaims stay** — the data does not go with the platform. Delete
them yourself when you mean it:

```sh
kubectl delete pvc --all -n stardelt
```

The Secrets listed in the output of `make uninstall` stay as well (they hold
the keys that make the backups readable): `stardelt-realm-admin`,
`stardelt-oidc-clients`, `trino-password-db`, `airflow-fernet-key`,
`superset-secret-key` and the rest. `make export-recovery-secrets` writes them
to an encrypted file outside the repository before you delete anything.

---

# Quickstart

```sh
make deps      # verify kubectl + helm are present
make platform  # install the whole platform (the runbook above)
make pf        # open port-forwards
```

Override the namespace (default: `stardelt`):

```sh
NAMESPACE=my-namespace make platform
```

---

## Who may use notebooks

The hub is default-closed. Two groups are admitted: `stardelt-admins`, and
**`stardelt-users` — the realm's default group**, so an account created in the
Keycloak console can open a notebook without an administrator doing anything.
`make sync-realm-user-management` guarantees the group exists and stays a default
group; membership is the only switch.

# Helm chart (baseline)

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

`make verify-backups` checks that the bucket has every WAL segment PostgreSQL has queued for archiving: the current segment is archived, or the one before it is and `pg_wal/archive_status` holds no `.ready` file. An idle cluster passes at any age; a segment that is waiting behind is a gap. The SeaweedFS filer needs **512Mi** of memory — at 256Mi it was OOM-killed in a loop and took S3 writes down with it (platform#230); raise it only with a measured peak, never by lowering another limit.

---

# Uninstalling

```sh
make uninstall
```

This removes helm releases in reverse dependency order and deletes the manifests. PVCs
are intentionally left in place; delete them manually if you want to reclaim storage:

```sh
kubectl delete pvc --all -n stardelt
```

The full removal path — what is kept, what is lost, and how to keep the
recovery keys — is in the [runbook](#remove-it).
