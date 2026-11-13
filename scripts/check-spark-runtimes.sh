#!/usr/bin/env bash
# The Spark runtime catalogue the operator's SparkCluster controller reads and the
# Makefile path's spark-defaults.conf are one set of settings (internal#161 slice 4a).
#
#   bash scripts/check-spark-runtimes.sh
#
# The operator turns a catalogue entry into {image, sparkVersion, serviceAccount,
# sparkConf} and owns exactly the keys SparkConnect fills from the SparkCluster spec
# (spark.master, the namespace, the container image, the executor service account, the
# driver/executor sizing and dynamic allocation). Everything else must be identical to
# manifests/spark.yaml's spark-defaults.conf — otherwise a Spark started through the
# operator differs from a Spark started with `make install` in a way nobody chose.
#
# Two paths, one file each: a digest bump or a setting change that touches only one of
# them fails here (the same rule as check-spark-parity.sh, platform#399).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

catalogue="chart/files/spark-runtimes.json"
manifest="manifests/spark.yaml"
spark_dockerfile="images/spark/Dockerfile"

fail() {
  echo "check-spark-runtimes: $*" >&2
  exit 1
}

# The keys SparkConnect owns and stardelt-operator#460's builder fills from the
# SparkCluster spec, and the two server-process UI settings: the shared Spark Connect
# server turns the UI and its Prometheus servlet on because it is the scraped endpoint
# (stardelt-platform#1158); the per-user SparkCluster servers read this catalogue and
# stay dark (a test pins `spark.ui.enabled: false` there). They are the only allowed
# difference between the two paths.
excluded_keys=$(cat <<'EOF'
spark.master
spark.kubernetes.namespace
spark.kubernetes.container.image
spark.kubernetes.authenticate.executor.serviceAccountName
spark.driver.memory
spark.driver.maxResultSize
spark.executor.memory
spark.executor.memoryOverhead
spark.executor.cores
spark.dynamicAllocation.enabled
spark.dynamicAllocation.shuffleTracking.enabled
spark.dynamicAllocation.minExecutors
spark.dynamicAllocation.initialExecutors
spark.dynamicAllocation.maxExecutors
spark.dynamicAllocation.executorIdleTimeout
spark.dynamicAllocation.shuffleTracking.timeout
spark.ui.enabled
spark.ui.prometheus.enabled
EOF
)

# --- 1. the catalogue parses and carries exactly one runtime ------------------
[ -f "$catalogue" ] || fail "no $catalogue"
jq -e . "$catalogue" > /dev/null 2>&1 || fail "$catalogue is not valid JSON"

runtime_count=$(jq -r 'keys | length' "$catalogue")
[ "$runtime_count" = "1" ] \
  || fail "$catalogue has $runtime_count runtimes; this check knows one ($(jq -r 'keys | join(", ")' "$catalogue"))"
runtime=$(jq -r 'keys[0]' "$catalogue")

# --- 2. image == the single pinned Spark reference in manifests/spark.yaml ----
catalogue_image=$(jq -r --arg n "$runtime" '.[$n].image' "$catalogue")
manifest_images=$(grep -oE 'ghcr\.io/stardelt/spark:dev@sha256:[0-9a-f]{64}' "$manifest" | sort -u || true)
manifest_image_count=$(printf '%s' "$manifest_images" | grep -c . || true)
[ "$manifest_image_count" = "1" ] \
  || fail "$manifest has $manifest_image_count distinct Spark image references; expected exactly one"
[ "$catalogue_image" = "$manifest_images" ] \
  || fail "image differs: $catalogue has '$catalogue_image', $manifest has '$manifest_images'"

# --- 3. sparkVersion == the base tag of images/spark/Dockerfile ---------------
catalogue_spark=$(jq -r --arg n "$runtime" '.[$n].sparkVersion' "$catalogue")
dockerfile_spark=$(grep -oE '^FROM apache/spark:[0-9]+\.[0-9]+\.[0-9]+' "$spark_dockerfile" \
  | head -1 | sed 's|^FROM apache/spark:||' || true)
