#!/usr/bin/env python3
"""Empty the public demo's playground every night at 03:00 UTC.

Runs inside the cluster as CronJob `demo-reset` (`manifests/demo-reset.yaml`, epic
platform#895 decision 4). The playground Catalog is written to by anyone on the
internet, so every night it is emptied and gets its one schema `scratch` back.

The job signs in as the existing principal `pipeline-demo` (realm group `demo`, which
owns `playground`) with `grant_type=client_credentials`, and talks to the query engine
about the catalog: no IdP administrator and no new credential is needed. Its Secret
`sp-pipeline-demo` is the one `make demo-access YES=1` writes.

The visitors' Pipelines go first, and they go through the Kubernetes API, not the query
engine (epic platform#895 decision 11): ServiceAccount `demo-reset` may `list` and
`delete` `pipelines`, nothing else. A visitor may schedule a pipeline and Nova's floor
is five minutes, so a pipeline that outlived the drop would re-create the table the
reset just removed — deleting the pipeline first is what makes "gone by morning" true.
Only pipelines labelled `stardelt.io/owner-group=visitors` are deleted; the demo's own
(`demo`) stay.

Two trust stores, and that is why this job is not a single `SSL_CERT_FILE`:

* the public WebPKI roots serve OIDC discovery and the token request (`OIDC_ISSUER` is
  the public issuer, e.g. `https://id.<domain>/realms/stardelt`), as they do for
  `manifests/access-sync.yaml`'s `wait-for-idp`;
* exactly one extra anchor, `TRINO_CA` (Secret `trino-ca`, key `tls.crt`), signs the
  coordinator's certificate behind `TRINO_URL`
  (`https://trino.<ns>.svc.cluster.local:8443`). Nova (`NOVA_TRINO_CA_PEM`), Airflow
  and JupyterHub carry the same one anchor; verification is never disabled and the
  public roots are never replaced. `trino_context()` builds the default store and adds
  that one file.

Every schema and table name read back from `information_schema` was chosen by a
visitor, so it is always quoted through `ident()` and never formatted in raw.

Standard library only (the image is plain `python:slim-bookworm`). No token, secret or
visitor-chosen name is ever printed: the log carries counts and HTTP status codes.
"""

from __future__ import annotations

import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

CATALOG = os.environ.get("CATALOG") or "playground"
NAMESPACE = os.environ.get("NAMESPACE") or "stardelt"
TIMEOUT = 60

K8S_API = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
# The label Nova writes on every pipeline it creates (seen on shop-01-bronze:
# stardelt.io/owner-group=demo). A visitor's pipelines carry `visitors`.
VISITOR_GROUP = "visitors"

# Set in main(): the bearer every Trino request carries and the TLS context they all
# use (public roots plus Secret trino-ca). Tests replace `run` instead.
TOKEN = ""
TRINO_SSL = None

REQUIRED = ("OIDC_ISSUER", "TRINO_URL", "CLIENT_ID", "CLIENT_SECRET")

# Schemas the reset never reads or drops (platform#943). `information_schema` and
# Iceberg's `system` are the connector's own metadata; the two queries below exclude
# them server-side, and the loops skip them again so a row that still arrives is not
# dropped either.
RESERVED_SCHEMAS = ("information_schema", "system")


def trino_context(path):
    """The public roots plus the one namespace anchor Trino's certificate needs."""
    return ssl.create_default_context(cafile=path)


def missing_environment(environ):
    """One sentence per missing variable, so one run reports all of them."""
    missing = []
    for name in REQUIRED:
        if not environ.get(name):
            missing.append(f"{name} is not set - the demo reset needs it")
    path = environ.get("TRINO_CA")
    if not path:
        missing.append("TRINO_CA is not set - the demo reset needs the path to the Trino CA certificate")
    elif not os.path.exists(path):
        missing.append(f"TRINO_CA ({path}) does not exist - the demo reset needs the Trino CA certificate")
    return missing


def token():
    """A client_credentials token for CLIENT_ID, discovered from OIDC_ISSUER.

    Discovery and the token request use the default context (the public roots); the
    client id and secret travel form-encoded in HTTP Basic, never in the query string.
    """
    issuer = os.environ["OIDC_ISSUER"].rstrip("/")
    with urllib.request.urlopen(issuer + "/.well-known/openid-configuration", timeout=TIMEOUT) as response:
        endpoint = json.load(response)["token_endpoint"]
    basic = base64.b64encode(
        f"{os.environ['CLIENT_ID']}:{os.environ['CLIENT_SECRET']}".encode()
    ).decode()
    body = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Authorization": "Basic " + basic,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)["access_token"]


