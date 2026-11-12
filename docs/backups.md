# Backups

Part of the [stardelt-platform](../README.md) manual.

Every piece of state the platform keeps, how it is copied and where it comes back
from. A backup nobody restored is a hope, so each row names the check that proves
it: `make verify-pgdump` restores the newest dump into a throwaway database and
compares the table count with the live one; `make verify-backups*` compares the
WAL bucket with the database's own archiver (#59). Neither compares rows — the
restore is where a human looks at the data.

| State | Lives in | Mechanism | Retention | Proof |
|---|---|---|---|---|
| Catalog metadata (warehouses, tables, grants) | `lakekeeper-pg` (CloudNative-PG) | Continuous WAL archiving → `s3://backups/lakekeeper-pg/` plus the daily base backup `lakekeeper-pg-daily` (02:30) | 14 days (`retentionPolicy: 14d`) | `make verify-backups` |
| Nova state (saved queries, settings) | `nova-pg` (CloudNative-PG) | Same: WAL + `nova-pg-daily` | 14 days | `make verify-backups-nova` |
| Identity (users, realms, clients) | `keycloak-pg` (CloudNative-PG) | Same: WAL + a daily base backup | 14 days | `make verify-backups-identity` |
| Permissions (OpenFGA tuples) | `openfga-pg` (CloudNative-PG) | Same: WAL + `openfga-pg-daily` | 14 days | `make verify-backups-openfga` |
| Superset (dashboards, charts, datasets, saved queries) | `superset-postgresql` (Bitnami StatefulSet) | `pg_dump --format=custom` CronJob `superset-pg-dump`, 02:30 → `s3://backups/pgdump/superset/` | 14 dumps | `make verify-pgdump PG_DUMP=superset` |
| Airflow (run history, users) | `airflow-postgresql` (Bitnami StatefulSet) | `pg_dump` CronJob `airflow-pg-dump`, 02:45 → `s3://backups/pgdump/airflow/` | 14 dumps | `make verify-pgdump PG_DUMP=airflow` |
| Lakehouse data | SeaweedFS bucket `lakehouse` | `lakehouse-backup` CronJob: `aws s3 sync` into bucket `lakehouse-backup`, no `--delete`, so an object removed from the source stays recoverable | archive keeps what the source loses | — |

`make backups` applies the two dump CronJobs; `make install` does it after
Superset/Airflow and `make uninstall` removes them. The objects are written by
`amazon/aws-cli` (digest-pinned) into the same `backups` bucket as the
CloudNative-PG prefixes, under `pgdump/`, and each run prunes its own prefix
beyond 14 days. The dump container runs the database's *own* postgres image: the
dump tool must not be a newer major version than the server it reads. The umbrella
chart does not render these two CronJobs; like the other plain manifests they are
applied to namespace `stardelt`.

`make verify-backups-all` is the single pass/fail entry point over the whole
list: it enumerates every PVC in the namespace, maps it to its mechanism and
prints `PVC | mechanism | last backup age | verdict`. A PVC fails when it has no
mechanism and no written-down exception, when a mapped mechanism is missing, or
when its newest backup is older than 36 h. It is a manual target — nothing
schedules it; run it after the nightly window, or a fresh install fails until
each mechanism has completed its first run. It also prints one `offsite copy`
line for the off-cluster copy below.

## Recovery keys

A backup restores the rows; it does not restore the keys that encrypted them.
Seven Secrets exist only in the cluster's own datastore, are generated at
install time and are copied nowhere: `openbao-seal-key` and `openbao-init` (the
secret store cannot be opened without the seal key), the
`lakekeeper-postgres-encryption` key (warehouse secrets inside Lakekeeper's
database), `airflow-fernet-key` (connections and variables inside Airflow's
database), `stardelt-s3-creds` (the object store the backups live in) and
`keycloak-admin` / `stardelt-realm-admin` (the identity provider's
administrators). Lose the node and the databases come back; without these keys
their contents do not.

```sh
# RECOVERY_PASSPHRASE in the environment; FILE is never inside this repository
make export-recovery-secrets FILE=/media/usb/stardelt-recovery.enc
make import-recovery-secrets FILE=/media/usb/stardelt-recovery.enc CHECK=1
```

`export` writes one `kind: List` document with only what `kubectl apply` needs
(name, namespace, type, data — no uid, resourceVersion, ownerReferences or
annotations), AES-256-CBC with PBKDF2 (600 000 iterations) and a random salt,
into a file with mode `0600`. The passphrase comes only from
`RECOVERY_PASSPHRASE`, must be at least 16 characters, and is never written next
to the file or printed; `import` decrypts in memory. A Secret that does not
exist in the namespace is reported and left out, never invented — a partial
install exports what it has and says so. The target refuses a `FILE` inside the
repository work tree, and an existing file without `FORCE=1`.

Store that file **outside the cluster and outside the backup buckets**: the
administrator's password manager, or a safe. Not on the machine whose loss it is
meant to survive, and not in the object store that the platform itself restores
from — a copy of the keys next to the ciphertext protects nothing. The
passphrase is the other half: keep it somewhere else again, and not in this
repository. Without it the file is noise.

Restore order: the keys first (`make import-recovery-secrets`, `NAMESPACE=…`
targets another namespace), then the databases, then the object store. A catalog
restored before `lakekeeper-postgres-encryption` is back restores the rows, but
every warehouse secret in them stays unreadable.

## Off-cluster copy

