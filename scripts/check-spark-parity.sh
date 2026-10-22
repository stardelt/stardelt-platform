#!/usr/bin/env bash
# The notebook's Spark Connect client and the platform's Spark server must be on the
# same Spark line.
#
#   bash scripts/check-spark-parity.sh
#
# A client that is newer than the server reads the server's settings in a spelling it
# mis-parses: Spark 4.1.3 answers `spark.sql.session.localRelationSizeLimit` as
# `3221225472b` (Scala BigInt notation), the 4.2 client calls `int()` on it, and every
# `createDataFrame` in every notebook fails with `invalid literal for int()` (platform#399).
# Both pins are read from the files that carry them, so the drift fails here instead of
# in a user's first cell.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

notebook_dockerfile="images/jupyter/Dockerfile"
spark_dockerfile="images/spark/Dockerfile"

client=$(grep -oE "pyspark\[connect\]==[0-9]+(\.[0-9]+){0,2}" "$notebook_dockerfile" | head -1 | sed 's/.*==//')
server=$(grep -oE "^FROM apache/spark:[0-9]+(\.[0-9]+){0,2}" "$spark_dockerfile" | head -1 | sed 's/.*://')

if [ -z "$client" ]; then
  echo "check-spark-parity: no pyspark pin found in $notebook_dockerfile" >&2
  exit 1
fi
if [ -z "$server" ]; then
  echo "check-spark-parity: no Spark version found in $spark_dockerfile" >&2
  exit 1
fi

client_line=$(echo "$client" | cut -d. -f1,2)
server_line=$(echo "$server" | cut -d. -f1,2)

if [ "$client_line" != "$server_line" ]; then
  echo "check-spark-parity: the notebook's Spark client is $client but the Spark server image is $server." >&2
  echo "  They must be on the same Spark line (platform#399): a newer client reads the" >&2
  echo "  server's settings in the old spelling and fails with 'invalid literal for int()'." >&2
  exit 1
fi

echo "check-spark-parity: OK (client $client, server $server)"