def run(sql):
    """Run one statement to completion and return its rows, following `nextUri`."""
    url = os.environ["TRINO_URL"].rstrip("/") + "/v1/statement"
    headers = {"Authorization": "Bearer " + TOKEN, "Content-Type": "text/plain"}
    request = urllib.request.Request(url, data=sql.encode(), headers=headers)
    rows = []
    while True:
        with urllib.request.urlopen(request, timeout=TIMEOUT, context=TRINO_SSL) as response:
            page = json.load(response)
        if "error" in page:
            raise RuntimeError(page["error"].get("message", "query failed"))
        rows.extend(page.get("data") or [])
        next_uri = page.get("nextUri")
        if not next_uri:
            return rows
        request = urllib.request.Request(next_uri, headers=headers)


def ident(name):
    """Quote one identifier; names are chosen by visitors, so they always go through here."""
    return '"' + name.replace('"', '""') + '"'


def k8s_request(method, path):
    """One request to the API server as this pod's ServiceAccount."""
    token = open(f"{SA_DIR}/token", encoding="utf-8").read().strip()
    context = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    request = urllib.request.Request(
        K8S_API + path,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT, context=context) as answer:
        return json.load(answer) if method == "GET" else None


def delete_visitor_pipelines(namespace):
    """Delete every pipeline the visitors published; returns how many. Names come back from
    the API, so they are quoted on the way into the path, never formatted in raw."""
    listing = k8s_request(
        "GET",
        f"/apis/stardelt.io/v1alpha1/namespaces/{namespace}/pipelines"
        f"?labelSelector={urllib.parse.quote('stardelt.io/owner-group=' + VISITOR_GROUP)}",
    )
    names = [item["metadata"]["name"] for item in listing.get("items", [])]
    for name in names:
        k8s_request(
            "DELETE",
            f"/apis/stardelt.io/v1alpha1/namespaces/{namespace}/pipelines/{urllib.parse.quote(name)}",
        )
    return len(names)


def reset(pipelines=0):
    """Drop every table, view and schema of the catalog and recreate `scratch`.

    Returns the number of drops that failed; the caller exits 1 so the Job shows red.
    `pipelines` is how many visitor pipelines main() already deleted, for the summary.
    The summary is a claim about the catalog *after* the drops, so the catalog is read
    back and anything left there makes the run a failure.
    """
    tables = run(
        f"select table_schema, table_name, table_type from {CATALOG}.information_schema.tables"
        " where table_schema not in ('information_schema', 'system')"
    )
    failed = dropped_tables = dropped_views = dropped_schemas = 0
    for schema, table, table_type in tables:
        if schema in RESERVED_SCHEMAS:
            continue
        is_view = table_type == "VIEW"
        statement = (
            f"drop {'view' if is_view else 'table'} {CATALOG}.{ident(schema)}.{ident(table)}"
        )
        try:
            run(statement)
        except urllib.error.HTTPError as error:
            failed += 1
            print(f"drop failed: {error.code} {error.reason}", file=sys.stderr)
        except RuntimeError as error:
            failed += 1
            print(f"drop failed: {error}", file=sys.stderr)
        else:
            if is_view:
                dropped_views += 1
            else:
                dropped_tables += 1

    schemas = run(
        f"select schema_name from {CATALOG}.information_schema.schemata"
        " where schema_name not in ('information_schema', 'system')"
    )
    for (schema,) in schemas:
        if schema in RESERVED_SCHEMAS:
            continue
        try:
            run(f"drop schema {CATALOG}.{ident(schema)}")
        except urllib.error.HTTPError as error:
            failed += 1
            print(f"drop failed: {error.code} {error.reason}", file=sys.stderr)
        except RuntimeError as error:
            failed += 1
            print(f"drop failed: {error}", file=sys.stderr)
        else:
            dropped_schemas += 1

    run(f"create schema if not exists {CATALOG}.scratch")
    leftover = int(
        str(
            run(
                f"select count(*) from {CATALOG}.information_schema.tables"
                " where table_schema not in ('information_schema', 'system')"
            )[0][0]
        )
    )
    failed += leftover
    if failed or leftover:
        print(
            f"demo-reset: {failed} drop(s) failed; {leftover} object(s) remain in {CATALOG}; "
            "scratch is NOT empty",
            file=sys.stderr,
        )
        return failed
    print(
        f"demo-reset: removed {pipelines} visitor pipeline(s); "
        f"dropped {dropped_tables} tables, {dropped_views} views, "
        f"{dropped_schemas} schemas; scratch ready"
    )
    return 0


def main():
    global TOKEN, TRINO_SSL
    missing = missing_environment(os.environ)
    if missing:
        for sentence in missing:
            print(f"demo-reset: {sentence}", file=sys.stderr)
        return 2
    TRINO_SSL = trino_context(os.environ["TRINO_CA"])
    TOKEN = token()
    # Pipelines first: a scheduled one would re-create the table we are about to drop.
    # A refused or failed API call raises, so the job exits 1 and the CronJob shows red:
    # a reset that silently keeps the pipelines is the bug this step exists to prevent.
    pipelines = delete_visitor_pipelines(NAMESPACE)
    return 1 if reset(pipelines) else 0


if __name__ == "__main__":
    sys.exit(main())
