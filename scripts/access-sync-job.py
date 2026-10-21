#!/usr/bin/env python3
"""Turn `Catalog` objects into Lakekeeper warehouses with grants (authz 4/8, 5/8).

Runs inside the cluster as CronJob `access-sync` (every 2 minutes). The design
(`design/multitenant-catalogs.md` §4.2, §5.2–§5.7, §7.2 P2a) gives this loop to the
operator; the operator builds objects and Jobs only and has no HTTP client (no
`CATALOG_*` environment), so a CronJob does it until the operator absorbs it.
Nothing here belongs in the operator's Catalog controller, which stays a dry-run
planner.

For every `Catalog` in the namespace, one line on stdout:

* `created` / `exists` — a Lakekeeper warehouse of that name exists afterwards. An
  existing warehouse is adopted untouched (no storage change, status only), which is
  how the pre-existing `warehouse` joins the model without a migration.
* `invalid <reason>` — the object breaks a rule, so no warehouse is created and the
  status says why. This is a verdict, not a job failure: the Catalog carries the error.
* `failed <detail>` — Lakekeeper refused the create; the tick exits non-zero so the
  CronJob's backoff and the failed Job are visible.

Then the grants (platform#306): a Keycloak group becomes a Lakekeeper role of the
same name, its members are that role's `assignee`s by OIDC `sub` (`oidc~<sub>`, valid
before a person has ever signed in), and the Catalog's `grants` become grants on the
warehouse — which Lakekeeper inherits downward to every namespace, table and view,
existing and future. The verb map (architect decision 2026-10-20 included):

    browse -> describe        select -> select            write -> modify
    create -> create          manage -> manage_grants     (never `ownership`)

`manage` is `manage_grants` because Lakekeeper's `ownership` includes every data
right, and managing a catalog must not imply reading it; dropping or renaming needs
`write`. The owner group gets `manage_grants` and nothing else (§5.3: ownership does
not imply select).

The sync owns only what it created: roles whose description starts with
`stardelt group `, nothing else — a role with a foreign description is reported as a
conflict and never edited. Grants on a managed warehouse held by a role this job
manages that the spec does not declare are removed; grants held by anything else
(the project-level `data_admin` of the platform's service accounts, a person's
ownership, a person) are left alone and only *counted* in the Catalog's `Drift`
condition (reason plus count, no names). The sync's own `ownership` on a warehouse it
created (`own_user_id()`, the creator tuple Lakekeeper writes) is its own record and
is not drift.

The admin group (`ADMIN_GROUP`, default `stardelt-admins`) is always managed: its
role exists, holds its members, and is a `project_admin` of the project, so every
platform administrator has that through the group instead of one grant per person.
`STATIC_ASSIGNEES` (`{"<group>": ["<principal>"]}`, default `{}`) adds assignees that
have no Keycloak user — tonight the PASSWORD account `superset` — as
`oidc~<principal>`; entries for groups no Catalog declares are ignored.

Status is written through the `status` subresource as a merge-patch, and only when it
differs from the live status — a converged tick must not bump `resourceVersion`
(`make access-sync-now` twice leaves it alone). The job owns the `CatalogReady`,
`GrantsReady` and `Drift` conditions and leaves any other condition untouched.

The Keycloak side is read-only and always happens before the first write, so a realm
that refuses this client (401/403) fails the tick with nothing written. A declared
group that does not exist in the realm is a verdict (`GrantsReady=False`,
`reason=UnknownGroup`), not a failed tick — the same rule as `Invalid`.

Tonight only prefix mode is built: every catalog shares the platform bucket (Secret
`stardelt-s3-creds`) and `storage.keyPrefix` (default: the catalog name) separates the
data. A `storage.bucket` that is not the platform bucket is
`Invalid/BucketsNotBuilt` — storage isolation cannot be enforced anyway until
per-catalog buckets exist (`design/multitenant-catalogs.md` §2.4; spike platform#272
showed CopyObject bypasses bucket scoping), and users never hold storage credentials.

Deleting a Catalog never deletes its warehouse or its data (design §2.5): a warehouse
without a Catalog is only reported, as one `orphan warehouse <name>` line per tick.

Standard library only (the image is plain `python:slim-bookworm`). The S3 secret
travels only in the create body; logs carry catalog names, group names, counts and
HTTP status codes, never principals, subjects, usernames, tokens, keys or response
bodies (a create body is the one place the storage key appears, and a response body
can echo it).
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
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak:8080").rstrip("/")
REALM = os.environ.get("REALM", "stardelt")
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "stardelt-admins")
# JSON `{"<group>": ["<principal>"]}`: assignees that have no Keycloak user.
STATIC_ASSIGNEES = os.environ.get("STATIC_ASSIGNEES", "{}")
CLIENT_SECRET_NAME = os.environ.get("CLIENT_SECRET_NAME", "svc-catalog-operator")
# The read-only Keycloak client (view-users on realm-management), the same one
# CronJob `trino-group-sync` uses.
SYNC_SECRET_NAME = os.environ.get("SYNC_SECRET_NAME", "stardelt-oidc-clients")
SYNC_SECRET_KEY = os.environ.get("SYNC_SECRET_KEY", "trino-group-sync")
SYNC_CLIENT = os.environ.get("SYNC_CLIENT", "trino-group-sync")
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

# Our verbs (design §5.2) as Lakekeeper relations on the warehouse object. `manage`
# is `manage_grants`, never `ownership`: ownership includes all data rights, and
# managing a catalog must not imply reading it (architect decision 2026-10-20).
VERB_RELATIONS = {
    "browse": "describe",
    "select": "select",
    "write": "modify",
    "create": "create",
    "manage": "manage_grants",
}
# The description marks a role as ours; any other role is never edited.
ROLE_PREFIX = "stardelt group "
# Keycloak lists members and Lakekeeper lists roles 100 at a time; both page.
MEMBER_PAGE = 100
ROLE_PAGE = 100
# The conditions this job writes; anything else in the status is preserved.
OWNED_CONDITIONS = ("CatalogReady", "GrantsReady", "Drift")

TIMEOUT = 30
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_API = "https://kubernetes.default.svc"

_TOKEN = None  # Lakekeeper client-credentials token, cached for one run, never logged
_KC_TOKEN = None  # Keycloak client-credentials token, cached for one run, never logged
_OWN_USER = None  # `oidc~<sub>` of this job's Lakekeeper client (own_user_id), never logged
_OWN_USER_TOKEN = None  # the token _OWN_USER was decoded from; recompute when it changes
# Filled by main() from Secret stardelt-s3-creds: the one bucket every catalog shares
# until per-catalog buckets exist.
PLATFORM_BUCKET = ""


class SyncProblem(Exception):
    """A problem with one group's sync, reported on the Catalogs that declare it.

    `verdict` is True when the spec asks for something the sync cannot do (a group
    that is not in the realm, a role somebody else owns): the Catalog carries the
    reason in `GrantsReady` and the tick stays successful, like `Invalid` for a
    broken name. `verdict` False means a write was refused — the tick exits non-zero.
    """

    reason = "SyncProblem"
    verdict = False

    def __init__(self, message):
        super().__init__(message)
        self.message = message


class GroupUnknown(SyncProblem):
    reason = "UnknownGroup"
    verdict = True


class RoleConflict(SyncProblem):
    reason = "RoleConflict"
    verdict = True


class RoleCreateFailed(SyncProblem):
    reason = "RoleCreateFailed"


class AssigneesFailed(SyncProblem):
    reason = "AssigneesFailed"


class GrantsFailed(SyncProblem):
    reason = "GrantsFailed"


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


def own_user_id():
    """`oidc~<sub>` of the Lakekeeper client this run authenticates as, or None.

    Lakekeeper writes an `ownership` assignment for the principal that creates a
    warehouse; for a Catalog this job creates, that principal is this client. The
    `sub` is read from the payload of the token `lakekeeper_token()` already holds —
    base64url, signature *not* verified, because this is the token this process just
    received over TLS, not a credential somebody else handed in. Computed once per
    token (one decode per run) and never printed or logged: the `sub` is a principal,
    like every other subject this job refuses to name.

    Returns None when the token carries no readable `sub`; the caller then counts
    every assignment it does not manage, exactly as before this helper existed.
    """
    global _OWN_USER, _OWN_USER_TOKEN
    token = lakekeeper_token()
    if token == _OWN_USER_TOKEN:
        return _OWN_USER
    _OWN_USER_TOKEN, _OWN_USER = token, None
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, TypeError, ValueError):
        return None
    sub = claims.get("sub") if isinstance(claims, dict) else None
    if not isinstance(sub, str) or not sub:
        return None
    _OWN_USER = "oidc~" + sub
    return _OWN_USER


def keycloak_token():
    """A client-credentials token for the read-only sync client, cached for the run.

    The client (`trino-group-sync` by default) holds `view-users` on the realm's
    `realm-management`, which is all the group reads below need — never the master
    credential. The secret comes from Secret `stardelt-oidc-clients`, decoded in
    memory only.
    """
    global _KC_TOKEN
    if _KC_TOKEN:
        return _KC_TOKEN
    data = secret_data(SYNC_SECRET_NAME)
    try:
        client_secret = base64.b64decode(data[SYNC_SECRET_KEY]).decode()
    except (KeyError, ValueError):
        fail(
            "Secret %s has no usable %r key" % (SYNC_SECRET_NAME, SYNC_SECRET_KEY)
        )
    if not client_secret:
        fail("Secret %s key %r is empty" % (SYNC_SECRET_NAME, SYNC_SECRET_KEY))
    body = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": SYNC_CLIENT,
            "client_secret": client_secret,
        }
    ).encode()
    req = urllib.request.Request(
        "%s/realms/%s/protocol/openid-connect/token" % (KEYCLOAK_URL, REALM),
        data=body,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            token = json.load(response).get("access_token") or ""
    except urllib.error.HTTPError as e:
        fail("token endpoint refused the %s client credentials: HTTP %s" % (SYNC_CLIENT, e.code))
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail("token endpoint unreachable: %s" % e)
    if not token:
        fail("token endpoint answered without an access token")
    _KC_TOKEN = token
    del client_secret, body
    return _KC_TOKEN


def kc(path):
    """One Keycloak admin read: `(status_code, json_body)`.

    401/403 fail the run immediately. Every read of this module happens before the
    first write, so such a failure never leaves a partial sync behind.
    """
    req = urllib.request.Request(
        KEYCLOAK_URL + path,
        headers={"Authorization": "Bearer " + keycloak_token(), "Accept": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            raw = response.read().decode("utf-8")
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        e.close()
        if e.code in (401, 403):
            fail(
                "Keycloak refused the %s client on a group read: HTTP %s"
                % (SYNC_CLIENT, e.code)
            )
        return e.code, None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail("Keycloak unreachable: %s" % e)


def group_members(group):
    """The OIDC `sub`s of every member of a Keycloak group (`set[str]`).

    `group-by-path` resolves the group, then `groups/{id}/members` is paged until a
    short page. A member's `id` is the token's `sub`, so these are exactly the
    principals Lakekeeper knows as `oidc~<sub>`. 404 means the group does not exist —
    a typo in a Catalog, reported per Catalog; any other status fails the run.
    """
    api = "/admin/realms/%s" % REALM
    status, body = kc("%s/group-by-path/%s" % (api, urllib.parse.quote(group, safe="")))
    if status == 404:
        raise GroupUnknown("the realm has no group `%s`" % group)
    if status != 200 or not body:
        fail("cannot read group `%s` from the realm (HTTP %s)" % (group, status))
    group_id = body.get("id")
    if not group_id:
        fail("group-by-path for `%s` answered without a group id" % group)
    subs = set()
    first = 0
    while True:
        status, page = kc(
            "%s/groups/%s/members?briefRepresentation=true&first=%d&max=%d"
            % (api, group_id, first, MEMBER_PAGE)
        )
        if status != 200 or page is None:
            fail("cannot list the members of group `%s` (HTTP %s)" % (group, status))
        subs.update(user["id"] for user in page if user.get("id"))
        if len(page) < MEMBER_PAGE:
            return subs
        first += len(page)


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


def static_assignees():
    """`{"<group>": set(<principal>)}` from the `STATIC_ASSIGNEES` environment."""
    raw = (STATIC_ASSIGNEES or "{}").strip() or "{}"
    try:
        parsed = json.loads(raw)
    except ValueError:
        fail("STATIC_ASSIGNEES is not valid JSON")
    if not isinstance(parsed, dict) or not all(
        isinstance(principals, list)
        and all(isinstance(principal, str) and principal for principal in principals)
        for principals in parsed.values()
    ):
        fail('STATIC_ASSIGNEES must be {"<group>": ["<principal>"]}')
    return {group: set(principals) for group, principals in parsed.items()}


def declared_groups(spec):
    """The groups a Catalog's spec names: its owner and every grant group."""
    groups = set()
    spec = spec or {}
    if spec.get("owner"):
        groups.add(spec["owner"])
    for grant in spec.get("grants") or []:
        if grant.get("group"):
            groups.add(grant["group"])
    return groups


