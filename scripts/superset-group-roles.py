#!/usr/bin/env python3
"""Create an Superset role per Catalog grant group (platform#494).

Mirrors the Airflow stardelt-group-* model. For each Catalog object (catalogs.stardelt.io)
in the namespace, match it to a Superset Trino database by the URI path (e.g.
`trino://host:443/<catalog>`), and for each grant whose group is not
`stardelt-admins`, converge role `stardelt-group-<group>` to database_access on
that database and datasource_access on its datasets. Drift is removed.
"""

import json
import ssl
import urllib.error
import urllib.request

API_HOST = "https://kubernetes.default.svc"
API_BASE = f"{API_HOST}/apis/stardelt.io/v1alpha1"


def _sa_token():
    with open("/var/run/secrets/kubernetes.io/serviceaccount/token", "r") as f:
        return f.read().strip()


def _sa_ca():
    return "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def _namespace():
    with open("/var/run/secrets/kubernetes.io/serviceaccount/namespace", "r") as f:
        return f.read().strip()


def _api_request(path):
    token = _sa_token()
    ca = _sa_ca()
    req = urllib.request.Request(f"{API_BASE}{path}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    context = ssl.create_default_context(cafile=ca)
    try:
        with urllib.request.urlopen(req, context=context) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Kubernetes API error {e.code} for {path}: {body}") from e


def catalog_from_uri(uri):
    uri = str(uri or "")
    if "://" not in uri:
        return None
    rest = uri.split("://", 1)[1]
    rest = rest.split("?", 1)[0]
    if "/" not in rest:
        return None
    return rest.split("/", 1)[1].strip() or None


EXTRA = {("can_write", "Dataset"), ("can_duplicate", "Dataset"), ("can_get_or_create_dataset", "Dataset"),
         ("can_save", "Datasource"), ("can_samples", "Datasource"), ("can_get_column_values", "Datasource")}


def is_trino(uri):
    return str(uri or "").lower().startswith("trino://")


def grants(databases, tables):
    wanted = {("database_access", perm) for perm in databases}
    wanted |= {("datasource_access", perm) for perm in tables if perm}
    return wanted


def converge(current, want, granted):
    keep = want | granted
    return sorted(keep - current), sorted(current - keep)


def main():
    from superset.app import create_app

    app = create_app()
    with app.app_context():
        from superset import db, security_manager as sm
        from superset.connectors.sqla.models import SqlaTable
        from superset.models.core import Database

        ns = _namespace()
        try:
            data = _api_request(f"/namespaces/{ns}/catalogs")
        except Exception as e:
            print(f"failed to list catalogs: {e}")
            raise
        catalogs = data.get("items") or []

        # Build map from catalog name -> (db, datasets)
        trino_dbs = [d for d in db.session.query(Database).order_by(Database.id) if is_trino(d.sqlalchemy_uri)]
        db_by_catalog = {}
        for d in trino_dbs:
            cat = catalog_from_uri(d.sqlalchemy_uri)
            if cat:
                db_by_catalog[cat] = d

        names_fn = lambda r: {(p.permission.name, p.view_menu.name) for p in r.permissions}

        for cat in catalogs:
            meta = cat.get("metadata") or {}
            spec = cat.get("spec") or {}
            cat_name = meta.get("name")
            if not cat_name:
                continue
            db_obj = db_by_catalog.get(cat_name)
            if not db_obj:
                print(f"orphan {cat_name}")
                continue
            grants_list = spec.get("grants") or []
            groups = set()
            for g in grants_list:
                if not isinstance(g, dict):
                    continue
                grp = g.get("group")
                if grp and str(grp).strip() and str(grp).strip() != "stardelt-admins":
                    groups.add(str(grp).strip())
            if not groups:
                continue
            # Get datasets for this database
            tables = db.session.query(SqlaTable).filter(SqlaTable.database_id == db_obj.id).all()
            granted = grants([db_obj.perm], [t.perm for t in tables])
            want = set()  # per-group roles only get what's granted for this catalog; they also get Gamma/stardelt-analyst via mapping? The ticket says "stardelt-analyst keeps Gamma + SQL Lab but loses the blanket..." and group roles carry catalogs. Also in mapping we add the group role to users in that group - so the role itself needs the permissions.
            for grp in sorted(groups):
                role_name = f"stardelt-group-{grp}"
                role = sm.find_role(role_name) or sm.add_role(role_name)
                add, remove = converge(names_fn(role), want, granted)
                for n, v in add:
                    pv = sm.find_permission_view_menu(n, v)
                    if pv:
                        sm.add_permission_role(role, pv)
                for n, v in remove:
                    pv = sm.find_permission_view_menu(n, v)
                    if pv:
                        sm.del_permission_role(role, pv)
                print(f"role {role_name}: {len(role.permissions)} permissions (db {db_obj.database_name})")
        sm.get_session.commit()
        print("superset-group-roles: done")


if __name__ == "__main__":
    main()
