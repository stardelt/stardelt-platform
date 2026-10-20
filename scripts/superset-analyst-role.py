#!/usr/bin/env python3
"""Create/refresh the Superset role for normal platform users (platform#287).

`stardelt-analyst` is the built-in `Gamma` and `sql_lab` permission sets plus
Alpha's dataset/datasource additions and `database_access` on the one Trino
database: SQL Lab and the datasets of the warehouse, nothing administrative
(no `can_write` on Database, no `all_database_access` / `all_datasource_access`,
no `can_upload` on Database). The init Job runs this after `superset init` and
after the datasource import, so a fresh install has the role before the first
login; `AUTH_ROLES_MAPPING` then syncs it from group `stardelt-users`.

Idempotent: it converges the role to exactly that permission set (drift is
removed) and prints one line. Run it inside the Superset app environment:

    kubectl -n stardelt exec deploy/superset -- python /app/configs/superset-analyst-role.py
"""

from superset.app import create_app

app = create_app()
with app.app_context():
    from superset import db, security_manager as sm
    from superset.models.core import Database

    d = db.session.query(Database).filter_by(database_name="Trino Warehouse").one()
    names = lambda r: {(p.permission.name, p.view_menu.name) for p in r.permissions}
    gamma, alpha, sqll = (sm.find_role(n) for n in ("Gamma", "Alpha", "sql_lab"))
    want = names(gamma) | names(sqll)
    extra = {("can_write", "Dataset"), ("can_duplicate", "Dataset"), ("can_get_or_create_dataset", "Dataset"),
             ("can_save", "Datasource"), ("can_samples", "Datasource"), ("can_get_column_values", "Datasource")}
    want |= (names(alpha) & extra)
    role = sm.find_role("stardelt-analyst") or sm.add_role("stardelt-analyst")
    for n, v in sorted(want - names(role)):
        pv = sm.find_permission_view_menu(n, v)
        if pv:
            sm.add_permission_role(role, pv)
    sm.add_permission_role(role, sm.find_permission_view_menu("database_access", d.perm))
    for n, v in names(role) - want - {("database_access", d.perm)}:
        sm.del_permission_role(role, sm.find_permission_view_menu(n, v))   # drift: the role is exactly this set
    sm.get_session.commit()
    print("role stardelt-analyst:", len(role.permissions), "permissions")
