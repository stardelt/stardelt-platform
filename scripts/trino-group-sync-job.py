#!/usr/bin/env python3
"""Re-sync Trino's query-visibility group file from the live Keycloak realm.

Runs inside the cluster as CronJob `trino-group-sync` (every 5 minutes,
platform#167). It performs the same convergence as
scripts/sync-trino-groups.sh — read the members of group `stardelt-admins`,
write them as one `group:user,...` line into ConfigMap `trino-group-file` when
they changed — but with the in-cluster transports that script cannot use:

* Keycloak at http://keycloak:8080 directly (no port-forward), authenticated
  as the dedicated `trino-group-sync` service-account client
  (client-credentials grant), never the master credential;
* the Kubernetes API over the Pod's ServiceAccount (no kubectl in the image).

The Keycloak query contract is defined by scripts/sync-trino-groups.sh and
mirrored here on purpose: `group-by-path/{group}` to resolve the id, then
`groups/{id}/members?briefRepresentation=true`, usernames sorted into one
`group:user,...` line with a trailing newline, comparison ignoring that
newline. Change the query there and mirror it here.

Standard library only (urllib/json/ssl/base64): the image is plain
`python:slim-bookworm`, which has nothing else. Logging states counts, never
principals: usernames, tokens and secrets stay out of stdout/stderr, and error
messages carry HTTP status codes but never response bodies (a members payload
is a list of users).

Exit 0 when the ConfigMap already holds the membership or was converged onto
it (verified by read-back); non-zero otherwise, so a failed tick is visible as
a failed Job and retried by the CronJob's backoff.
"""
import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

NAMESPACE = os.environ.get("NAMESPACE", "stardelt")
KC_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak:8080").rstrip("/")
REALM = os.environ.get("REALM", "stardelt")
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "stardelt-admins")
GROUP_CONFIGMAP = os.environ.get("GROUP_CONFIGMAP", "trino-group-file")
SYNC_CLIENT = os.environ.get("SYNC_CLIENT", "trino-group-sync")
CLIENT_SECRET_NAME = os.environ.get("CLIENT_SECRET_NAME", "stardelt-oidc-clients")
CLIENT_SECRET_KEY = os.environ.get("CLIENT_SECRET_KEY", "trino-group-sync")

TIMEOUT = 30
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_API = "https://kubernetes.default.svc"


def fail(message):
    print("trino-group-sync: %s" % message, file=sys.stderr)
    sys.exit(1)


