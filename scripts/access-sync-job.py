#!/usr/bin/env python3
"""Turn `Catalog` objects into Lakekeeper warehouses (authz 4/8, platform#305).

Runs inside the cluster as CronJob `access-sync` (every 2 minutes). The design
(`design/multitenant-catalogs.md` §4.2, §7.2 P2a) gives this loop to the operator; the
operator builds objects and Jobs only and has no HTTP client (no `CATALOG_*`
environment), so a CronJob does it until the operator absorbs it. Nothing here belongs
in the operator's Catalog controller, which stays a dry-run planner.

For every `Catalog` in the namespace, one line on stdout:

* `created` / `exists` — a Lakekeeper warehouse of that name exists afterwards. An
  existing warehouse is adopted untouched (no storage change, status only), which is
  how the pre-existing `warehouse` joins the model without a migration.
* `invalid <reason>` — the object breaks a rule, so no warehouse is created and the
  status says why. This is a verdict, not a job failure: the Catalog carries the error.
* `failed <detail>` — Lakekeeper refused the create; the tick exits non-zero so the
  CronJob's backoff and the failed Job are visible.

Status is written through the `status` subresource as a merge-patch, and only when it
differs from the live status — a converged tick must not bump `resourceVersion`
(`make access-sync-now` twice leaves it alone).

Tonight only prefix mode is built: every catalog shares the platform bucket (Secret
`stardelt-s3-creds`) and `storage.keyPrefix` (default: the catalog name) separates the
data. A `storage.bucket` that is not the platform bucket is
`Invalid/BucketsNotBuilt` — storage isolation cannot be enforced anyway until
per-catalog buckets exist (`design/multitenant-catalogs.md` §2.4; spike platform#272
showed CopyObject bypasses bucket scoping), and users never hold storage credentials.

Deleting a Catalog never deletes its warehouse or its data (design §2.5): a warehouse
without a Catalog is only reported, as one `orphan warehouse <name>` line per tick.

Standard library only (the image is plain `python:slim-bookworm`). The S3 secret
travels only in the create body; logs carry catalog names, counts and HTTP status
codes, never principals, tokens, keys or response bodies (a create body is the one
place the storage key appears, and a response body can echo it).
"""
import base64
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

NAMESPACE = os.environ.get("NAMESPACE", "stardelt")
LAKEKEEPER_URL = os.environ.get("LAKEKEEPER_URL", "http://lakekeeper:8181").rstrip("/")
CLIENT_SECRET_NAME = os.environ.get("CLIENT_SECRET_NAME", "svc-catalog-operator")
S3_SECRET_NAME = os.environ.get("S3_SECRET_NAME", "stardelt-s3-creds")

# The one project the catalog bootstraps (manifests/lakekeeper-bootstrap.yaml).
PROJECT_ID = "00000000-0000-0000-0000-000000000000"
CATALOG_PATH = "/apis/stardelt.io/v1alpha1/namespaces/%s/catalogs" % NAMESPACE

# Trino catalog names taken by the engine or by the platform: the operator's
# `RESERVED_CATALOG_NAMES` (stardelt-operator crates/stardelt-operator/src/crd.rs).
RESERVED_NAMES = ("system", "information_schema", "memory", "tpch", "tpcds", "jmx")
# `metadata.name` becomes an unquoted SQL identifier: lower-case letters and digits,
# starting with a letter, 1 to 40 characters (CatalogDomainSpec::validate).
NAME_RE = re.compile(r"^[a-z][a-z0-9]{0,39}$")

TIMEOUT = 30
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_API = "https://kubernetes.default.svc"

_TOKEN = None  # client-credentials token, cached for one run, never logged
# Filled by main() from Secret stardelt-s3-creds: the one bucket every catalog shares
# until per-catalog buckets exist.
PLATFORM_BUCKET = ""


def fail(message):
    print("access-sync: %s" % message, file=sys.stderr)
    sys.exit(1)


