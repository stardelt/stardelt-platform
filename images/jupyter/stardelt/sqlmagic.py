"""JupySQL integration for stardelt notebooks."""
import os

from sqlalchemy import create_engine
from sqlalchemy.pool import NullPool

import stardelt


def _creator():
    return stardelt._connect()


def _configure_jupysql():
    try:
        from sql import connection as sql_connection
        from sql.magic import SqlMagic
    except Exception:
        return

    os.environ.setdefault("PLOOMBER_STATS_ENABLED", "false")

    try:
        if hasattr(SqlMagic, "autopandas"):
            SqlMagic.autopandas = False
        if hasattr(SqlMagic, "displaylimit"):
            SqlMagic.displaylimit = 100
        if hasattr(SqlMagic, "autolimit"):
            SqlMagic.autolimit = 10000
        if hasattr(SqlMagic, "feedback"):
            SqlMagic.feedback = 0
    except Exception:
        pass

    try:
        engine = create_engine("trino://", creator=_creator, poolclass=NullPool)
        try:
            orig = sql_connection.SQLAlchemyConnection._get_database_information
            sql_connection.SQLAlchemyConnection._get_database_information = (
                lambda self: {"dialect": "trino", "driver": "trino", "server_version_info": None}
            )
            try:
                conn = sql_connection.SQLAlchemyConnection(engine, alias="warehouse")
            finally:
                sql_connection.SQLAlchemyConnection._get_database_information = orig
            sql_connection.ConnectionManager.connections["warehouse"] = conn
            sql_connection.ConnectionManager.current = conn
            return
        except Exception:
            pass
        try:
            sql_connection.ConnectionManager.set(engine, displaycon=False, alias="warehouse")
        except Exception:
            pass
    except Exception:
        pass


_configure_jupysql()