[ -n "$dockerfile_spark" ] || fail "no 'FROM apache/spark:<version>' in $spark_dockerfile"
[ "$catalogue_spark" = "$dockerfile_spark" ] \
  || fail "sparkVersion differs: $catalogue has '$catalogue_spark', $spark_dockerfile builds '$dockerfile_spark'"

# --- 4. serviceAccount == the executor ServiceAccount in manifests/spark.yaml --
catalogue_sa=$(jq -r --arg n "$runtime" '.[$n].serviceAccount' "$catalogue")
manifest_sa=$(awk '/^[[:space:]]*spark\.kubernetes\.authenticate\.executor\.serviceAccountName[[:space:]]/ { print $2; exit }' "$manifest")
[ -n "$manifest_sa" ] || fail "no executor serviceAccountName in $manifest"
[ "$catalogue_sa" = "$manifest_sa" ] \
  || fail "serviceAccount differs: $catalogue has '$catalogue_sa', $manifest has '$manifest_sa'"

# --- 5. sparkConf == spark-defaults.conf minus the SparkConnect keys ----------
# The block's lines run from `spark-defaults.conf: |` to the next non-blank line
# that is not indented by four spaces or more; a YAML parser is not needed for it.
manifest_conf=$(awk '
  /^[[:space:]]*spark-defaults\.conf:[[:space:]]*\|[[:space:]]*$/ { inblock = 1; next }
  inblock && /^[[:space:]]*$/ { next }
  inblock && /^    / { print; next }
  inblock { exit }
' "$manifest")
[ -n "$manifest_conf" ] || fail "no spark-defaults.conf block found in $manifest"

manifest_pairs=$(printf '%s\n' "$manifest_conf" | awk -v exclusions="$excluded_keys" '
  BEGIN {
    n = split(exclusions, lines, "\n")
    for (i = 1; i <= n; i++) skip[lines[i]] = 1
  }
  {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (line !~ /^spark\./) next
    key = line
    sub(/[[:space:]].*$/, "", key)
    if (key in skip) next
    value = line
    sub(/^[^[:space:]]+[[:space:]]+/, "", value)
    print key "\t" value
  }' | sort)
[ -n "$manifest_pairs" ] || fail "no spark.* settings outside the SparkConnect keys in $manifest"

json_pairs=$(jq -r --arg n "$runtime" '.[$n].sparkConf | to_entries[] | "\(.key)\t\(.value)"' "$catalogue" \
  | awk -F'\t' -v exclusions="$excluded_keys" '
      BEGIN { n = split(exclusions, lines, "\n"); for (i = 1; i <= n; i++) skip[lines[i]] = 1 }
      !($1 in skip)' \
  | sort)

declare -A mconf jconf
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] && mconf[$key]=$value
done <<< "$manifest_pairs"
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] && jconf[$key]=$value
done <<< "$json_pairs"

for key in $(printf '%s\n' "${!mconf[@]}" "${!jconf[@]}" | grep -v '^$' | sort -u); do
  if [ -z "${mconf[$key]+set}" ]; then
    fail "sparkConf key '$key' is in $catalogue but not in $manifest (it is not one of the SparkConnect keys)"
  fi
  if [ -z "${jconf[$key]+set}" ]; then
    fail "sparkConf key '$key' is in $manifest but not in $catalogue (it is not one of the SparkConnect keys)"
  fi
  if [ "${mconf[$key]}" != "${jconf[$key]}" ]; then
    fail "sparkConf key '$key' differs: $manifest has '${mconf[$key]}', $catalogue has '${jconf[$key]}'"
  fi
done

digest=${catalogue_image##*sha256:}
echo "check-spark-runtimes: OK ($runtime, Spark $catalogue_spark, image ${digest:0:8}…)"
