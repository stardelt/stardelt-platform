# Superset's own stored connection to Trino — the path every query takes.
#
#   kubectl -n stardelt exec -i deploy/superset -- python - < scripts/superset-probe.py
#
# Loads the `Trino Warehouse` database row from Superset's metadata database and
# runs `select current_user` through the engine Superset builds from it — including
# SQLALCHEMY_CUSTOM_PASSWORD_STORE, which is where the `superset` service account's
# password comes from (#278). A credential stored in the URI, or a password in the
# pod environment that Trino no longer accepts, fails here and nowhere else in
# scripts/verify-trino-auth.sh.
#
# Prints one line and no secret: the current user, or the exception type and the
# first 160 characters of its message.
from superset.app import create_app

app = create_app()
with app.app_context():
    from sqlalchemy import text

    from superset import db
    from superset.models.core import Database

    d = db.session.query(Database).filter_by(database_name="Trino Warehouse").one()
    try:
        with d.get_sqla_engine() as engine:
            with engine.connect() as conn:
                print("current_user =", conn.execute(text("select current_user")).scalar())
    except Exception as e:
        print("FAILED:", type(e).__name__, str(e)[:160].replace("\n", " "))
        raise SystemExit(1)
