#!/usr/bin/env bash
# Follow one app's `dev` tag and roll its Deployment when CI publishes a new build.
#
#   scripts/dev-watch.sh                          # nova, every 15 s
#   scripts/dev-watch.sh stardelt-operator        # another image
#   APP=nova INTERVAL=5 NS=lab scripts/dev-watch.sh
#   ONESHOT=1 scripts/dev-watch.sh                # check once and exit (a timer runs this)
#
# Why: `make dev-refresh` is one shot, so the loop after a merge is "merge, remember to
# run it, wait". This closes that loop. Each tick asks the registry for the digest of
# the tag and compares it with what the Deployment runs, so it costs one HEAD request
# and stays quiet until something changed.
#
# It never writes the repository: recording the digest is `make pin-images`, a
# deliberate act. Ctrl-C stops it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP="${1:-${APP:-nova}}"
NS="${NS:-${NAMESPACE:-stardelt}}"
INTERVAL="${INTERVAL:-15}"
TAG="${TAG:-dev}"

command -v kubectl >/dev/null 2>&1 || { echo "dev-watch: kubectl not found" >&2; exit 1; }

case "$APP" in
  spark) deploy="spark-connect" ;;
  *)     deploy="$APP" ;;
esac

kubectl -n "$NS" get deploy "$deploy" >/dev/null 2>&1 || {
  echo "dev-watch: no deployment $NS/$deploy" >&2
  exit 1
}

echo "› watching $APP ($NS/$deploy:$TAG) every ${INTERVAL}s — Ctrl-C stops it"

trap 'printf "\n› stopped\n"; exit 0' INT TERM

while :; do
  want="$(PRINT_DIGEST=1 APP="$APP" NS="$NS" TAG="$TAG" bash scripts/pin-image.sh 2>/dev/null || true)"
  live="$(kubectl -n "$NS" get deploy "$deploy" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | sed -n 's/.*@\(sha256:[0-9a-f]*\)$/\1/p')"

  if [ -z "$want" ]; then
    printf '  %s could not resolve %s (private package needs read:packages?)\n' "$(date +%H:%M:%S)" "$TAG" >&2
  elif [ "$want" != "$live" ]; then
    printf '  %s new build %s… — rolling %s\n' "$(date +%H:%M:%S)" "${want:0:19}" "$deploy"
    WRITE_MANIFEST=0 APP="$APP" NS="$NS" TAG="$TAG" bash scripts/pin-image.sh 2>&1 \
      | sed 's/^/    /' || printf '    rollout failed — retrying on the next tick\n'
  fi

  [ "${ONESHOT:-0}" = "1" ] && exit 0
  sleep "$INTERVAL"
done