`make offsite-backup` (also part of `make backups`) applies the
`offsite-backup` CronJob: at 04:15 daily, `rclone copy` pushes the three
backup buckets — `backups` (the CloudNative-PG WAL/base backups and the
`pgdump/` objects), `lakehouse-backup` (the object-store archive) and
`notebooks` (published notebooks) — to an S3 destination the operator chooses.
It is `copy`, never `sync`: nothing is deleted at the destination, so an object
removed from the source stays recoverable there. The versioned `notebooks`
bucket is copied as its current object versions only — rclone does not read
versions.

The destination is **the operator's own S3** (their object store, another
region, another provider), configured in Secret `backup-offsite` with keys
`endpoint`, `region`, `bucket`, `access-key`, `secret-key` and an optional
`prefix`. The values are typed by the administrator and never committed to this
repository:

```sh
kubectl -n stardelt create secret generic backup-offsite \
  --from-literal=endpoint=https://s3.example.net \
  --from-literal=region=us-east-1 \
  --from-literal=bucket=stardelt-backup \
  --from-literal=access-key=... --from-literal=secret-key=... \
  --from-literal=prefix=alpha          # optional
```

Without that Secret the CronJob still applies, runs, prints
`offsite: not configured (Secret backup-offsite)` and exits 0 — a destination
is a decision, never a default. Without one, every backup shares the cluster's
failure domain: losing the SeaweedFS volumes loses the backups with them. To
restore, run the copy in the other direction — from the off-cluster bucket back
into the platform's store (`rclone copy` destination remote → source remote; the
env shape is in `manifests/offsite-backup.yaml`).

`make verify-backups-all` prints `offsite copy | NOT CONFIGURED (Secret
backup-offsite absent)` when no destination is set, `PASS (<age>)` when the
last successful run is younger than 36 h, and `FAIL (<reason>)` otherwise.
NOT CONFIGURED does not fail the run; FAIL does.

## Not covered (and why)

- **The OpenBao data directory.** `data-openbao-0` holds the secret store and
  Secret `openbao-seal-key` unseals it; losing either makes the data unreadable.
  The keys are exported by `make export-recovery-secrets` (above), the store's
  own data directory is not copied: that belongs to the backup design in
  platform#368 and is deliberately not improvised here.
- **Cluster state.** CRDs, Helm releases, RBAC, ConfigMaps and Secrets are in
  none of the mechanisms above — they are the output of `make install` plus this
  repository, so `main` recreates them. The rows above are what a rebuild cannot
  recreate.
- **JupyterHub's home database.** `hub-db-dir` is a sqlite file (users, servers,
  tokens): a *session* store. Losing it means people sign in again, not that
  notebooks are gone (notebooks are objects in the `notebooks` bucket).
- **SeaweedFS filer and master metadata.** `data-filer-seaweedfs-filer-0` holds
  the S3 namespace index and `data-stardelt-seaweedfs-master-0` the volume
  assignment. The object bytes live in the volume store — the `lakehouse` bucket
  is what `lakehouse-backup` copies — so these two are metadata, not data, and
  are not covered by design today (platform#3). `make verify-backups-all` lists
  them as ACCEPTED.
- **Published notebooks.** The `notebooks` bucket has S3 versioning, which
  survives overwrites and deletes inside the bucket, not the bucket itself.
- **Caches.** `superset-redis` holds no PVC; it rebuilds itself.

And the limit that applies to all of it: by default the backups live in the
same SeaweedFS cluster as the data they protect. Losing the SeaweedFS volumes
loses the backups with them — that is what the off-cluster copy above is for.
Without a configured destination, every backup shares the cluster's failure
domain.

## Restoring

**CloudNative-PG clusters** (catalog, Nova, Keycloak, OpenFGA):
`manifests/cnpg-restore-proof.yaml` is a working recovery Cluster in namespace
`stardelt-restore` that recovers `lakekeeper-pg` from the latest archived WAL. For
another cluster rename it and set `serverName` to the folder in the bucket (which
does not follow the restored Cluster's name):

```sh
kubectl create namespace stardelt-restore
kubectl -n stardelt get secret stardelt-s3-creds -o json \
  | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,
            .metadata.creationTimestamp,.metadata.managedFields)' \
  | kubectl -n stardelt-restore apply -f -
kubectl -n stardelt-restore apply -f manifests/cnpg-restore-proof.yaml
```

**Superset and Airflow** (logical dumps): run the CronJob once, read the key it
printed, and restore that object. The job prints `name`, `size` and `key` — never
a credential:

```sh
kubectl -n stardelt create job --from=cronjob/superset-pg-dump superset-pg-dump-now
kubectl -n stardelt logs job/superset-pg-dump-now -c upload | tail -1
make verify-pgdump PG_DUMP=superset        # runs it and restores the newest object
```

To restore it for real, run a pod with the `postgres` image, the
`stardelt-s3-creds` Secret and the app's password Secret (the verify script builds
exactly that pod), fetch the key and restore into a *new* database first —
`--clean` against the live one drops what is there:

```sh
pg_restore --list dumpfile                      # what is in the archive
pg_restore --no-owner -h superset-postgresql -U superset -d superset_restore dumpfile
```

`make verify-pgdump` is the executable form of this procedure: it restores the
newest object into a throwaway `restoretest` database with `--exit-on-error` and
compares the table count with the live database, so the path is exercised rather
than assumed. Like the WAL guards it runs on demand; a scheduled wrapper is
follow-up work, as for #59.

**Lakehouse objects:** run an `amazon/aws-cli` pod with the `stardelt-s3-creds`
Secret (the shape is in `manifests/object-store-backup.yaml`) and sync the other
direction:

```sh
aws --endpoint-url "$AWS_ENDPOINT_URL" s3 sync s3://lakehouse-backup s3://lakehouse
```

---
