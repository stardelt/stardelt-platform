#!/usr/bin/env bash
# Start the Spark Connect server as a long-running driver.
#
# `spark.driver.host` is the address executors dial back to. It is only known
# inside the pod, so the Deployment passes it through the downward API and this
# script forwards it as a --conf, which wins over spark-defaults.conf. Every
# other setting (the Kubernetes master, the Iceberg catalog, the gRPC port)
# stays declarative in the ConfigMap.
#
# `--wait` keeps start-connect-server.sh in the foreground. Without it the
# script daemonizes through spark-daemon.sh: PID 1 exits, the kubelet restarts
# the container, and the pod crash-loops with no useful log.
set -euo pipefail

: "${POD_IP:?POD_IP is required (downward API: status.podIP)}"
SPARK_HOME="${SPARK_HOME:-/opt/spark}"

# Catalog sign-in (platform#283, step 2 of the catalog turn-on). The Iceberg REST
# catalog authenticates as the service client svc-catalog-spark: client id and secret
# arrive in the environment from Secret svc-catalog-spark, the token endpoint follows
# the realm issuer in ConfigMap stardelt-identity. Both are passed as --conf, which is
# the only channel Spark offers for a catalog property — and they stay out of
# spark-defaults.conf, a ConfigMap the whole namespace can read. The value therefore
# exists in this driver's own arguments and nowhere else (executors do not talk to the
# catalog, and Spark does not copy app confs into the executor config maps).
# Without an IdP the three variables are absent — an `install-core` cluster — and the
# driver keeps talking to Lakekeeper anonymously, which is the shape it had before.
catalog_conf=()
if [[ -n "${CATALOG_CLIENT_ID:-}" && -n "${CATALOG_CLIENT_SECRET:-}" && -n "${CATALOG_OIDC_ISSUER:-}" ]]; then
  catalog_conf=(
    --conf "spark.sql.catalog.warehouse.credential=${CATALOG_CLIENT_ID}:${CATALOG_CLIENT_SECRET}"
    --conf "spark.sql.catalog.warehouse.oauth2-server-uri=${CATALOG_OIDC_ISSUER%/}/protocol/openid-connect/token"
  )
else
  echo "stardelt-connect-server: catalog sign-in is off (no svc-catalog-spark Secret or realm issuer) — Lakekeeper sees this driver as anonymous" >&2
fi

exec "${SPARK_HOME}/sbin/start-connect-server.sh" --wait \
  --conf "spark.driver.host=${POD_IP}" \
  ${catalog_conf[@]+"${catalog_conf[@]}"} \
  "$@"
