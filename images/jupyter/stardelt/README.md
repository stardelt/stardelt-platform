# stardelt notebook helper

The small package the notebook image ships: `stardelt.sql` (query as the
signed-in hub user), `stardelt.write_df` (governed DataFrame writes),
`stardelt.spark` (Spark Connect session), `stardelt.connection` (reserved
stub for the connections work).

Pure Python, MIT. Installed in the image (`images/jupyter/Dockerfile`);
tested in CI (`images/jupyter/tests/`, the `notebook-helper` job in
`.github/workflows/ci.yml`). The full contract is the docstrings in
`__init__.py` — this file exists so the build backend has a readme.