def managed_groups(catalogs):
    """Every group the sync owns a role for: owners, grant groups, the admin group."""
    groups = {ADMIN_GROUP}
    for item in catalogs:
        groups |= declared_groups(item.get("spec") or {})
    return groups


def desired_relations(spec):
    """The `(Lakekeeper relation, group)` pairs a Catalog's spec asks for.

    `manage` is `manage_grants`, never `ownership`; the owner group holds that and
    nothing else (ownership does not imply select, design §5.3).
    """
    desired = set()
    spec = spec or {}
    if spec.get("owner"):
        desired.add(("manage_grants", spec["owner"]))
    for grant in spec.get("grants") or []:
        relation = VERB_RELATIONS.get(grant.get("verb"))
        group = grant.get("group")
        if relation and group:
            desired.add((relation, group))
    return desired


def list_roles():
    """Every Lakekeeper role, following `next-page-token` until it is absent.

    0.12.2 pages with `pageSize`/`pageToken` (camelCase; the snake_case spellings are
    ignored, which silently repeats the first page).
    """
    roles = []
    token = None
    for _ in range(1000):
        query = "?pageSize=%d" % ROLE_PAGE
        if token:
            query += "&pageToken=" + urllib.parse.quote(token, safe="")
        status, body = lk("GET", "/management/v1/role" + query)
        if status != 200 or body is None:
            fail("cannot list Lakekeeper roles (HTTP %s)" % status)
        roles.extend(body.get("roles") or [])
        token = body.get("next-page-token")
        if not token:
            return roles
    fail("Lakekeeper role listing does not terminate after 1000 pages")


