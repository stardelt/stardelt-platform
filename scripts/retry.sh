#!/usr/bin/env bash
# Run a command up to 3 times with a 20 s pause. GitHub release downloads answer
# 504 in bursts (2026-11-08: three runs on one morning, three different charts).
set -uo pipefail
attempts=3
for i in $(seq 1 "$attempts"); do
  if "$@"; then exit 0; fi
  echo "attempt $i/$attempts failed: $*" >&2
  if [ "$i" -lt "$attempts" ]; then sleep 20; fi
done
exit 1
