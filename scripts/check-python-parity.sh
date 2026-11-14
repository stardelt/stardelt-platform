#!/usr/bin/env bash
# The notebook image's Python and the Spark workers' Python must be the same minor
# (platform#369): Spark Connect pickles user Python in the notebook and unpickles it on
# the executor, so a mismatch fails every UDF, pandas_udf, mapInPandas, applyInPandas and
# foreach with PYTHON_VERSION_MISMATCH. Both pins are read from the files that carry them,
# so the drift fails here instead of in a user's first cell.
#
#   bash scripts/check-python-parity.sh
#
# NOTEBOOK_DOCKERFILE / SPARK_DOCKERFILE override the two inputs (the unit test uses them).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

notebook_dockerfile="${NOTEBOOK_DOCKERFILE:-images/jupyter/Dockerfile}"
spark_dockerfile="${SPARK_DOCKERFILE:-images/spark/Dockerfile}"

notebook=$(grep -oE '^ARG STARDELL_PYTHON_MINOR=[0-9]+\.[0-9]+' "$notebook_dockerfile" | head -1 | cut -d= -f2 || true)
spark=$(grep -oE 'cpython-[0-9]+\.[0-9]+\.' "$spark_dockerfile" | head -1 | sed -e 's/^cpython-//' -e 's/\.$//' || true)

if [ -z "$notebook" ]; then
  echo "check-python-parity: no 'ARG STARDELL_PYTHON_MINOR=<major>.<minor>' in $notebook_dockerfile" >&2
  exit 1
fi
if [ -z "$spark" ]; then
  echo "check-python-parity: no 'cpython-<major>.<minor>.' archive in $spark_dockerfile" >&2
  exit 1
fi

if [ "$notebook" != "$spark" ]; then
  echo "check-python-parity: the notebook image is Python $notebook but the Spark workers are Python $spark." >&2
  echo "  They must be the same minor (platform#369): a mismatch fails every UDF in every notebook" >&2
  echo "  with PYTHON_VERSION_MISMATCH. Move both images (and pandas/pyarrow in both Dockerfiles)" >&2
  echo "  in one change, or neither." >&2
  exit 1
fi

echo "check-python-parity: OK (notebook $notebook, spark $spark)"