def is_managed_role(role):
    """True for roles this job created: their description starts with the prefix."""
    return (role.get("description") or "").startswith(ROLE_PREFIX)


def ensure_role(group, roles=None):
    """The id of the role named `group`, created when missing.

    Only roles whose description starts with `stardelt group ` are ours. A same-named
    role somebody else owns is left untouched and raised as `RoleConflict`: the sync
    never edits a role it did not create, and assigning members to a foreign role
    would change its grants.
    """
    for role in list_roles() if roles is None else roles:
        if role.get("name") != group:
            continue
        if is_managed_role(role):
            return role["id"]
        raise RoleConflict(
            "Lakekeeper role `%s` exists but is not managed by the sync "
            "(its description does not start with `%s`); it was not edited" % (group, ROLE_PREFIX)
        )
    status, body = lk(
        "POST", "/management/v1/role", {"name": group, "description": ROLE_PREFIX + group}
    )
    if status == 409:
        # Somebody created it between our list and our create: adopt it if it is ours.
        for role in list_roles():
            if role.get("name") == group and is_managed_role(role):
                return role["id"]
        raise RoleConflict("Lakekeeper role `%s` appeared concurrently and is not managed" % group)
    role_id = (body or {}).get("id")
    if status not in (200, 201) or not role_id:
        raise RoleCreateFailed("Lakekeeper refused the role for `%s`: HTTP %s" % (group, status))
    return role_id


