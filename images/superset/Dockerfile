# Stardelt's Superset image: baseline Apache Superset 5.0 + the python
# drivers the upstream image does not ship in its venv:
#   - psycopg2-binary: needed to connect to the chart's bundled Postgres
#     backend. Without it the init-db job and gunicorn workers crash.
#   - trino:           SQLAlchemy driver for the Trino warehouse catalog.
#
# Built with the user-managed image so we don't pay a `pip install` cost on
# every pod startup, and so the chart's bootstrapScript can stay minimal.
FROM apachesuperset.docker.scarf.sh/apache/superset:5.0.0

USER root
ENV UV_CACHE_DIR=/tmp/uv-cache
RUN uv pip install --python /app/.venv/bin/python --no-cache \
        psycopg2-binary==2.9.10 \
        trino==0.330.0 \
    && rm -rf /tmp/uv-cache
USER superset
