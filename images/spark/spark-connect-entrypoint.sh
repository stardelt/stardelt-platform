#!/usr/bin/env bash
# Start the Spark Connect server as a long-running driver.
#
# `spark.driver.host` is the address executors dial back to. It is only known
# inside the pod, so the Deployment passes it through the downward API and this
# script forwards it as a --conf, which wins over spark-defaults.conf. Every
# other setting (the Kubernetes master, the Iceberg extensions, the gRPC port)
# stays declarative in the ConfigMap. Catalogs are not here: they belong to the
# person and the notebook helper configures them on the session (platform#317).
#
# `--wait` keeps start-connect-server.sh in the foreground. Without it the
# script daemonizes through spark-daemon.sh: PID 1 exits, the kubelet restarts
# the container, and the pod crash-loops with no useful log.
set -euo pipefail

: "${POD_IP:?POD_IP is required (downward API: status.podIP)}"
SPARK_HOME="${SPARK_HOME:-/opt/spark}"

exec "${SPARK_HOME}/sbin/start-connect-server.sh" --wait \
  --conf "spark.driver.host=${POD_IP}" \
  "$@"