def sync_assignees(role_id, subs):
    """Make the role's assignees exactly `subs`; returns `(written, removed)`.

    Only `assignee` entries are touched — the role's `ownership` (its creator) and any
    other relation stay as they are. Nothing is written when the sets already match,
    which is what makes a converged tick a no-op.
    """
    status, body = lk("GET", "/management/v1/permissions/role/%s/assignments" % role_id)
    if status != 200 or body is None:
        raise AssigneesFailed("cannot read the assignees of a role (HTTP %s)" % status)
    current = {
        entry["user"]
        for entry in body.get("assignments") or []
        if entry.get("type") == "assignee" and entry.get("user")
    }
    desired = {"oidc~" + sub for sub in subs}
    writes = sorted(desired - current)
    deletes = sorted(current - desired)
    if not writes and not deletes:
        return 0, 0
    status, _ = lk(
        "POST",
        "/management/v1/permissions/role/%s/assignments" % role_id,
        {
            "writes": [{"type": "assignee", "user": subject} for subject in writes],
            "deletes": [{"type": "assignee", "user": subject} for subject in deletes],
        },
    )
    if status not in (200, 204):
        raise AssigneesFailed("Lakekeeper refused the assignees of a role: HTTP %s" % status)
    return len(writes), len(deletes)


def sync_warehouse_grants(warehouse_id, desired, role_ids, managed_role_ids=None, apply=True):
    """Converge one warehouse's grants; returns `(written, removed, foreign)`.

    `desired` comes from `desired_relations(spec)`, `role_ids` maps group -> role id,
    `managed_role_ids` is every role this job created (default: the ones in
    `role_ids`) — a grant held by one of those that the spec does not declare is
    removed. Everything else (another role, a person, the platform's service accounts
    at project level) is left alone and only counted as `foreign`, because the sync
    never edits a subject it does not own. One exception: the `ownership` assignment
    Lakekeeper wrote for the sync's *own* client when it created the warehouse
    (`own_user_id()`) is the sync's own record, not drift, so it is neither counted
    nor deleted. `apply=False` reads and counts without writing — used when one of the
    Catalog's groups cannot be resolved, so a broken spec removes nothing.
    """
    managed = set(role_ids.values()) if managed_role_ids is None else set(managed_role_ids)
    own = own_user_id()
    status, body = lk("GET", "/management/v1/permissions/warehouse/%s/assignments" % warehouse_id)
    if status != 200 or body is None:
        raise GrantsFailed("cannot read the grants of a warehouse (HTTP %s)" % status)
    assignments = body.get("assignments") or []
    current = {
        (entry.get("type"), entry.get("role"))
        for entry in assignments
        if entry.get("type") and entry.get("role")
    }
    declared = {
        (relation, role_ids[group])
        for relation, group in desired
        if group in role_ids
    }
    writes = sorted(declared - current)
    deletes = sorted({entry for entry in current if entry[1] in managed} - declared)
    # Every assignment whose subject is not a role of ours: another role, a person,
    # the platform's service accounts. Counted, never edited, never named — except
    # this job's own `ownership` tuple, which is the sync's own record, not drift.
    def is_own_ownership(entry):
        return (
            own is not None
            and entry.get("type") == "ownership"
            and entry.get("user") == own
        )

    foreign = len(
        [
            entry
            for entry in assignments
            if entry.get("role") not in managed and not is_own_ownership(entry)
        ]
    )
    if not apply or (not writes and not deletes):
        return 0, 0, foreign
    status, _ = lk(
        "POST",
        "/management/v1/permissions/warehouse/%s/assignments" % warehouse_id,
        {
            "writes": [{"type": relation, "role": role} for relation, role in writes],
            "deletes": [{"type": relation, "role": role} for relation, role in deletes],
        },
    )
    if status not in (200, 204):
        raise GrantsFailed("Lakekeeper refused the grants of a warehouse: HTTP %s" % status)
    return len(writes), len(deletes), foreign