def keycloak_get(path, token):
    req = urllib.request.Request(
        KC_URL + path, headers={"Authorization": "Bearer " + token}, method="GET"
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        fail("Keycloak GET %s refused: HTTP %s" % (path.rsplit("?", 1)[0], e.code))
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail("Keycloak GET %s unreachable: %s" % (path.rsplit("?", 1)[0], e))


def k8s_request(method, path, body=None):
    try:
        with open(os.path.join(SA_DIR, "token")) as handle:
            sa_token = handle.read().strip()
        context = ssl.create_default_context(
            cafile=os.path.join(SA_DIR, "ca.crt")
        )
    except OSError as e:
        fail("cannot read the Pod ServiceAccount credentials: %s" % e)
    data = None
    headers = {
        "Authorization": "Bearer " + sa_token,
        "Accept": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/merge-patch+json"
    req = urllib.request.Request(
        K8S_API + path, data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=context) as response:
            raw = response.read().decode("utf-8")
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, TimeoutError, OSError, ssl.SSLError) as e:
        fail("Kubernetes API %s %s unreachable: %s" % (method, path, e))


# 1. The client's secret, from the Secret the install owns. base64-decoded in
#    memory only — never logged, never written to disk.
status, secret = k8s_request(
    "GET", "/api/v1/namespaces/%s/secrets/%s" % (NAMESPACE, CLIENT_SECRET_NAME)
)
if status != 200 or not secret:
    fail("cannot read Secret %s (HTTP %s)" % (CLIENT_SECRET_NAME, status))
try:
    client_secret = base64.b64decode(secret["data"][CLIENT_SECRET_KEY]).decode()
except (KeyError, ValueError) as e:
    fail("Secret %s has no usable %r key: %s" % (CLIENT_SECRET_NAME, CLIENT_SECRET_KEY, e))
if not client_secret:
    fail("Secret %s key %r is empty" % (CLIENT_SECRET_NAME, CLIENT_SECRET_KEY))

# 2. Client-credentials token for the sync client.
token_body = urllib.parse.urlencode(
    {
        "grant_type": "client_credentials",
        "client_id": SYNC_CLIENT,
        "client_secret": client_secret,
    }
).encode()
try:
    token_req = urllib.request.Request(
        "%s/realms/%s/protocol/openid-connect/token" % (KC_URL, REALM),
        data=token_body,
        method="POST",
    )
    with urllib.request.urlopen(token_req, timeout=TIMEOUT) as token_response:
        access_token = json.load(token_response).get("access_token") or ""
except urllib.error.HTTPError as e:
    fail("token endpoint refused the %s client credentials: HTTP %s" % (SYNC_CLIENT, e.code))
except (urllib.error.URLError, TimeoutError, OSError) as e:
    fail("token endpoint unreachable: %s" % e)
if not access_token:
    fail("token endpoint answered without an access token")
# The secret has served its purpose; drop the reference before any logging.
del client_secret, token_body

# 3. Resolve the group, then list its members — the same two reads
#    scripts/sync-trino-groups.sh performs.
api = "/admin/realms/%s" % REALM
group = keycloak_get("%s/group-by-path/%s" % (api, ADMIN_GROUP), access_token)
try:
    group_id = group["id"]
except (TypeError, KeyError):
    fail("group-by-path answered without a group id")
members = keycloak_get(
    "%s/groups/%s/members?briefRepresentation=true" % (api, group_id),
    access_token,
)
try:
    names = sorted({user["username"] for user in members if user.get("username")})
except (TypeError, AttributeError):
    fail("members endpoint answered without a user list")
desired = "%s:%s\n" % (ADMIN_GROUP, ",".join(names))
count = len(names)
del access_token

# 4. Converge the ConfigMap. Byte-identical content means no write — the data
#    fans out through a mounted volume, so a no-op write would still bounce the
#    kubelet's file timestamp for nothing.
cm_path = "/api/v1/namespaces/%s/configmaps/%s" % (NAMESPACE, GROUP_CONFIGMAP)
status, live_cm = k8s_request("GET", cm_path)
if status == 404:
    # The Role deliberately grants no `create`: a resourceNames-scoped create
    # rule never authorizes (verified), and the ConfigMap is owned by
    # `make trino`, which writes it before the CronJob exists. A missing
    # ConfigMap here is a broken install, not something to self-heal.
    fail(
        "ConfigMap %s does not exist — run 'make trino' to create it"
        % GROUP_CONFIGMAP
    )
if status != 200 or not live_cm:
    fail("cannot read ConfigMap %s (HTTP %s)" % (GROUP_CONFIGMAP, status))
live = (live_cm.get("data") or {}).get("groups.txt", "")
if live.rstrip("\n") == desired.rstrip("\n"):
    print(
        "trino-group-sync: OK — %s (%d member(s)) in ConfigMap %s, unchanged"
        % (ADMIN_GROUP, count, GROUP_CONFIGMAP)
    )
    sys.exit(0)

status, _ = k8s_request("PATCH", cm_path, {"data": {"groups.txt": desired}})
if status != 200:
    fail("cannot update ConfigMap %s (HTTP %s)" % (GROUP_CONFIGMAP, status))
action = "updated"

# 5. Prove it: read back and compare bytes, not intentions.
status, read_back = k8s_request("GET", cm_path)
if status != 200 or not read_back:
    fail("cannot read ConfigMap %s back after the write (HTTP %s)" % (GROUP_CONFIGMAP, status))
if (read_back.get("data") or {}).get("groups.txt", "").rstrip("\n") != desired.rstrip("\n"):
    fail("ConfigMap %s reads back different content than written" % GROUP_CONFIGMAP)
print(
    "trino-group-sync: OK — %s (%d member(s)) in ConfigMap %s, %s"
    % (ADMIN_GROUP, count, GROUP_CONFIGMAP, action)
)
