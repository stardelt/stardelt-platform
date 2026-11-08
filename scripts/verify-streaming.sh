#!/usr/bin/env bash
# Prove the streaming pillar is wired: the broker is Ready, the Spark Operator watches this
# namespace, every StreamApp's status is current, and the Strimzi controller is not crash-looping.
#
#   NS=stardelt bash scripts/verify-streaming.sh
#
# Read-only. Exit 0 = PASS, 1 = FAIL, 3 = UNVERIFIED (could not see the subject).
set -euo pipefail

NS="${NS:-${NAMESPACE:-stardelt}}"
command -v kubectl >/dev/null 2>&1 || { echo "verify-streaming: kubectl not found" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "UNVERIFIED (python3 not found)" >&2; exit 3; }

problems=0
streams=0

# ---------------------------------------------------------------------------
# 1. Not installed is a pass: a cluster that has no Kafka has no streaming
#    pillar to be broken (install-core, the identity-only install).
# ---------------------------------------------------------------------------
if ! err="$(kubectl -n "$NS" get kafkas.kafka.strimzi.io kafka 2>&1 >/dev/null)"; then
  if printf '%s' "$err" | grep -q 'NotFound'; then
    echo "– streaming: not installed (no Kafka kafka in $NS)"
    echo "PASS (streaming is not installed)"
    exit 0
  fi
  echo "UNVERIFIED ($err)"
  exit 3
fi

# ---------------------------------------------------------------------------
# 2. The broker is Ready. A Kafka whose Ready condition is False still lists,
#    and every StreamApp pointed at it fails at runtime.
# ---------------------------------------------------------------------------
ready="$(kubectl -n "$NS" get kafka kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || true)"
if [ "$ready" = "True" ]; then
  echo "✓ kafka   broker Ready"
else
  echo "✗ kafka   broker is not Ready (got '$ready')"
  problems=$((problems + 1))
fi

# ---------------------------------------------------------------------------
# 3. The Spark Operator's namespace watch. This is the #608 shape: the
#    operator watching only `default` never sees a StreamApp in this
#    namespace, so the CRs sit there and nothing runs.
# ---------------------------------------------------------------------------
if ! kubectl -n "$NS" get deploy spark-operator-controller >/dev/null 2>&1; then
  echo "✗ spark-operator   no spark-operator-controller in $NS — the streaming pillar is half installed"
  problems=$((problems + 1))
else
  args="$(kubectl -n "$NS" get deploy spark-operator-controller -o json \
    | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0].get("args",[])))')"
  # `--namespaces=""` is what an all-namespaces install carries; strip the
  # quotes the manifest writes around the value.
  watched="$(printf '%s' "$args" | tr ' ' '\n' | sed -n 's/^--namespaces=//p' | head -n 1)"
  watched="${watched%\"}"
  watched="${watched#\"}"
  if [ -z "$watched" ]; then
    echo "✓ spark-operator   watches all namespaces"
  elif case ",$watched," in *",$NS,"*) true ;; *) false ;; esac; then
    echo "✓ spark-operator   watches $NS"
  else
    echo "✗ spark-operator   watches '$watched', not $NS — no StreamApp can run (platform#608)"
    problems=$((problems + 1))
  fi
fi

# ---------------------------------------------------------------------------
# 4. Every StreamApp's status is current: a phase other than Failed and an
#    observedGeneration that has caught up with the spec. A StreamApp the
#    controller never reconciled keeps an old generation and looks fine.
# ---------------------------------------------------------------------------
if ! apps="$(kubectl -n "$NS" get streamapps.stardelt.io -o json 2>&1)"; then
  echo "✗ streamapps   cannot list streamapps.stardelt.io in $NS: $apps"
  problems=$((problems + 1))
else
  report="$(printf '%s' "$apps" | python3 -c '
import json, sys

items = json.load(sys.stdin).get("items") or []
lines, failures = [], 0
for item in items:
    meta = item.get("metadata") or {}
    status = item.get("status") or {}
    name = meta.get("name", "?")
    phase = status.get("phase") or ""
    generation = meta.get("generation")
    observed = status.get("observedGeneration")
    if phase != "Failed" and observed is not None and observed == generation:
        lines.append("✓ %s   %s" % (name, phase))
    else:
        lines.append("✗ %s   phase %s, observedGeneration %s != generation %s"
                     % (name, phase or "(none)", observed, generation))
        failures += 1
print(json.dumps({"lines": lines, "failures": failures, "count": len(items)}))
')"
  streams="$(printf '%s' "$report" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')"
  app_failures="$(printf '%s' "$report" | python3 -c 'import json,sys; print(json.load(sys.stdin)["failures"])')"
  printf '%s' "$report" | python3 -c 'import json,sys; [print(line) for line in json.load(sys.stdin)["lines"]]'
  if [ "$streams" -eq 0 ]; then
    echo "– streamapps: none"
  fi
  problems=$((problems + app_failures))
fi

# ---------------------------------------------------------------------------
# 5. The Strimzi controller pod. A restart is a warning, not a failure: the
#    operator comes back and the broker it manages stays up (platform#665).
# ---------------------------------------------------------------------------
pods="$(kubectl -n "$NS" get pods -l name=strimzi-cluster-operator -o json 2>/dev/null || true)"
restarts="$(printf '%s' "$pods" | python3 -c '
import json, sys

try:
    items = json.load(sys.stdin).get("items") or []
except ValueError:
    items = []
if not items:
    print("")
else:
    pod = items[0]
    print(sum(c.get("restartCount", 0) for c in (pod.get("status") or {}).get("containerStatuses") or []))
' 2>/dev/null || true)"
if [ -z "$restarts" ]; then
  echo "✗ strimzi-operator   no pod"
  problems=$((problems + 1))
elif [ "$restarts" -gt 0 ]; then
  echo "! strimzi-operator   $restarts restart(s) — see stardelt-platform#665"
else
  echo "✓ strimzi-operator   no restarts"
fi

# ---------------------------------------------------------------------------
# 6. Verdict.
# ---------------------------------------------------------------------------
if [ "$problems" -gt 0 ]; then
  echo "FAIL ($problems problem(s))"
  exit 1
fi

echo "PASS (1 broker, $streams stream(s))"