def ensure_admin_grant(role_id):
    """`project_admin` on the project for `role_id`; True when it was written.

    With this in place every member of the admin group is a project administrator
    through the group, and a person joining or leaving needs no grant of their own.
    """
    status, body = lk("GET", "/management/v1/permissions/project/assignments")
    if status != 200 or body is None:
        fail("cannot read the project assignments (HTTP %s)" % status)
    for entry in body.get("assignments") or []:
        if entry.get("type") == "project_admin" and entry.get("role") == role_id:
            return False
    status, _ = lk(
        "POST",
        "/management/v1/permissions/project/assignments",
        {"writes": [{"type": "project_admin", "role": role_id}], "deletes": []},
    )
    if status not in (200, 204):
        fail("Lakekeeper refused project_admin for the admin role (HTTP %s)" % status)
    return True


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


def _condition(condition_type, status, reason, message, generation):
    condition = {"type": condition_type, "status": status, "observedGeneration": generation}
    if reason:
        condition["reason"] = reason
    if message:
        condition["message"] = message
    return condition


def _signature(condition):
    """What has to match for a status not to be rewritten (`lastTransitionTime` is not)."""
    return (
        condition.get("type"),
        condition.get("status"),
        condition.get("reason"),
        condition.get("message"),
        condition.get("observedGeneration"),
    )


