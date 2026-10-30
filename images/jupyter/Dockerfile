# stardelt's Jupyter single-user image — what a person gets when they open
# Notebooks in Nova.
#
# Upstream `scipy-notebook` plus the client libraries a warehouse notebook needs,
# so a new user can query the platform without a `pip install` in the first cell:
#   - trino            Python client for the warehouse (Trino → Lakekeeper)
#   - pyspark[connect] Spark Connect client, ready for the Spark work (step 3)
#   - pandas, pyarrow  DataFrames and Arrow; scipy-notebook ships pandas but not
#                      pyarrow, which the Spark/Arrow path needs
#   - jupyterlab-git   Git panel in JupyterLab, so notebooks live in the user's
#                      own repository (never in the image)
#   - nbgitpuller      One-click clone of a repository into the user's home,
#                      for training sessions (hub link generator)
#
# Deliberately absent: `jupyterlab-sql`. Its last release (0.3.3, 2020) predates
# JupyterLab 4, and it has no way to carry the per-user token — it would ship a
# SQL UI that cannot authenticate to the warehouse.
#
# No credentials and no connection string live here. The hub copies the
# signed-in user's Keycloak access token into the pod as `TRINO_TOKEN` at spawn
# (helm-values/jupyterhub.yaml, `20-notebook-identity`); `TRINO_URL` comes from
# the same chart values.
#
# Framing. Nova frames the notebook, and a single-user server executes
# arbitrary code, so Jupyter Server's `frame-ancestors` list is a deliberate
# choice: exactly `'self'` plus Nova's origin, which the hub passes at spawn
# from the identity contract. The config file documents the mechanism.
# Python 3.11 (3.11.10 in the 2024-10-07 base image). Keep both on the same
# Python minor: Spark Connect UDFs fail otherwise — the Spark image installs its
# own CPython 3.11 for the workers and must stay on this minor (platform#369).
FROM quay.io/jupyter/scipy-notebook:2024-10-07

USER ${NB_UID}

# `--upgrade-strategy only-if-needed` keeps the base image's conda packages
# unless one of these genuinely needs a newer version. The build fails here, not
# in a user's first cell, if an import is broken.
# The base image ships `jupyterlab-git` 0.50.1, and upgrading it inside the
# same `pip install` breaks its prebuilt frontend: pip installs the new
# dependency (`jupyterlab-git-core`) before it uninstalls the old package, and
# that late uninstall deletes the new `package.json`, so `labextension list`
# no longer shows `@jupyterlab/git`. Uninstall first, in its own invocation.
# The Spark workers run these exact versions of pandas, pyarrow and numpy
# (images/spark/Dockerfile installs them into its own Python 3.11): a pandas UDF
# pickles pandas objects on this side and rebuilds them there (platform#369).
# The Spark Connect client is on the SAME Spark line as the server image
# (apache/spark:4.1.3): a newer client reads the server's settings in the old
# spelling -- `spark.sql.session.localRelationSizeLimit` comes back as `3221225472b`
# -- and every createDataFrame dies with `invalid literal for int()` (platform#399).
# scripts/check-spark-parity.sh fails the build when the two drift apart.
RUN python3 -m pip uninstall -y jupyterlab-git \
    && python3 -m pip install --no-cache-dir --upgrade-strategy only-if-needed \
        pandas==2.2.3 \
        pyarrow==18.1.0 \
        'pyspark[connect]==4.1.3' \
        jupyterlab-git==0.55.0 \
        nbgitpuller==1.3.0 \
        papermill==2.7.0 \
        trino==0.340.0 \
    && python3 -c "import pandas, pyarrow, pyspark, trino; print('pandas', pandas.__version__, '| pyarrow', pyarrow.__version__, '| pyspark', pyspark.__version__, '| trino', trino.__version__)" \
    && python3 -c "import jupyterlab_git, nbgitpuller; print('jupyterlab-git', jupyterlab_git.__version__, '| nbgitpuller', nbgitpuller.__version__)" \
    && python3 -c "import papermill; print('papermill', papermill.__version__)" \
    && git --version \
    && { jupyter labextension list 2>&1 | tee /tmp/labext.txt | grep -i '@jupyterlab/git' || { echo '--- full labextension list ---'; cat /tmp/labext.txt; exit 1; }; } \
    && jupyter server extension list 2>&1 | grep -i 'nbgitpuller'

# Pristine copy of the quickstart. The spawner's postStart hook copies missing
# notebooks into the user's home (`cp -n`), so edits survive a restart and a
# newer image replaces the source without touching the user's copy.
COPY --chown=${NB_UID}:${NB_GID} notebooks/ /opt/stardelt/notebooks/

# The stardelt notebook helper (`import stardelt`: sql, write_df, spark, and
# the connection() stub) has its own repository (stardelt/stardelt-python) and
# is installed here as a **pinned release**. Pure Python, MIT, versioned and
# tested there; the platform consumes one release of it (platform#417).
#
# Pinned by commit SHA, not by tag: a moving tag is not an upgrade path — the
# same rule the image pins follow (scripts/pin-image.sh). The SHA below is the
# release v0.1.2
# (https://github.com/stardelt/stardelt-python/releases/tag/v0.1.2).
#
# The Makefile holds the pin (STARDELT_LIB_REF) and passes it as a build arg;
# scripts/check-stardelt-pin.sh fails the build when this default and the
# Makefile's ref disagree. Installed rather than copied so every notebook
# imports it with no sys.path tweak; the import check fails the build here, not
# in a user's first cell.
ARG STARDELT_LIB_REF=bc44a3e6df14b59df0a5b60e5893010df74293d5
RUN python3 -m pip install --no-cache-dir --upgrade-strategy only-if-needed \
        "stardelt @ git+https://github.com/stardelt/stardelt-python@${STARDELT_LIB_REF}" \
    && python3 -c "import stardelt; print('stardelt', stardelt.__version__)" \
    && python3 -c "import stardelt.notebook_run; print('stardelt.notebook_run: the notebook task wrapper is installed')"

# The single-user server's framing policy (Nova's origin, passed at spawn) —
# see the file's docstring for why this exists and what happens without it.
COPY jupyter_server_config.py /usr/local/etc/jupyter/jupyter_server_config.py
