# Spark — heavy compute on the same Iceberg tables

Part of the [stardelt-platform](../README.md) manual.

Spark is the heavy-compute plug of the master spec (§5 #14): a **Spark Connect**
endpoint in the cluster, reading the same Iceberg tables as Trino. A table
written by one engine is a table of the other — no copy, no second catalog, no
second credential store for table data.

Since platform#317 the catalog is **per person**, not the shared service client:
`stardelt.spark()` asks Trino which catalogs the signed-in person may see, then
creates a session with one Iceberg REST catalog per name and that person's token.
Lakekeeper decides, so Spark sees the same catalogs and the same grants as the
person's Trino session — and a catalog they may not see is refused by the catalog,
not by a list in Spark.

```sh
make install-spark     # manifests/spark.yaml: Deployment + Service + ConfigMap + RBAC
```

Endpoint (ClusterIP only — there is deliberately no Ingress):

```text
sc://spark-connect.stardelt.svc.cluster.local:15002
```

From a notebook, use the helper the single-user image ships (the pinned release of
`stardelt/stardelt-python`). It sets the catalogs and the token for you:

```python
import stardelt

spark = stardelt.spark()          # every catalog Trino lists for you, with your token
spark.sql("SELECT country, confirmed_cases FROM warehouse.covid.covid_summary").show()
spark.sql("SHOW CATALOGS").show()
```

A scheduled job (PySpark Connect client, `pip install pyspark-client==4.1.4`) has no
hub token, so it builds the same session itself and passes its own token:

```python
from pyspark.sql import SparkSession

builder = SparkSession.builder.remote(
    "sc://spark-connect.stardelt.svc.cluster.local:15002"
).appName("nightly-load")
builder = builder.config("spark.sql.catalog.warehouse", "org.apache.iceberg.spark.SparkCatalog")
for key, value in {
    "type": "rest",
    "uri": "http://lakekeeper.stardelt.svc.cluster.local:8181/catalog",
    "warehouse": "warehouse",
    "token": token,               # the pod's own principal, audience lakekeeper
    "io-impl": "org.apache.iceberg.aws.s3.S3FileIO",
    "s3.endpoint": "http://seaweedfs-s3.stardelt.svc.cluster.local:8333",
    "s3.region": "us-east-1",
    "s3.path-style-access": "true",
}.items():
    builder = builder.config(f"spark.sql.catalog.warehouse.{key}", value)
spark = builder.create()          # create(), not getOrCreate(): a fresh session per token
```

The quickstart notebook's Spark cell uses `stardelt.spark()` and prints the count
of `warehouse.covid.covid_summary` (`demo` was removed on 2026-10-21), so one click
in Nova's Notebooks page proves the second engine as well as the first.

Notebook pods reach the endpoint because the JupyterHub chart's singleuser NetworkPolicy carries
one egress rule for it (`helm-values/jupyterhub.yaml`): `podSelector:
app.kubernetes.io/name=spark-connect`, port 15002. The chart default denies **all** private
addresses, and the one-line alternative (`egressAllowRules.privateIPs: true`) would have opened
Trino, Lakekeeper, S3 and the Kubernetes API to every user pod for the same feature — the narrow
rule is the point (stardelt-platform#90). Spark pods are not part of the umbrella chart; when
they are absent the rule matches nothing.

The image is `ghcr.io/stardelt/spark` (`images/spark/Dockerfile`): Apache Spark 4.1.4
plus the Iceberg 1.12 runtime and AWS bundle. The jars are baked in at image build
time (checksum-verified from Maven Central), so a pod never downloads dependencies —
the install stays air-gap-friendly when the registry is mirrored.

## Reading public S3 with Spark

A notebook can read a **public** S3 bucket directly — no catalog, no Iceberg table —
with either URI form:

```python
spark = stardelt.spark()
spark.read.csv("s3a://noaa-ghcn-pds/csv.gz/by_year/1763.csv.gz").count()
spark.read.parquet("s3://ookla-open-data/parquet/performance/type=fixed/year=2023/quarter=1/").limit(5).show()
```

The image carries `hadoop-aws` 3.4.2 (Hadoop's S3A filesystem) and the AWS SDK v2
bundle that version needs, so `s3a://` resolves; `s3://` is mapped to the same
filesystem class (`spark.hadoop.fs.s3.impl`). Both are anonymous and **only**
anonymous: `spark.hadoop.fs.s3a.aws.credentials.provider` is
`AnonymousAWSCredentialsProvider`, so S3A never signs a request — a private bucket
fails with an access error, and the platform's own storage (`s3a://lakehouse/`) is
not readable this way. Read that data through Trino or an Iceberg table, where the
catalog's grants apply.

`spark.hadoop.fs.s3a.endpoint` is unset on purpose: S3A talks to AWS and resolves the
bucket's region, so buckets in any region work. That also means the Spark pods use
their internet egress. They have no NetworkPolicy (Spark is not part of the umbrella
chart), so egress is open today; this feature adds no rule and no Secret. The jars
ship in the image, so the only thing that leaves the cluster is the read itself.

## Shape and the memory budget

One Deployment runs the Connect server as a long-running driver with **Kubernetes as
the cluster manager**. Executors are pods the driver creates on demand and releases
when a query finishes (`spark.dynamicAllocation`, shuffle tracking — no shuffle
service), so an idle platform pays for the driver only:

| Part | Request | Limit | Steady state |
|------|---------|-------|--------------|
| Driver (`spark-connect`) | 250m / 1 GiB | 1 CPU / 3 GiB | 0.5 GiB idle, 1.8 GiB under a large job (2026-10-21) |
| Executor, each (max 2) | 1 CPU / 1.4 GiB | JVM heap `1g` + `384m` overhead | 0.6–1.4 GiB, only while querying |

On the shared 16 GB dev node (`cpx42`, 15613 Mi allocatable) the driver idles at about
0.5 GiB, and a large notebook job took it to 1.8 GiB of the 3 GiB limit on 2026-10-21.
The node itself was the tight part that day, with two executors running: pod requests
15536 Mi (99 % of allocatable), limits 28954 Mi (185 %), and 13920 Mi really in use
(89 %). The request stays at 1 GiB — at 99 % of allocatable a larger request would leave
the driver Pending — only the limit has room. `make node-budget` prints the current
numbers: requests, limits and use per pod, the pods above their request (the kubelet
evicts those first) and the headroom left. Executors are released after
`shuffleTracking.timeout` (180 s) plus the idle timeout, so a query leaves the
node as it was a few minutes later.
Change the numbers in `manifests/spark.yaml` (ConfigMap `spark-connect-config` +
the driver's `resources`) and re-run `make install-spark`; the target restarts the
driver only when the ConfigMap actually changed.

**What a notebook can do to the driver.** Every notebook shares this one driver
(`replicas: 1`), so a result that lands in it lands in everyone's way. `collect()` and
`toPandas()` are capped at `spark.driver.maxResultSize` (512 MiB): above that the call
fails in the notebook with `Total size of serialized results of N tasks (...) is bigger
than spark.driver.maxResultSize` and the driver keeps serving. Without the cap Spark's
default is 1 GiB, as large as the whole heap, so one big result could exhaust it. The
cap does not bound everything a notebook can do to the driver: on 2026-10-21 a load that
turned 250,000-row chunks into DataFrames (tasks of 11 MiB, no big result) got the driver
OOMKilled at the 2 GiB limit, which is why the limit is 3 GiB: heap 1g plus JVM direct
memory up to its default cap of 1g plus about 0.4g of metaspace, code and threads is about
2.4 GiB (arithmetic, not a measurement). When a call fails
that way, write the result to a table (`df.writeTo("<catalog>.<schema>.<table>").createOrReplace()`)
and read it back, or aggregate first; do not raise the limit. The
[notebook cheat sheet](https://github.com/stardelt/stardelt-python/blob/v0.1.0/stardelt/README.md#keeping-the-shared-driver-healthy)
(platform#374) has the patterns that keep the driver small.

## Catalog wiring

`spark-defaults.conf` carries **no catalog block** (platform#317). Spark 4.1 reads
`spark.sql.catalog.*` when it creates the session state, so the helper sends one
`spark.sql.catalog.<name>` group per visible catalog as session configuration:

| Spark property (per catalog) | Value |
|---|---|
| `spark.sql.catalog.<name>` | `org.apache.iceberg.spark.SparkCatalog` |
| `spark.sql.catalog.<name>.type` | `rest` |
| `spark.sql.catalog.<name>.uri` | `http://lakekeeper.stardelt.svc.cluster.local:8181/catalog` (`STARDELT_CATALOG_URI`) |
| `spark.sql.catalog.<name>.warehouse` | the catalog name |
| `spark.sql.catalog.<name>.token` | the signed-in person's token (`_token()`) |
| `spark.sql.catalog.<name>.io-impl` | `org.apache.iceberg.aws.s3.S3FileIO` |
| `spark.sql.catalog.<name>.s3.endpoint` | `http://seaweedfs-s3.stardelt.svc.cluster.local:8333` (`STARDELT_S3_ENDPOINT`) |
| `spark.sql.catalog.<name>.s3.region` | `us-east-1` |
| `spark.sql.catalog.<name>.s3.path-style-access` | `true` |

`spark.sql.defaultCatalog` is `warehouse` when that catalog is among the visible
ones. The helper creates a fresh Connect session (`create()`, not `getOrCreate()`:
the latter returns the process-wide session and would leak one person's catalogs
and token into the next call), sets these properties before the first catalog
call, then loads each catalog once (`setCurrentCatalog`) so `SHOW CATALOGS` lists
the session's catalogs. A catalog the catalog itself refuses is left out with a
one-line warning; if every catalog is refused (typically a token without
`aud=lakekeeper`), `spark()` raises instead of returning an empty session. A
renewed token gets a new session; the previous one is stopped — setting `.token`
again on a live session does not re-key an initialized catalog (gate G5).

Lakekeeper runs without vended credentials, so both engines sign their own S3
requests. Spark gets the credentials from Secret `stardelt-s3-creds` through
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` on the driver and through
`spark.kubernetes.executor.secretKeyRef.*` on every executor; nothing is written
into a config file. Storage credentials stay platform-side (platform#272); the
person's token governs the catalog, not the data files.

## Catalog authorization

The enforcement path (platform#285, platform#304, platform#317):

1. **Authentication is the token.** Lakekeeper validates the bearer against the realm
   (`LAKEKEEPER__OPENID_PROVIDER_URI`, audience `lakekeeper`); without one, every
   request is 401. The hub's and the developer client's tokens get the audience from
   `make sync-catalog-audience` (an `aud-lakekeeper` mapper on `jupyterhub` and
   `stardelt-dev`, declared in `chart/files/keycloak-realm.json`). A hub user picks it
   up on the next spawn or sign-in.
2. **Authorization is OpenFGA.** Every catalog request is decided against tuples in
   OpenFGA (via the OPA bridge sidecar); a valid token without a grant is 403 — for a
   catalog the person may not even browse, Lakekeeper answers 404 instead of revealing
   that it exists. Grants are keyed by `oidc~<sub>`; authenticating does not create a
   user row.
3. **The person is the driver's authority.** The Spark driver does the catalog calls;
   executors only read data files. There is no service client on the Spark path, so a
   session cannot see more than its person. `svc-catalog-spark` stays a realm client
   for a future platform-side path, unused by this one.
4. **The bridge's client is a god credential.** `svc-catalog-bridge` holds
   `project_admin` on the project, so it can change every grant. Treat its Secret like
   the realm admin Secret; it is read by the sidecar, never mounted into other pods.

`make catalog-authz` runs `scripts/catalog-authz-bootstrap.sh`, the one supported
cutover: it takes a CloudNative-PG backup (`pre-authz-*`), upgrades Lakekeeper to
`authz.backend: openfga`, calls `reopen-bootstrap`, re-bootstraps the catalog, runs
`openfga reconcile`, writes the grants and prints the verification table. It is
idempotent; a second run reports every step as already done. `make install-core`
(no IdP) keeps `allowall` through `helm-values/lakekeeper-allowall.yaml`.

To see the grants, use a `project_admin` client (the bridge's) and read the project
assignments:

```sh
kubectl -n stardelt port-forward svc/lakekeeper 8181:8181
# with a token from svc-catalog-bridge (never print it):
curl -sS -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8181/management/v1/permissions/project/assignments
```

**If the catalog is locked out** (403 on everything, e.g. after a bad values edit):
re-run `make catalog-authz` (it re-bootstraps and re-grants); if the bootstrap state is
inconsistent, `kubectl -n stardelt exec deploy/lakekeeper -c lakekeeper --
/home/nonroot/lakekeeper reopen-bootstrap -y`, POST `/management/v1/bootstrap` as
`svc-catalog-bootstrap`, then `openfga reconcile` and the grants. Switching back to
`allowall` is not supported by upstream and is a maintainer decision; a restore from the
`pre-authz-*` backup is the last resort.

## Catalog network access (interim)

Lakekeeper authorizes every request with OpenFGA (above), and the network is the second
control: it narrows *who can even attempt a call* and still holds if authentication ever
regresses. `make install` and `make install-core` apply
`manifests/lakekeeper-network-policy.yaml` (`NetworkPolicy lakekeeper-ingress`): only the
Trino coordinator, Nova, the Spark Connect driver, Airflow task pods and the Lakekeeper
bootstrap Job may open TCP 8181, and only the Trino coordinator may open the OPA bridge's
TCP 8282. Trino workers read Parquet from S3 and Spark executors read data files, so
neither calls the catalog; the JupyterHub single-user egress policy already denies it. The
policy is ingress-only — it does not touch what Lakekeeper reaches (Postgres, OpenFGA, S3)
— and it has no namespace-wide or CIDR rule. Kubelet probes come from the node, so the pod
stays Ready.

It needs a CNI that enforces NetworkPolicy: k3s does (the JupyterHub policies already
rely on its controller), while plain Flannel does not. To remove the interim restriction,
e.g. while debugging the catalog:

```sh
kubectl delete networkpolicy lakekeeper-ingress -n stardelt
```

Re-apply it with `kubectl apply -f manifests/lakekeeper-network-policy.yaml`; `make
uninstall` removes it. A new consumer of the catalog needs its own `podSelector` entry —
do not widen the policy with a namespace selector.

## Verifying the spine

`scripts/verify-spark-iceberg.py` is the repeatable proof: it configures
`warehouse` itself (there is no static catalog), with `TRINO_TOKEN` as the
catalog token, compares `count(*)` and a `GROUP BY` on
`warehouse.covid.covid_summary` between Spark and Trino, then runs a two-way
round trip — Trino writes a table Spark reads, Spark writes a table Trino reads —
in a scratch namespace it drops again. Run it from any pod that can reach both
services with a token that carries `aud=lakekeeper` and `aud=trino`:

```sh
kubectl -n stardelt run spark-verify --image=python:3.11-slim --restart=Never --command -- sleep infinity
kubectl -n stardelt exec spark-verify -- pip install pyspark-client==4.1.4
kubectl -n stardelt cp scripts/verify-spark-iceberg.py spark-verify:/tmp/verify.py
# Put the person's token in the pod without printing it, then:
kubectl -n stardelt exec spark-verify -- sh -c \
  'TRINO_URL=https://trino.stardelt.svc.cluster.local:8443 \
   REQUESTS_CA_BUNDLE=/etc/stardelt/trino-ca/ca.crt TRINO_TOKEN="$TOKEN" \
   python3 /tmp/verify.py'
kubectl -n stardelt delete pod spark-verify
```

## Why a Deployment, not the Spark Kubernetes Operator

The Apache Spark Kubernetes Operator is the right controller once several Spark
applications share a cluster, and it is where the stardelt operator's
`Workspace`/`Pipeline` reconciliation will point. For one long-running app on one
node it is not: its controller alone requests 2 GiB by default, permanently, and
adds CRDs and a webhook to operate a single endpoint Kubernetes can already run.
The CRD path is the follow-up, not a reason to make this node heavier today.

## Limits

Spark Connect has no built-in authentication (upstream points at authenticating
proxies). The endpoint is therefore ClusterIP-only: anyone who can create pods in
`stardelt` can open a session and present any token they hold. The catalog still
decides what that token may read, and a session without a valid `aud=lakekeeper`
token gets 401 — but the endpoint itself is not an identity boundary. Wiring
Connect behind the platform IdP is a follow-up with the CRD work, not something
to expose on an Ingress before then.

Two more limits, deliberately not hidden: row and column masks are Trino-only
(design `multitenant-catalogs.md` §5.8), so a Spark read is governed by table
grants, not by a mask; and the driver/executors sign S3 with the platform key,
so a person with write access to a table can write files the key reaches even
where Trino would refuse. Use Spark where Trino cannot, not to bypass a policy.

If the driver is killed hard, its executor pods can outlive it. They are labelled
and safe to delete:

```sh
kubectl -n stardelt delete pods -l spark-role=executor
```

---