def patch_status(name, phase, warehouse_id, reason, message, grants=None):
    """Write the Catalog status as a merge-patch, only when it differs from the live one.

    `grants` is `(ready, reason, message, drift)` and adds the `GrantsReady` and
    `Drift` conditions; `None` writes only `CatalogReady` (the Invalid verdict).
    `lastTransitionTime` is set only on a write, so an unchanged tick leaves both the
    status and the object's `resourceVersion` alone (the ticket's idempotence check).
    `warehouseId: null` clears a stale id when a Catalog turns Invalid. Conditions
    this job does not own are preserved as they are.
    """
    path = "%s/%s" % (CATALOG_PATH, name)
    status, live = k8s_request("GET", path)
    if status != 200 or not live:
        fail("cannot read Catalog %s (HTTP %s)" % (name, status))
    generation = (live.get("metadata") or {}).get("generation")
    current = live.get("status") or {}
    condition_status = "True" if phase == "Ready" else "False"

    desired = [
        _condition("CatalogReady", condition_status, reason, message, generation)
    ]
    if grants is not None:
        ready, grants_reason, grants_message, drift = grants
        desired.append(
            _condition(
                "GrantsReady",
                "True" if ready else "False",
                grants_reason,
                grants_message,
                generation,
            )
        )
        if drift:
            desired.append(
                _condition(
                    "Drift",
                    "True",
                    "ForeignGrants",
                    "%d grant(s) on this warehouse belong to subjects the sync does "
                    "not manage" % drift,
                    generation,
                )
            )
        else:
            desired.append(
                _condition(
                    "Drift",
                    "False",
                    "Clean",
                    "no grant on this warehouse belongs to another subject",
                    generation,
                )
            )

    live_owned = [
        condition
        for condition in current.get("conditions") or []
        if condition.get("type") in OWNED_CONDITIONS
    ]
    foreign = [
        condition
        for condition in current.get("conditions") or []
        if condition.get("type") not in OWNED_CONDITIONS
    ]
    unchanged = (
        current.get("phase") == phase
        and current.get("warehouseId") == warehouse_id
        and current.get("observedGeneration") == generation
        and [_signature(condition) for condition in live_owned]
        == [_signature(condition) for condition in desired]
    )
    if unchanged:
        return False

    written = []
    for condition in desired:
        condition = dict(condition)
        condition["lastTransitionTime"] = datetime.now(timezone.utc).isoformat(
            timespec="seconds"
        )
        written.append(condition)
    status, _ = k8s_request(
        "PATCH",
        path + "/status",
        {
            "status": {
                "phase": phase,
                "warehouseId": warehouse_id,
                "observedGeneration": generation,
                "conditions": written + foreign,
            }
        },
    )
    if status not in (200, 201):
        fail("cannot write Catalog %s status (HTTP %s)" % (name, status))
    return True


