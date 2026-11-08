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
# 4. Every StreamApp's status is current and running: a stream that is not
#    running is never a checkmark: `Pending` is a warning, `Failed` or a stale
#    generation is a failure. A StreamApp the controller never reconciled keeps
#    an old generation and looks fine.
#
#    The phase alone is not health: a driver that fails is resubmitted from the
#    checkpoint and the phase is `Running` again between failures, so a single
#    look is green most of the time (platform#671). SparkApplication
#    status.executionAttempts counts the resubmissions; a running stream with
#    more than one is a warning, not a failure (a one-off restart is not broken).
#
#    The warning is limited to the operator's ten-minute restart window
#    (RESTART_WINDOW_SECS, override with RESTART_WINDOW_SECS): a stream whose
#    last submission is older than the window keeps a checkmark, because its
#    attempts are historical, not an active restart (platform#677).
# ---------------------------------------------------------------------------
spark_apps=""
if spark_json="$(kubectl -n "$NS" get sparkapplications.sparkoperator.k8s.io -o json 2>&1)"; then
  spark_apps="$spark_json"
elif printf '%s' "$spark_json" | grep -Eq 'NotFound|have a resource type'; then
  echo "– sparkapplications: not installed (no SparkApplication CRD in $NS)"
else
  echo "! sparkapplications   cannot list: $spark_json (execution attempts not checked)"
fi

if ! apps="$(kubectl -n "$NS" get streamapps.stardelt.io -o json 2>&1)"; then
  echo "✗ streamapps   cannot list streamapps.stardelt.io in $NS: $apps"
  problems=$((problems + 1))
else
restart_window="${RESTART_WINDOW_SECS:-600}"
  report="$(printf '%s' "$apps" | python3 -c '
import json, sys
from datetime import datetime, timezone

items = json.load(sys.stdin).get("items") or []
attempts = {}
window = int(sys.argv[2]) if len(sys.argv) > 2 else 600
spark_raw = sys.argv[1] if len(sys.argv) > 1 else ""
if spark_raw.strip():
    try:
        for app in (json.loads(spark_raw).get("items") or []):
            name = (app.get("metadata") or {}).get("name")
            if name:
                attempts[name] = (app.get("status") or {}).get("executionAttempts") or 0
    except ValueError:
        attempts = {}
lines, failures = [], 0
for item in items:
    meta = item.get("metadata") or {}
    status = item.get("status") or {}
    name = meta.get("name", "?")
    phase = status.get("phase") or ""
    generation = meta.get("generation")
    observed = status.get("observedGeneration")
    if observed != generation:
        lines.append("✗ %s   phase %s, observedGeneration %s != generation %s"
                     % (name, phase or "(none)", observed, generation))
        failures += 1
    elif phase == "Running":
        submitted = status.get("lastSubmittedAt")
        recent = False
        if submitted:
            try:
                then = datetime.fromisoformat(submitted.replace("Z", "+00:00"))
                recent = (datetime.now(timezone.utc) - then).total_seconds() < window
            except ValueError:
                recent = False
        if attempts.get(name, 0) > 1 and recent:
            lines.append("! %s   %d execution attempts, last submitted %s — inside the %d-minute restart window"
                         % (name, attempts[name], submitted, window // 60))
        elif attempts.get(name, 0) > 1:
            lines.append("✓ %s   Running, %d execution attempts, last submitted %s"
                         % (name, attempts[name], submitted or "never"))
        else:
            lines.append("✓ %s   Running" % (name,))
    elif phase == "Pending":
        lines.append("! %s   Pending, lastSubmittedAt %s (not running now)"
                     % (name, status.get("lastSubmittedAt") or "never"))
    elif phase == "Stopped":
        lines.append("✓ %s   Stopped" % (name,))
    else:
        lines.append("✗ %s   phase %s" % (name, phase or "(none)"))
        failures += 1
print(json.dumps({"lines": lines, "failures": failures, "count": len(items)}))
' "$spark_apps" "$restart_window")"
  streams="$(printf '%s' "$report" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')"
  app_failures="$(printf '%s' "$report" | python3 -c 'import json,sys; print(json.load(sys.stdin)["failures"])')"
  printf '%s' "$report" | python3 -c 'import json,sys; [print(line) for line in json.load(sys.stdin)["lines"]]'
  if [ "$streams" -eq 0 ]; then
    echo "– streamapps: none"
  fi
  problems=$((problems + app_failures))
fi

# ---------------------------------------------------------------------------
# 5. The Strimzi controller pod. The warning is limited to the operator's
#    ten-minute restart window (RESTART_WINDOW_SECS, override for a test), so a
#    controller that came back long ago is not an active alarm; the root cause
#    stays platform#665.
# ---------------------------------------------------------------------------
pods="$(kubectl -n "$NS" get pods -l name=strimzi-cluster-operator -o json 2>/dev/null || true)"
restart_window="${RESTART_WINDOW_SECS:-600}"
restart_report="$(printf '%s' "$pods" | python3 -c '
import json, sys
from datetime import datetime, timezone

window = int(sys.argv[1]) if len(sys.argv) > 1 else 600
try:
    items = json.load(sys.stdin).get("items") or []
except ValueError:
    items = []
if not items:
    print("")
    sys.exit(0)

restarts, newest = 0, None
for pod in items:
    for c in (pod.get("status") or {}).get("containerStatuses") or []:
        restarts += c.get("restartCount", 0) or 0
        finished = ((c.get("lastState") or {}).get("terminated") or {}).get("finishedAt")
        if finished:
            try:
                t = datetime.fromisoformat(finished.replace("Z", "+00:00"))
            except ValueError:
                continue
            if newest is None or t > newest:
                newest = t

inside, age_min = False, None
if newest is not None:
    age_min = int((datetime.now(timezone.utc) - newest).total_seconds() // 60)
    inside = age_min * 60 < window
print(json.dumps({"restarts": restarts, "age_minutes": age_min, "inside": inside}))
' "$restart_window" 2>/dev/null || true)"
if [ -z "$restart_report" ]; then
  echo "✗ strimzi-operator   no pod"
  problems=$((problems + 1))
else
  restarts="$(printf '%s' "$restart_report" | python3 -c 'import json,sys; print(json.load(sys.stdin)["restarts"])')"
  inside="$(printf '%s' "$restart_report" | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["inside"] else "no")')"
  age="$(printf '%s' "$restart_report" | python3 -c 'import json,sys; a=json.load(sys.stdin)["age_minutes"]; print("unknown" if a is None else ("%dm" % a if a < 120 else "%dh" % (a // 60)))')"
  if [ "$restarts" -eq 0 ]; then
    echo "✓ strimzi-operator   no restarts"
  elif [ "$inside" = "yes" ]; then
    echo "! strimzi-operator   $restarts restart(s), last $age ago — inside the $((restart_window / 60))-minute window; see stardelt-platform#665"
  else
    echo "✓ strimzi-operator   $restarts restart(s), last $age ago (outside the window)"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Verdict.
# ---------------------------------------------------------------------------
if [ "$problems" -gt 0 ]; then
  echo "FAIL ($problems problem(s))"
  exit 1
fi

echo "PASS (1 broker, $streams stream(s))"
