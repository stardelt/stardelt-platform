# OpenFGA (catalog permission store)

Part of the [stardelt-platform](../README.md) manual.

[OpenFGA](https://openfga.dev/) is the permission store the catalog will check
against: a Zanzibar-style relationship database that answers "may this subject
`browse` / `select` / `create` / `modify` this warehouse, namespace, table or
view, and who may manage its grants". A subject is a person's OIDC `sub`, a
group name or a service client; the roles Lakekeeper assigns live there too.

**It is deployed and backed up, and unused until `make catalog-authz`**
(platform#304, authz 3/8). `helm-values/lakekeeper.yaml` still sets
`authz.backend: allowall`, so no request is checked against these tuples yet
(authentication is on since platform#285 — the token is validated, the tuple is not) —
shipping this release changes nothing a person can do.

```sh
make openfga            # helm release `openfga` + its CNPG Cluster `openfga-pg`
```

`make install` runs the same steps inside its `stardelt-identity` guard (before
Lakekeeper), because authorization is keyed on the IdP's subjects; a bare
`install-core` without an IdP does not get it.

- **Own database, not the catalog's.** CloudNative-PG Cluster `openfga-pg`,
  database `openfga`, 1Gi volume (`manifests/openfga-pg.yaml`). The permission
  tuples must survive a catalog re-bootstrap, which is exactly what the cutover
  is (spike platform#271), so they do not share `lakekeeper-pg`. CNPG generates
  Secret `openfga-pg-app`; the chart reads the DSN from its `uri` key.
- **Memory budget.** Requests 20m / 128Mi, limits 500m / 512Mi for OpenFGA; its
  Postgres asks 50m / 128Mi with a 256Mi limit. Together ~190Mi of requests and
  at most ~450Mi of limits. The #271 spike measured a running OpenFGA at ~50Mi;
  the dev release reports ~16Mi idle, and the 512Mi ceiling leaves room for
  checks.
- **Backups.** Continuous WAL archiving into `s3://backups/openfga-pg/` plus the
  daily base backup `openfga-pg-daily` (`immediate: true`, so a fresh install
  has one right away). Guards: `make verify-backup-config PG_CLUSTER=openfga-pg`
  (config only, runs in `make install`) and `make verify-backups-openfga`
  (bucket vs. database).
- **No authentication of its own.** The chart ships OpenFGA unsecured; the
  NetworkPolicy `openfga-ingress` (`manifests/openfga-network-policy.yaml`) is
  its protection — only the Lakekeeper catalog pod and its migration Job may
  reach 8080/8081, so no other workload can grant itself permissions. Nothing
  is exposed outside the cluster.
- **Image.** `openfga/openfga:v1.22.1`, pinned explicitly so a chart bump cannot
  move the application; it is the pair Lakekeeper 0.15 ships with, and Lakekeeper
  0.12.2, which is on the lab today, requires OpenFGA >= 1.11. Chart pin:
  `OPENFGA_VERSION` in the Makefile. Licence:
  Apache-2.0 (permissive policy, `stardelt-docs` → architecture/licenses).

---

# Catalogs

A `Catalog` is one data domain: the name users type (`finance.orders`) and, in
Lakekeeper, the name of one warehouse. It is a CRD (`catalogs.stardelt.io`, short
`cat`) — owner group, optional storage overrides, grants — so a catalog is a
cluster object like everything else, not a row in a UI (platform#305, design
`design/multitenant-catalogs.md` §4.2).

```yaml
apiVersion: stardelt.io/v1alpha1
kind: Catalog
metadata:
  name: finance              # 1-40 lower-case letters and digits, starts with a letter
  namespace: stardelt
spec:
  lakehouseRef: { name: main }
  displayName: "Finance"
  description: "Contracted revenue, orders and billing."
  owner: stardelt-finops     # exactly one group: ownership means manage, not select
  storage:
    keyPrefix: domains/finance   # default: the catalog name
  grants:
    - { group: stardelt-finops, verb: browse }
    - { group: stardelt-analytics, verb: select }
```

```sh
kubectl apply -f finance.yaml
make access-sync-now            # run the CronJob once, wait, print its log
kubectl -n stardelt get cat finance -o jsonpath='{.status.phase} {.status.warehouseId}'
# Ready 5f1c2bde-…             (within 2 minutes without access-sync-now)
```

CronJob `access-sync` (`manifests/access-sync.yaml`) runs every 2 minutes — in the
`stardelt-identity` guard of `make install`, because the job signs in to the catalog
as `svc-catalog-operator`; `make access-sync` refreshes its script ConfigMap and
applies it. It is the part of the operator's job the operator cannot do yet: it
builds objects and Jobs, has no HTTP client, so a CronJob holds this loop until the
operator absorbs it. The design stays the operator's: nothing here is a second
control plane, and the Catalog controller keeps its dry-run plan.

Status fields:

| Field | Meaning |
|-------|---------|
| `status.phase` | `Ready` (a warehouse of that name exists) or `Invalid` (a rule failed; no warehouse was created) |
| `status.warehouseId` | The Lakekeeper warehouse id — Nova and the permission bridge read it instead of guessing by name |
| `status.conditions[CatalogReady]` | `reason`/`message` name the rule when `Invalid`; `observedGeneration` says which spec the verdict is for |
| `status.conditions[GrantsReady]` | `True` when every declared group's grants are on the warehouse; `False` with `reason` `UnknownGroup` (the realm has no such group) or `RoleConflict` (a Lakekeeper role of that name is not the sync's) |
| `status.conditions[Drift]` | `True` with `reason: ForeignGrants` and a **count** when the warehouse carries grants held by a subject the sync does not manage (the platform's service accounts at project level, the bootstrap user's ownership, a person); `False`/`Clean` otherwise. No names |

The job is idempotent: an existing warehouse is **adopted** (no storage change, no
credential refresh — the bootstrap Job owns the platform warehouse's credential),
a converged tick writes no status at all, and a second `make access-sync-now` leaves
`resourceVersion` alone. Names the engine or the platform owns (`system`,
`information_schema`, `memory`, `tpch`, `tpcds`, `jmx`) are `Invalid`, never a
warehouse.

**Not built: per-catalog buckets.** Every catalog shares the platform bucket
(`stardelt-s3-creds`) and is separated by `storage.keyPrefix`. A `Catalog` with a
`storage.bucket` other than the platform bucket is `Invalid/BucketsNotBuilt` — until
per-catalog buckets exist, storage isolation cannot be enforced (internal note
§2.4), and users never hold storage credentials, so accepting the field would
advertise an isolation that is not there.

**Deleting a Catalog deletes no data** (design §2.5): the warehouse and its tables
stay, and the job reports it as `orphan warehouse <name>` on each tick. Removing a
catalog for good is a maintainer decision on the warehouse, not a side effect of
`kubectl delete catalog`.

## Grants: groups become roles, members become assignees

The same CronJob writes the catalog's grants (platform#306). Grants are **groups**,
never people (design `design/multitenant-catalogs.md` §5.1–§5.3), and Lakekeeper's
OpenFGA authorizer stores role membership itself, so the job materialises the realm
into the catalog:

- every declared group (the `owner` and each `grants[].group`) becomes a Lakekeeper
  **role of the same name**, description `stardelt group <group>`;
- the group's Keycloak members are the role's **assignees**, by OIDC `sub`
  (`oidc~<sub>`) — valid before a person has ever signed in, and removed on the next
  tick when they leave the group;
- each grant becomes a grant on the warehouse by the group's role, which Lakekeeper
  inherits down to every namespace, table and view, existing and future:

| `verb` | Lakekeeper relation | Means |
|--------|--------------------|-------|
| `browse` | `describe` | metadata and existence; also the ability to address the catalog |
| `select` | `select` | read data |
| `write` | `write` | insert, update, delete, merge, alter, replace; not drop or rename |
| `create` | `create` | create schemas and tables inside it |
| `manage` | `manage_grants` | grant and revoke on this warehouse — **not** `ownership`, which would include every data right |

Drop and rename are platform-administrator actions in v0.4 (the `project_admin` role); a
data engineer rebuilds a table with `CREATE OR REPLACE TABLE`, which the bridge checks as
a `commit`.

The owner group gets `manage_grants` and nothing else. The admin group
(`stardelt-admins`) always gets a role, its members, and `project_admin` on the
project, so every platform administrator holds that through the group. `superset` —
the PASSWORD account Superset connects with — has no Keycloak user, so
`STATIC_ASSIGNEES` (`manifests/access-sync.yaml`) adds it to `stardelt-users`.

The job owns only what it created, and only where it was declared: a grant on a
managed warehouse held by one of its own roles that the Catalog does not declare is
removed; a grant held by anyone else is left alone and counted in `Drift`. A role
whose description does not start with `stardelt group ` is never edited — a
same-named role is reported as `RoleConflict` instead.

```sh
kubectl -n stardelt get catalog warehouse -o jsonpath='{.status.conditions}'
make access-sync-now            # log: one line per role (counts only) and per catalog
```

**Not built: Trino enforcement.** Trino still authorises from its file rules
(`helm-values/trino-identity.yaml`); the grants above are enforced where the catalog
is asked — by Nova today, by the OPA bridge when Trino's `access-control` moves to it
(a later authz step). Until then a person's Trino queries are not narrowed by
`Catalog.spec.grants`.

## More catalogs: Trino and the bridge

A `Catalog` is usable when three things agree, and `make catalogs` derives all three
from the objects themselves (platform#308):

```sh
kubectl apply -f finance.yaml      # the Catalog from above
make catalogs                      # access-sync → bridge mapping → Trino
```

1. **Lakekeeper / the OPA bridge.** The warehouse comes from access-sync (above). The
   bridge needs every Trino catalog name mapped to its warehouse: an unmapped catalog
   falls under `allowUnmanagedCatalogs: true`, which permits it *without asking
   Lakekeeper* — so its grants would not be enforced. The mapping is chart value
   `OPABridge.catalogs` (`[{trinoCatalog, lakekeeperWarehouse}]`), rendered into
   ConfigMap `lakekeeper-opa-policies`, key `catalogs.rego`:

   ```sh
   kubectl -n stardelt get cm lakekeeper-opa-policies -o jsonpath='{.data.catalogs\.rego}'
   ```

   `helm-values/lakekeeper.yaml` keeps the static `warehouse` entry and is never edited
   for a new catalog: `make catalogs` passes `--set-json OPABridge.catalogs=…` built
   from the live objects (Helm replaces the array, so the argument carries `warehouse`
   as well; with nothing new it prints nothing and the values file stands).
2. **Trino.** One properties file per Ready Catalog, rendered by
   `scripts/render-catalogs.sh` from `helm-values/catalog.properties.tmpl` — the identity
   overlay's `warehouse` block with `iceberg.rest-catalog.warehouse=@NAME@` — into
   `.build/catalogs/<name>.properties` (git-ignored) and passed to the chart as
   `--set-file catalogs.<name>=…` by `make trino`. `warehouse` itself stays in
   `helm-values/trino.yaml` + `helm-values/trino-identity.yaml`. `--set-file` and not
   another values file because the *set* of catalogs is dynamic — a values file would have
   to be generated per release anyway, while `--set-file` adds one key on top of the two
   tracked files and edits neither. (Helm merges the `catalogs` map key by key: a second
   `-f` that repeats `catalogs.warehouse` replaces that catalog's whole properties block —
   which is why the identity overlay repeats it verbatim. `--set-file` keeps that
   arrangement.) `scripts/check-catalog-template.sh` (`make lint`) keeps the template
   identical to the overlay's block.
3. **The engine.** Adding or removing a catalog rolls the Trino **coordinator and
   worker** — about a minute. The chart mounts the catalog ConfigMap read-only, so Trino
   cannot load a catalog live, and the coordinator restart drops running queries: pick a
   quiet moment. A second `make catalogs` with nothing new renders the same ConfigMap and
   leaves both pods (and their age) alone. Removing a `Catalog` removes its Trino catalog;
   its warehouse and data stay, as with `kubectl delete catalog`.

The three modes are what the targets call (a cluster is needed; `make lint` runs only
the template check):

```sh
bash scripts/render-catalogs.sh list        # Ready Catalogs except warehouse, one per line
bash scripts/render-catalogs.sh trino-args  # the --set-file arguments make trino passes
bash scripts/render-catalogs.sh bridge-arg  # the --set-json argument make catalogs passes
```

A `Catalog` created by something other than this page — Nova's catalog browser, or a `kubectl
apply` — is still a `Catalog`: it has a Lakekeeper warehouse and a maintenance CronJob, and no
Trino catalog until `make catalogs` runs. Until then its maintenance run fails with
`CATALOG_NOT_FOUND`. `make verify-maintenance` catches it: `✗ trino <name> is Ready but
ConfigMap trino-catalog has no <name>.properties — hint: make catalogs` (platform#914).

A Catalog that is not `Ready` gets nothing on either side, and a name the operator would
reject is skipped with a warning. On a cluster without the Catalog CRD (no operator,
`make install-core`) all three print nothing, so `make trino` keeps the single `warehouse`
catalog. The umbrella chart path (`make chart-install`) is not wired to this yet: it still
renders its own static `warehouse` catalog from `chart/values.yaml`.

## The bridge contract

The bridge answers questions Trino writes, so the questions have to be known before Trino
is pointed at it (`platform#311`). `make bridge-capture` records them from the coordinator's
own image and `make bridge-replay` asks the live bridge the recorded questions — no
hand-written request shape, no guess about what 480 sends (`platform#333`).

**What Trino 480 sends.** A `POST` to the policy URI (the bridge serves the package as
`/v1/data/trino/allow`), body `{"input": {context, action}}`:

```json
{"input": {
  "context": {"identity": {"user": "<sub>", "groups": []},
              "softwareStack": {"trinoVersion": "480"},
              "properties": {}, "queryId": "20261021_061336_00000_a9b5n"},
  "action": {"operation": "AccessCatalog",
             "resource": {"catalog": {"name": "finance"}}}}}
```

- **Per question.** `AccessCatalog`, `ShowSchemas` (resource `catalog`), `ShowTables` /
  `ShowColumns` (`schema` / `table`), `CreateSchema`, `CreateTable`, `CreateView`,
  `DropSchema`, `DropTable`, `InsertIntoTable`, `SelectFromColumns`, `ExecuteQuery`
  (no resource), `SetSystemSessionProperty` (`systemSessionProperty`),
  `ExecuteProcedure` and `ShowFunctions` (`function` / `schema`), and the query-ownership
  operations (`user`).
- **Batched.** With `opa.policy.batched-uri` set, as the bridge's chart config does,
  `FilterCatalogs`, `FilterSchemas`, `FilterTables` and `FilterColumns` arrive at
  `/v1/data/stardelt/batch` (the front entry point, below) as one request: `{"action": {"operation":
  "FilterCatalogs", "filterResources": [{"catalog": {"name": "system"}}, …]}}`, answered with
  `{"result": [<allowed index>, …]}`. The index order is the order the resources were
  sent in, and it is not sorted — the answer is a set of positions, not a list of names.
  Without that URI the plugin sends one request per resource instead.
- **What the bridge must never see.** `FilterFunctions` and
  `CreateViewWithSelectFromColumns` exist in the plugin's interface, but 480 never sends
  them in this battery: `SHOW FUNCTIONS` asks `ShowFunctions`, and view creation asks
  `CreateView` plus the underlying `SelectFromColumns`. `ImpersonateUser` is asked only
  when the server authenticates a principal and then acts for a different user — which
  is what Superset does after `platform#310`; it is captured separately (`platform#342`,
  see below) because the battery runs without authentication.
- **The two facts the bridge relies on:** every data question carries
  `context.identity.user` (it becomes `oidc~<sub>`, the Lakekeeper user) and a catalog
  name under `resource.<kind>.catalogName` (or `resource.catalog.name`). A body that
  lacks either gets `false` **before** any call to Lakekeeper, which is why the
  Lakekeeper audit log shows no batch-check at all.

**The front entry points and the catalog decision table** (`platform#359`). Every question
that reaches Lakekeeper costs about 0.15 s *per distinct catalog* (PR #364 measured it: one
check 0.11 s, eight distinct warehouses in one request 0.9 s), so `SHOW CATALOGS` cost 1 to
2 s cold and every query paid about 350 ms — the reason `platform#311` rolled the switch
back. The price is Lakekeeper's per-entity authorization, not transport, so batching cannot
remove it; the answers have to come from somewhere else.

They come from a table CronJob `access-sync` already computes every two minutes. After the
grants of a tick are written, it publishes the catalog-level permissions as OPA data
(`scripts/access-sync-job.py`, `PUT /v1/data/stardelt/access` on the bridge):

```json
{"generatedAt": 1761055200,
 "catalogs": {"gold": {"drift": false, "all": ["<admin sub>"],
                      "browse": ["<sub>", "superset"], "select": ["<sub>"],
                      "write": [], "create": []}}}
```

Each list holds the exact string Trino sends as the user (the Keycloak `sub`, or a bare
`STATIC_ASSIGNEES` principal such as `superset`), with Lakekeeper's verb implications
already applied (`write` implies `select` implies `browse`; `create` implies `browse`), and
`all` is the platform administrators, who hold `project_admin` in Lakekeeper. Trino is
pointed at `data/stardelt/allow` (`opa.policy.uri`) and `data/stardelt/batch`
(`opa.policy.batched-uri`) — `stardelt.front.rego` in `helm-values/lakekeeper.yaml` — and the
two rules answer:

- **the catalog-level questions** (`AccessCatalog`, `FilterCatalogs`) from the table, in both
  directions, whenever the table is fresh and the catalog has no drift. That is the
  acceleration: zero Lakekeeper calls;
- **the hot object-level operations** (`SelectFromColumns`, `InsertIntoTable`, `CreateSchema`,
  `CreateTable`, `CreateView`, `ShowSchemas`/`FilterSchemas`, `ShowTables`/`FilterTables`,
  `ShowColumns`/`FilterColumns`) as an **allow-only** fast path. A denial is never the
  table's: the chart's rules ask Lakekeeper, which also knows object ownership and any grant
  below the catalog;
- **everything else** — drops, renames, alters, `ExecuteQuery`, session properties,
  impersonation, functions — by the chart's own rules, unchanged.

The table is an accelerator, never the authority. It is ignored when it is older than six
minutes (the sync publishes every two, so a normal table is at most ~2.5 minutes old), when a
catalog is missing from it (a `Catalog` that became Ready since the last tick), and when that
catalog carries `drift` — a grant on its warehouse held by a subject the sync does not
manage, which it cannot enumerate and therefore must not answer for. A failed push is logged
as `opa data: not published (<status>)` and never fails the sync tick: the bridge then falls
back to Lakekeeper and only the latency changes. A tick that removes a grant deletes the
table first; the bridge asks Lakekeeper until the next publish, a few seconds.

**The trust note.** The table is derived from the same `Catalog` objects the sync writes to
Lakekeeper; Lakekeeper stays the authority. The table is valid for at most six minutes
(usually 2.5), it can only widen answers at object level where Lakekeeper confirms them by
default, and its write API is reachable only from the `access-sync` and Trino-coordinator
pods (NetworkPolicy `lakekeeper-ingress`) — the same trust boundary as the bridge's own
Lakekeeper credential.

Three checks keep the accelerator honest. `make bridge-differential`
(`scripts/bridge-replay.sh --differential`) asks the front
entry points and the chart's own rules the same question for every catalog, every existing
table and every principal (including one that is in no group) and fails on any difference —
there is no "known difference". `scripts/test_bridge_policies.py` (CI, `make
test-bridge-policies`) proves the same against a stub Lakekeeper that counts calls, so "a
fresh table answers without asking" is a number, not a claim. `make bridge-latency` measures
it. `make lint` (`scripts/check-bridge-uri.sh`) keeps the paths in this file,
`scripts/lib/bridge.sh` and the values file identical, so the replay asks what the engine
asks.

**Who may impersonate whom** (`platform#342`). Exactly one principal may act as someone
else, and only as a person: `superset`, the PASSWORD account Superset authenticates to
Trino with, sending the signed-in person's Keycloak `sub` as `X-Trino-User`
(`platform#310`). The bridge's `trino.stardelt.rego` allows that one case —
`ImpersonateUser`, `context.identity.user == "superset"`, and
`action.resource.user.user` matching the lowercase UUID shape of a `sub` — and denies
everything else: any other asking principal (Nova and the notebooks forward the person's
own token and never name another person) and any target that is not a `sub` (`admin`, a
service account, an uppercase or otherwise non-UUID string). It is the same rule the file
authorizer applies until the switch (`helm-values/trino-identity.yaml`,
`impersonation`), so pointing Trino at the bridge does not widen or narrow who may act as
whom. The replay's `impersonation` table asks all six cases, allowed and denied.

**The fixture and the replay.** `scripts/tests/fixtures/trino-opa-requests.json` holds one
request per distinct (path, operation, resource kind) — 21 shapes from the 131-request
battery against `trinodb/trino:480` on 2026-10-21, plus the `ImpersonateUser` shape from a
second capture that day (same image, a throwaway coordinator that authenticates the name
`superset` and asks to act as a person; it carries no `queryId` because Trino asks it while
the session is created). The capture user is `<sub>` in every body, and `<peer>` is the
second user in the query-ownership questions. Refresh the battery after a Trino upgrade:

```sh
make bridge-capture    # throwaway Trino + a stub authorizer that allows and records;
                       # deletes its pod and ConfigMap, including on failure
make bridge-replay     # the contract, the probes, the must-work reads, the matrix,
                       # the impersonation rows
bash scripts/bridge-replay.sh --data-only   # only the matrix and impersonation (the gate)
bash scripts/bridge-replay.sh --differential   # the front entry points against the
                       # chart's own rules: every catalog, every table, every principal
make bridge-latency    # FilterCatalogs with every catalog: five cold runs, the median
                       # must stay <= 0.2 s, and one AccessCatalog/SelectFromColumns
                       # question <= 0.05 s, with the old path's answers unchanged
```

`make bridge-capture` runs the coordinator image with no authentication, the `tpch` catalog
and four `memory` catalogs (`warehouse`, `finance`, `product`, `sandbox`), an OPA authorizer
pointing at a python stub in the same pod, and executes a battery of statements covering
catalog/schema/table DDL and DML, `SELECT`, `EXPLAIN`, `SET SESSION`, `SHOW …`, the system
tables and a second user's query. The stub answers `{"result": true}` (and every index for
a batch) and appends every body to `/captures/requests.jsonl`; the pod is labelled
`app.kubernetes.io/name=trino-capture`, so NetworkPolicy `lakekeeper-ingress` keeps it away
from the real bridge. Two statements in the battery are kept verbatim from the ticket even
though 480 cannot parse them (`SHOW FUNCTIONS LIMIT 3`, and `n_nationkey` on a TPCH table,
whose columns have no `n_` prefix); the working variants next to them are what reach the
authorizer.

`make bridge-replay` asks every captured shape for the three seed people and one
`stardelt-admins` member (their Keycloak `sub`), from a throwaway pod labelled like the
coordinator so `lakekeeper-ingress` admits it to 8282. It prints five tables — the
contract, the operations 480 did not send, the reads the bridge must allow (`SELECT 1`,
`information_schema`, and `system.runtime.nodes` — whose bridge answer is still `allow` for
everyone, while the file rules have made the catalog administrator-only since
platform#363; for an ordinary person the engine refuses before the bridge is asked), the
permission matrix, and the
impersonation rows — and exits 1 on an HTTP error, a non-JSON body, an empty body, a
missing `result`, a wrong matrix or impersonation row, or a must-work read that is denied.
`--data-only` keeps the matrix and the impersonation rows: that is the regression check
`make catalog-authz` runs before it trusts the bridge, and `make catalog-enforce`
(`platform#311`) must run it too.

**The decision for unmapped catalogs.** The bridge gets `allowUnmanagedCatalogs: true`, so
any catalog that is not in `catalogs.rego` is allowed without asking Lakekeeper. That is
deliberate and it covers exactly the catalogs this platform does not manage: `system`,
`tpch` and `tpcds` (the engines' built-ins). Every `Catalog` object is mapped by
`make catalogs`, so a data catalog is never in that set; if one ever is (a typo, a render
that printed nothing), its grants are not enforced — that is the failure mode
`make verify-catalog-permissions` and `make bridge-replay` are for. The bridge still allows
those three catalogs for everyone; what a person may actually reach is decided one layer
up, because both authorizers must allow: the `catalogs` rules in
`helm-values/trino-identity.yaml` reserve `system`, `tpch` and `tpcds` for administrators
(platform#363, "Who may read what"). `SELECT * FROM system.runtime.nodes` and
`SHOW FUNCTIONS FROM tpch.tiny` are therefore administrator-only, while the bridge's own
answers about them are unchanged — the replay keeps asking them, because it tests the
bridge, and the differential compares the bridge's two paths, not the file rules.

**What the capture changed** (`platform#333`, before the switch):

| operation | before | after | why |
|---|:--:|:--:|---|
| `SetSystemSessionProperty` | denied for everyone | allowed | Trino asks it before *any* `SET SESSION`; the chart had no rule, so `SET SESSION query_max_run_time` failed for every person |
| `FilterFunctions` on a managed catalog | denied (empty `SHOW FUNCTIONS`) | allowed with `browse` | a function list is metadata; it follows the same `get_config` question as the catalog |
| `AccessCatalog`, `SelectFromColumns`, `InsertIntoTable`, `CreateSchema`, `FilterCatalogs` | correct | correct | the 21-shape table showed no defect here — the nine-row matrix and the replay agree |
| `ImpersonateUser` | denied for everyone | allowed for `superset` acting as a `sub`; denied otherwise | **platform#342**: Trino asks it for Superset's impersonation (`platform#310`), so the switch would have refused every Superset query. The bridge now applies the same rule as the file authorizer. |

The three rules are one small policy in `helm-values/lakekeeper.yaml`
(`OPABridge.customPolicies.trino.stardelt.rego`), proved by `make bridge-replay`, which
also carries the `warehouse.covid.covid_summary` row in place of the removed demo schema. The
symptom the reporter saw after `make catalogs` in `platform#308` — every catalog question
`false`, no batch-check in Lakekeeper — does **not** reproduce: the chart's
`checksum/opa-policies` annotation rolls the bridge pod whenever the generated
`catalogs.rego` changes, and the replay is correct for dev-outsider at t+0, +10, +30, +60
and +120 s after the rollout. Sending the same question without `context.identity.user`, or
with the catalog name only as a flat `catalogName`, does reproduce it exactly (`false`, no
batch-check): the bridge fails closed before it calls Lakekeeper. The capture in this
repository is the request shape that avoids that.


## Who may read what

The permission model, in the words a person uses:

- A **group** holds the permission, never a person. Keycloak groups (`stardelt-users`,
  `stardelt-admins`, a customer's own like `finops`) are the only thing a `Catalog`'s
  `grants` can name, and membership is changed in the IdP — one place, one audit trail.
- A **catalog** is a domain (`finance`, `product`, `sandbox`, `warehouse`, …). Each one has
  an owner group and a list of grants, one per group and verb.
- Five verbs, and they are cumulative in the obvious way:

  | verb | what a person may do |
  |---|---|
  | `browse` | see the catalog in a list, open it, list its schemas, tables and columns |
  | `select` | read rows (`SELECT`) |
  | `write` | insert, update, delete, and change a table |
  | `create` | create schemas and tables inside it |
  | `manage` | grant and revoke, transfer ownership, drop and rename the catalog — what the owner group holds; it does not imply `select` |

  Drop and rename are platform-administrator actions in v0.4 (the `project_admin` role);
  a data engineer rebuilds a table with `CREATE OR REPLACE`, which the bridge checks as a
  `commit`.

  A group with `browse` and no `select` sees the catalog and gets a refusal as soon as it
  reads a row: "may look, may not read" is a supported state (that is `product` for the
  `finops` group in the dev seed).

**Where it is enforced: at the query engine, for everybody.** Trino asks the permission
bridge — the OPA sidecar of the catalog, which answers from Lakekeeper's OpenFGA store —
before every catalog, schema, table and column operation (`make catalog-enforce`,
`platform#311`). Two consequences worth knowing:

- The engine's user is the person's **Keycloak user id** (`sub`), not a username, because
  that is the string the catalog's role assignees are keyed on.
- Every client goes through the same check, because every client goes through the same
  engine with the person's own token: **Nova** (the SQL editor and every catalog call),
  **Superset** (which impersonates the signed-in person from its service account,
  `platform#310`), a **notebook** (`stardelt.sql()`, `stardelt.write_df()`), a `trino`
  CLI with a Keycloak token, and **Airflow** pipelines (which run as their own service
  account, a member of a group like any other principal — `STATIC_ASSIGNEES` covers
  accounts that have no Keycloak user, like Superset's `superset`).
- Both access controls apply at once: the bridge decides *which catalogs and rows of
  metadata* a person may reach, the file rules in `helm-values/trino-identity.yaml`
  decide *query visibility* (own queries only, administrators all) and keep the
  cluster-internal tables away from ordinary users. A statement must be allowed by both.
- Trino takes its catalog list from the same answer, so a person sees exactly the catalogs
  their groups grant — in the SQL editor, in Nova's catalog switcher (a 30-second cache),
  in Superset's catalog list and in a notebook's `SHOW CATALOGS`. **`system`, `tpch` and
  `tpcds` are for administrators** (platform#363, below): they are the engine's own
  catalogs, not managed here, so no `Catalog` grant can describe them — and the bridge lets
  every catalog it does not manage through, which is why the file rules, not the bridge,
  are the layer that reserves them.

**The three engine catalogs are administrator-only** (`platform#363`). `system` is
Trino's own metadata catalog — `runtime.nodes`, `runtime.queries`, `runtime.tasks`,
`metadata.*`, `jdbc.*` — and `tpch`/`tpcds` are the sample connectors the chart mounts.
Nobody's data lives in them, so no `Catalog` grant can express who may read them, and
nobody needs them for ordinary work: Nova's query log has its own store, cancel goes
through the statement's `nextUri`, Superset reflects through `information_schema`/`SHOW`,
and notebooks use the managed catalogs. The reservation is a `catalogs` section in
`helm-values/trino-identity.yaml` — administrators `all`, `(system|tpch|tpcds)` `none`,
then a catch-all `all` for every other catalog (first match wins; without the catch-all a
catalog no rule matches would be denied, which would hide the managed five too). Trino
hides a catalog from `SHOW CATALOGS` when a person's catalog access is `none`, so the
shrink is immediate in the SQL editor, Nova, Superset and notebooks, and a statement that
names one is refused by the engine:

```text
PERMISSION_DENIED: Access Denied: Cannot access catalog tpch
```

Built-in functions are **not** catalog access: `SELECT abs(-1)`, `now()`,
`SHOW FUNCTIONS`, `SHOW SESSION LIKE 'query_max%'` and `EXPLAIN SELECT 1` are the
acceptance battery and stay available to everyone. The documented smoke test
`SELECT * FROM system.runtime.nodes` is administrator-only from here on; use
`SELECT 1` as an ordinary person. `CALL system.runtime.kill_query` is administrator-only:
the `catalogs` rule above refuses `system` to everyone else before the bridge's
`KillQueryOwnedBy` rule (`helm-values/lakekeeper.yaml`, platform#398) is asked, so the
bridge answers administrators only (platform#862). A person cancels their own query with
Nova's Cancel button, which uses `DELETE /v1/statement` and not this rule. Superset's
catalog list comes from `SHOW CATALOGS`, so it follows the person; adding a dataset and
previewing it read `information_schema`, and only the *table comment* lookup uses
`system.metadata.table_comments` — that one is denied now, Superset catches it and the
dataset has no comment (its dialect's own `PERMISSION_DENIED` fallback never fires,
because SQLAlchemy wraps the driver error before the dialect sees it).

To see it: a person's `SHOW CATALOGS` lists only the managed catalogs, an
administrator's still lists the three extra, and the three engine catalogs answer
administrators only. The policy is live when the coordinator has rolled on the
`checksum/access-control-config` annotation and `/etc/trino/access-control/rules.json`
inside the pod carries the `catalogs` section — the two places to look when a person
still sees `tpch`.

**What is not covered.**

- **No row or column rules.** The bridge answers per object (catalog, schema, table,
  column list); there are no filters or masks yet. A person with `select` reads every row
  of every table in the catalog.
- **Spark Connect has no authentication of its own.** The endpoint is ClusterIP-only,
  the single-user pods are its clients (the egress rule in `helm-values/jupyterhub.yaml`,
  `manifests/spark.yaml`), and `stardelt.spark()` hands the person's token to the catalog,
  so the *catalog* decides what a Spark session may read (`platform#317`). The Connect
  endpoint itself does not verify who is calling, though: do not expose it beyond the
  namespace, and do not treat a Spark read as an audited read of the same standing as a
  Trino one.
- **The catalog's own API** is a second door. `svc-catalog-*` clients authenticate to
  Lakekeeper directly (Nova writes uploads that way); the grants there are the same ones,
  because it is the same store.

**Recovery.** `make catalog-enforce-rollback` puts Trino back on the file rules alone, in one
command, and says so when it is done: every signed-in person addresses every catalog again
and the `Catalog` grants enforce nothing. The reason to roll back is a cell of the
verification table failing — including the latency cell, which is what a per-catalog
authorizer round trip shows up in first. An unreachable bridge is *not* such a reason:
fail-closed is the design, so fix the bridge rather than the switch (`SELECT 1` is denied
while it is down). `make verify-catalog-permissions` and `make bridge-replay --data-only`
answer the same questions the engine asks, without touching Trino, so they are the safe way
to look before switching again.

The rollback takes the bridge out of the authorization path and changes nothing else: the
principal stays the Keycloak `sub`, and the group file stays the one CronJob `access-sync`
writes by `sub` (platform#312). There is therefore no window in which the file and the
engine compare different strings, and no second writer to switch off first. It still runs
`deps` first (a missing tool must not stop it half-way) and waits for the coordinator
rollout before it prints that it is done; a failure is recovered by running the same target
again, which is idempotent.

**One known limit.** The bridge's administrator list (`OPABridge.adminUsers`) is rendered
from the `stardelt-admins` line of ConfigMap `trino-group-file` when a Lakekeeper release
is applied. A person added to `stardelt-admins` afterwards becomes an administrator in
Trino's file rules on the next sync (30 s), but sees everybody's queries in
`system.runtime.queries` only after the next `make catalog-enforce` (or `make catalogs`,
`make catalog-authz` — anything that re-renders the bridge). The bridge still refuses them
nothing else: the file rules grant the same visibility and the catalog grants are
unchanged.

---

## Dev seed: the maintainer layout is the baseline, fixtures are opt-in

The dev seed is a small permission set you can check by hand, for development and for
demoing the model (platform#309). Its **baseline is the layout the maintainer runs** —
`warehouse` (administrators only) and `shared`, granted read and write to
`stardelt-users` (`dev/seed/catalogs.yaml`) — and the seed does not touch the Catalog
objects at all unless you ask it to (layout decision, platform#365).

`make seed-dev-access YES=1` creates the cheap, invisible half:

| object | what it is |
|---|---|
| group `finops` | owns `finance` (when the fixtures are applied) |
| group `analytics` | owns `product`, may read `finance` (when the fixtures are applied) |
| users `dev-finops`, `dev-analytics`, `dev-outsider` | one person per row; all also in the default group `stardelt-users` |
| the existing user `analyst` | added to `analytics` (a person, not a seed user) |

It also runs one access-sync so the new memberships reach Lakekeeper now rather than on
the next two-minute tick, and it prints that no Catalog was touched. It never recreates a
Catalog that does not exist: if you deleted one, that was a decision, not drift. When you
do want the file applied — a fresh cluster, or a deleted baseline catalog back — say so:

```sh
SEED_CATALOGS=1 make seed-dev-access YES=1   # apply dev/seed/catalogs.yaml (the five baseline Catalogs)
```

The **permission fixtures** are opt-in, for people who want group differences to exercise:
`make seed-permission-fixtures YES=1` applies `dev/seed/fixtures/permission-fixtures.yaml`
(Catalogs `finance`, `product`, `sandbox` with different grants per group) and creates the
`schema seed`, `table nation` (25 rows with the TPCH nation columns, built from
`sequence(0, 24)` — no read of `tpch`, which is administrator-only since platform#363) in
each. They need the seed's
people and groups, so run `make seed-dev-access YES=1` first; `make
unseed-permission-fixtures YES=1` deletes exactly those three Catalogs and never a
baseline one. Deleting a Catalog deletes no data, so the `seed` schema stays in the
fixture warehouses (orphan warehouses to the next sync tick).

`dev-outsider` gets no domain group: it is the row of `false`. All three seed users are
marked in Keycloak with the attribute `stardelt-managed=seed`; that attribute is what
`make unseed-dev-access` deletes, so a user or group this seed did not create is never
touched. Keycloak 24+ drops undeclared user attributes on a fresh realm, so the seed also
sets `unmanagedAttributePolicy=ADMIN_EDIT` on the realm's user profile — administrators
may write the marker, users see no extra attribute.

**Passwords are generated at run time, 24 random characters, and are stored only in
Secret `dev-seed-users`** (one key per user name). Nothing prints them, and they are never
committed:

```sh
kubectl -n stardelt get secret dev-seed-users -o jsonpath='{.data.dev-finops}' | base64 -d
```

`make verify-catalog-permissions` proves the permissions against the OPA bridge by asking
it the same questions Trino asks (`POST http://lakekeeper-opa:8282/v1/data/trino/allow`,
from a throwaway pod labelled like the Trino coordinator so `lakekeeper-ingress` admits
it). Its expectation is **computed from the live Catalog objects and the live Keycloak
group memberships**, not from a table in the script (platform#365): a person may do a
verb when the union of their groups' grants holds it — `write ⇒ select ⇒ browse`,
`create ⇒ browse` — and a member of `stardelt-admins` may do everything. Edit a grant in
Nova and the next run follows it; no script change. Ownership is not a data verb: the
owner group gets `manage_grants` only.

| verb | question |
|---|---|
| `browse` | `AccessCatalog <catalog>` |
| `select` | `SelectFromColumns <catalog>.seed.nation` |
| `write` | `InsertIntoTable <catalog>.seed.nation` |
| `create` | `CreateSchema <catalog>.seed_probe` |

A table question on a table Lakekeeper does not have is answered `false` for everyone, so
`select`/`write` rows are asked only where `<catalog>.seed.nation` exists (the fixtures
create it in `finance`, `product` and `sandbox`) — the admin's own answer is the existence
check. Everywhere else only `browse` and `create` rows are asked. With the fixtures the
differentiated rows are the point:

| catalog | `dev-finops` | `dev-analytics` | `dev-outsider` |
|---|:--:|:--:|:--:|
| `finance` | browse, select, write, create | browse, select | — |
| `product` | browse | browse, select, write, create | — |
| `sandbox` | all four | all four | all four |

On the maintainer layout every grant is uniform, so every person passes every row — the
oracle says so, and the equality itself is the check that group wiring works.

```sh
make seed-dev-access YES=1              # groups, people, Secret; no Catalog touched
SEED_CATALOGS=1 make seed-dev-access YES=1   # also apply dev/seed/catalogs.yaml
make verify-catalog-permissions         # PASS/FAIL table from the live objects; exit 1 on a mismatch
make seed-permission-fixtures YES=1     # opt-in finance/product/sandbox + seed.nation
make unseed-permission-fixtures YES=1   # remove exactly those three Catalogs
make unseed-dev-access YES=1            # delete the seed people, groups and Secret (keeps every Catalog)
```

Every mutating target needs `YES=1` and refuses when ConfigMap `stardelt-identity` says
`environment: production`: this is a development aid, not an install step. `make
seed-dev-access` does not roll Trino — only `SEED_CATALOGS=1`, the two fixture targets and
a deleted catalog change the catalog set, and those converge through `make catalogs`
(about a minute, and the coordinator restart drops running queries: pick a quiet moment).

`unseed-dev-access` deletes only what the seed created: the users and groups carrying
`stardelt-managed=seed` and Secret `dev-seed-users` (its passwords belong to users that no
longer exist). It never deletes a Catalog, a Lakekeeper warehouse, a schema or a table.
`analyst` stays a person; the baseline Catalogs and the fixtures stay until you run the
fixtures' own unseed.

---