def k8s_request(method, path, body=None):
    """One call against the Kubernetes API over the Pod's ServiceAccount.

    A body is sent as a merge-patch (the only body this job sends is the status
    patch). Returns `(status_code, json_body)`; `(code, None)` for an HTTP error and
    `fail()` when the API cannot be reached at all — that is an install problem, not
    one catalog's.
    """
    try:
        with open(os.path.join(SA_DIR, "token")) as handle:
            sa_token = handle.read().strip()
        context = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    except OSError as e:
        fail("cannot read the Pod ServiceAccount credentials: %s" % e)
    data = None
    headers = {"Authorization": "Bearer " + sa_token, "Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/merge-patch+json"
    req = urllib.request.Request(K8S_API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=context) as response:
            raw = response.read().decode("utf-8")
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        e.close()
        return e.code, None
    except (urllib.error.URLError, TimeoutError, OSError, ssl.SSLError) as e:
        fail("Kubernetes API %s %s unreachable: %s" % (method, path, e))


def secret_data(name):
    """The decoded `data` of one Secret, or `fail()` — never logged."""
    status, secret = k8s_request(
        "GET", "/api/v1/namespaces/%s/secrets/%s" % (NAMESPACE, name)
    )
    if status != 200 or not secret:
        fail("cannot read Secret %s (HTTP %s)" % (name, status))
    return secret.get("data") or {}


def s3_credentials():
    """The platform bucket and its key pair from Secret stardelt-s3-creds."""
    data = secret_data(S3_SECRET_NAME)
    s3 = {}
    for key in ("endpoint", "bucket", "region", "access-key", "secret-key"):
        try:
            s3[key] = base64.b64decode(data[key]).decode()
        except (KeyError, ValueError):
            fail("Secret %s has no usable %r key" % (S3_SECRET_NAME, key))
    return s3


def lakekeeper_token():
    """A client-credentials token for svc-catalog-operator, cached for the run.

    The realm has no `lakekeeper` client scope; `openid` is a default scope of every
    client and the aud-lakekeeper mapper still puts the audience on the token.
    """
    global _TOKEN
    if _TOKEN:
        return _TOKEN
    data = secret_data(CLIENT_SECRET_NAME)
    try:
        client_id = base64.b64decode(data["client-id"]).decode()
        client_secret = base64.b64decode(data["client-secret"]).decode()
        token_url = base64.b64decode(data["token-url"]).decode()
    except (KeyError, ValueError):
        fail(
            "Secret %s must carry client-id, client-secret and token-url"
            % CLIENT_SECRET_NAME
        )
    body = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": "openid",
        }
    ).encode()
    req = urllib.request.Request(token_url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            token = json.load(response).get("access_token") or ""
    except urllib.error.HTTPError as e:
        fail(
            "token endpoint refused the %s client credentials: HTTP %s"
            % (CLIENT_SECRET_NAME, e.code)
        )
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail("token endpoint unreachable: %s" % e)
    if not token:
        fail("token endpoint answered without an access token")
    _TOKEN = token
    del client_secret, body
    return _TOKEN


def lk(method, path, body=None):
    """One Lakekeeper management call. Bodies never reach an error message."""
    headers = {"Authorization": "Bearer " + lakekeeper_token(), "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(LAKEKEEPER_URL + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            raw = response.read().decode("utf-8")
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        e.close()
        return e.code, None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail("Lakekeeper %s %s unreachable: %s" % (method, path, e))


def list_catalogs():
    """Every `Catalog` in the namespace (the CRD is namespaced and installed)."""
    status, listing = k8s_request("GET", CATALOG_PATH)
    if status != 200 or listing is None:
        fail("cannot list catalogs (HTTP %s)" % status)
    return listing.get("items") or []


def warehouse_index():
    """Name -> id for every Lakekeeper warehouse.

    The live 0.12.2 answers `{"warehouses": [{"id", "warehouse-id", "name", ...}]}`
    (both id keys present and equal); `warehouse-id` is the one the bootstrap Job
    reads, `id` is the entry's own id. Either identifies the warehouse.
    """
    status, listing = lk("GET", "/management/v1/warehouse")
    if status != 200 or listing is None:
        fail("cannot list Lakekeeper warehouses (HTTP %s)" % status)
    index = {}
    for entry in listing.get("warehouses") or []:
        name = entry.get("name")
        warehouse_id = entry.get("warehouse-id") or entry.get("id")
        if name and warehouse_id:
            index[name] = warehouse_id
    return index


def catalog_problem(name, spec):
    """The first rule a Catalog breaks, as `(reason, message)`, or None.

    The name rules mirror the operator's `CatalogDomainSpec::validate` word for word:
    the name becomes a Trino catalog (an unquoted SQL identifier) and a Lakekeeper
    warehouse, so it must not collide with a name the engine or the platform owns.
    """
    if not NAME_RE.match(name or ""):
        return (
            "InvalidName",
            "catalog name `%s` must be 1 to 40 lower-case letters and digits, "
            "starting with a letter (it is a SQL identifier)" % name,
        )
    if name in RESERVED_NAMES:
        return ("ReservedName", "catalog name `%s` is reserved" % name)
    bucket = ((spec or {}).get("storage") or {}).get("bucket")
    if bucket and bucket != PLATFORM_BUCKET:
        # Only prefix mode is built: one bucket, one key prefix per catalog.
        return (
            "BucketsNotBuilt",
            "storage.bucket `%s` is not the platform bucket `%s`; per-catalog buckets "
            "are not built, so every catalog shares the platform bucket and is separated "
            "by storage.keyPrefix" % (bucket, PLATFORM_BUCKET),
        )
    return None


def warehouse_body(name, spec, s3):
    """The create body of manifests/lakekeeper-bootstrap.yaml for one catalog.

    The storage credential comes from the `s3` argument only — the platform Secret's
    key pair, read once per run; nothing here re-reads the environment or a Secret.
    """
    prefix = ((spec or {}).get("storage") or {}).get("keyPrefix") or name
    return {
        "warehouse-name": name,
        "project-id": PROJECT_ID,
        "storage-profile": {
            "type": "s3",
            "bucket": s3["bucket"],
            "key-prefix": prefix,
            "endpoint": s3["endpoint"],
            "region": s3["region"],
            "path-style-access": True,
            "flavor": "minio",
            "sts-enabled": False,
            "remote-signing-enabled": False,
        },
        "storage-credential": {
            "type": "s3",
            "credential-type": "access-key",
            "aws-access-key-id": s3["access-key"],
            "aws-secret-access-key": s3["secret-key"],
        },
    }


def ensure_warehouse(name, spec, s3):
    """`(warehouse_id, "created"|"exists"|"failed")` — create only when missing.

    An existing warehouse is adopted as it is: no storage change, no credential
    refresh (the bootstrap Job owns the platform warehouse's credential) and no
    project move. A 409 on create means somebody else created it first — the same
    name in this project, since that is the only way this call conflicts — and counts
    as `exists`.
    """
    index = warehouse_index()
    if name in index:
        return index[name], "exists"
    status, body = lk("POST", "/management/v1/warehouse", warehouse_body(name, spec, s3))
    if status == 409:
        warehouse_id = warehouse_index().get(name)
        if warehouse_id:
            return warehouse_id, "exists"
        print(
            "access-sync: Lakekeeper refused warehouse `%s` with 409 but lists no "
            "warehouse of that name" % name,
            file=sys.stderr,
        )
        return None, "failed"
    if status not in (200, 201):
        print(
            "access-sync: Lakekeeper refused warehouse `%s`: HTTP %s" % (name, status),
            file=sys.stderr,
        )
        return None, "failed"
    warehouse_id = (body or {}).get("warehouse-id") or (body or {}).get("id")
    if not warehouse_id:
        warehouse_id = warehouse_index().get(name)
    if not warehouse_id:
        print(
            "access-sync: Lakekeeper created `%s` but reports no id for it" % name,
            file=sys.stderr,
        )
        return None, "failed"
    return warehouse_id, "created"


def _condition(status_block, condition_type):
    for condition in (status_block or {}).get("conditions") or []:
        if condition.get("type") == condition_type:
            return condition
    return None


def patch_status(name, phase, warehouse_id, reason, message):
    """Write the Catalog status as a merge-patch, only when it differs from the live one.

    `lastTransitionTime` is set only on a write, so an unchanged tick leaves both the
    status and the object's `resourceVersion` alone (the ticket's idempotence check).
    `warehouseId: null` clears a stale id when a Catalog turns Invalid.
    """
    path = "%s/%s" % (CATALOG_PATH, name)
    status, live = k8s_request("GET", path)
    if status != 200 or not live:
        fail("cannot read Catalog %s (HTTP %s)" % (name, status))
    generation = (live.get("metadata") or {}).get("generation")
    current = live.get("status") or {}
    condition_status = "True" if phase == "Ready" else "False"
    live_condition = _condition(current, "CatalogReady") or {}

    unchanged = (
        current.get("phase") == phase
        and current.get("warehouseId") == warehouse_id
        and current.get("observedGeneration") == generation
        and live_condition.get("status") == condition_status
        and live_condition.get("reason") == reason
        and live_condition.get("message") == message
        and live_condition.get("observedGeneration") == generation
    )
    if unchanged:
        return False

    condition = {
        "type": "CatalogReady",
        "status": condition_status,
        "lastTransitionTime": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "observedGeneration": generation,
    }
    if reason:
        condition["reason"] = reason
    if message:
        condition["message"] = message
    desired = {
        "phase": phase,
        "warehouseId": warehouse_id,
        "observedGeneration": generation,
        "conditions": [condition],
    }
    status, _ = k8s_request("PATCH", path + "/status", {"status": desired})
    if status not in (200, 201):
        fail("cannot write Catalog %s status (HTTP %s)" % (name, status))
    return True


def main():
    """Converge every Catalog, then report warehouses no Catalog claims."""
    global PLATFORM_BUCKET
    s3 = s3_credentials()
    PLATFORM_BUCKET = s3["bucket"]
    catalogs = list_catalogs()
    failures = 0
    for item in catalogs:
        name = (item.get("metadata") or {}).get("name") or ""
        spec = item.get("spec") or {}
        problem = catalog_problem(name, spec)
        if problem:
            reason, message = problem
            patch_status(name, "Invalid", None, reason, message)
            print("catalog %s: invalid %s" % (name, reason))
            continue
        warehouse_id, action = ensure_warehouse(name, spec, s3)
        if action == "failed":
            failures += 1
            print("catalog %s: failed" % name)
            continue
        # A stable reason and message across ticks: `created` vs `exists` is a
        # property of this run, and putting it in the status would make the second
        # tick rewrite the first one's result (the ticket's idempotence check).
        patch_status(
            name, "Ready", warehouse_id, "Ready", "Lakekeeper warehouse %s" % warehouse_id
        )
        print("catalog %s: %s" % (name, action))

    # Deleted Catalogs leave their warehouses and data behind (design §2.5): report,
    # never delete.
    declared = {(item.get("metadata") or {}).get("name") for item in catalogs}
    for name in sorted(set(warehouse_index()) - declared):
        print("orphan warehouse %s" % name)

    if failures:
        print("access-sync: %d catalog(s) failed" % failures, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