def main():
    """Converge every Catalog, then report warehouses no Catalog claims."""
    global PLATFORM_BUCKET
    s3 = s3_credentials()
    PLATFORM_BUCKET = s3["bucket"]
    catalogs = list_catalogs()
    static = static_assignees()
    groups = managed_groups(catalogs)

    # 1. Keycloak, read-only, before any write: a realm that refuses this client
    #    fails the tick with nothing written. A group that is not there at all is a
    #    verdict for the Catalogs that name it (a typo), not a failed tick.
    members, unknown = {}, set()
    for group in sorted(groups):
        try:
            members[group] = group_members(group)
        except GroupUnknown:
            unknown.add(group)
            print("group %s: not in the realm" % group)
    print(
        "access-sync: %d group(s) declared, %d member(s) in Keycloak"
        % (len(groups), sum(len(subs) for subs in members.values()))
    )

    # 2. One role per group, its assignees converged, once — membership does not
    #    depend on a Catalog.
    roles = list_roles()
    role_ids, problems, failures = {}, {}, 0
    for group in sorted(groups):
        if group in unknown:
            continue
        try:
            role_id = ensure_role(group, roles)
        except SyncProblem as problem:
            problems[group] = problem
            failures += 0 if problem.verdict else 1
            continue
        role_ids[group] = role_id
        assignees = members[group] | static.get(group, set())
        try:
            written, removed = sync_assignees(role_id, assignees)
        except SyncProblem as problem:
            problems[group] = problem
            failures += 1
            continue
        print(
            "role %s: %d assignee(s) (%d member(s), %d static), %d written, %d removed"
            % (
                group,
                len(assignees),
                len(members[group]),
                len(static.get(group, set())),
                written,
                removed,
            )
        )

    # 3. The admin group holds project_admin through its role, so every platform
    #    administrator has it by group (and no member needs a grant of their own).
    if ADMIN_GROUP not in role_ids:
        problem = problems.get(ADMIN_GROUP) or GroupUnknown(
            "the realm has no group `%s`" % ADMIN_GROUP
        )
        fail("cannot manage %s: %s" % (ADMIN_GROUP, problem.message))
    if ensure_admin_grant(role_ids[ADMIN_GROUP]):
        print("role %s: project_admin written" % ADMIN_GROUP)

    # Every role this job created, including one whose group a spec no longer names:
    # an undeclared grant of such a role is still ours to remove.
    managed_role_ids = {role["id"] for role in list_roles() if is_managed_role(role)}

    # 4. Catalogs: warehouse first, then its grants.
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

        declared = declared_groups(spec)
        unresolved = sorted(declared & unknown)
        blockers = [problems[group] for group in sorted(declared) if group in problems]
        desired = desired_relations(spec)
        grants_ready = True
        reason, message = "Ready", "%d declared grant(s) on the warehouse" % len(desired)
        if unresolved:
            grants_ready = False
            reason = "UnknownGroup"
            message = "the realm has no group `%s`" % unresolved[0]
        elif blockers:
            grants_ready = False
            reason, message = blockers[0].reason, blockers[0].message
        try:
            written, removed, drift = sync_warehouse_grants(
                warehouse_id,
                desired,
                role_ids,
                managed_role_ids,
                apply=grants_ready,
            )
        except SyncProblem as problem:
            failures += 1
            grants_ready = False
            reason, message = problem.reason, problem.message
            written, removed, drift = 0, 0, 0
        # A stable reason and message across ticks: `created` vs `exists` is a
        # property of this run, and putting it in the status would make the second
        # tick rewrite the first one's result (the ticket's idempotence check).
        patch_status(
            name,
            "Ready",
            warehouse_id,
            "Ready",
            "Lakekeeper warehouse %s" % warehouse_id,
            grants=(grants_ready, reason, message, drift),
        )
        print(
            "catalog %s: %s grants %d declared, %d written, %d removed, %d foreign"
            % (name, action, len(desired), written, removed, drift)
        )

    # Deleted Catalogs leave their warehouses and data behind (design §2.5): report,
    # never delete.
    declared = {(item.get("metadata") or {}).get("name") for item in catalogs}
    for name in sorted(set(warehouse_index()) - declared):
        print("orphan warehouse %s" % name)

    if failures:
        print("access-sync: %d failure(s) in this tick" % failures, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
