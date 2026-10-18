# stardelt's Jupyter single-user image — what a person gets when they open
# Notebooks in Nova.
#
# Upstream `scipy-notebook` plus the client libraries a warehouse notebook needs,
# so a new user can query the platform without a `pip install` in the first cell:
#   - trino            Python client for the warehouse (Trino → Lakekeeper)
#   - pyspark[connect] Spark Connect client, ready for the Spark work (step 3)
#   - pandas, pyarrow  DataFrames and Arrow; scipy-notebook ships pandas but not
#                      pyarrow, which the Spark/Arrow path needs
#
# Deliberately absent: `jupyterlab-sql`. Its last release (0.3.3, 2020) predates
# JupyterLab 4, and it has no way to carry the per-user token — it would ship a
# SQL UI that cannot authenticate to the warehouse.
#
# No credentials and no connection string live here. The hub copies the
# signed-in user's Keycloak access token into the pod as `TRINO_TOKEN` at spawn
# (helm-values/jupyterhub.yaml, `20-notebook-identity`); `TRINO_URL` comes from
# the same chart values.
FROM quay.io/jupyter/scipy-notebook:2024-10-07

USER ${NB_UID}

# `--upgrade-strategy only-if-needed` keeps the base image's conda packages
# unless one of these genuinely needs a newer version. The build fails here, not
# in a user's first cell, if an import is broken.
RUN python3 -m pip install --no-cache-dir --upgrade-strategy only-if-needed \
        pandas==2.2.3 \
        pyarrow==18.1.0 \
        'pyspark[connect]==4.2.0' \
        trino==0.340.0 \
    && python3 -c "import pandas, pyarrow, pyspark, trino; print('pandas', pandas.__version__, '| pyarrow', pyarrow.__version__, '| pyspark', pyspark.__version__, '| trino', trino.__version__)"

# Pristine copy of the quickstart. The spawner's postStart hook copies missing
# notebooks into the user's home (`cp -n`), so edits survive a restart and a
# newer image replaces the source without touching the user's copy.
COPY --chown=${NB_UID}:${NB_GID} notebooks/ /opt/stardelt/notebooks/
