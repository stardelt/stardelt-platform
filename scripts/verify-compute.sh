#!/usr/bin/env bash
# Prove the Compute tier is wired: the SparkCluster CRD carries the schema the Compute page
# writes, the live runtime catalogue is the repository's, Nova's ServiceAccount may list and
# patch SparkClusters, and every SparkCluster has been reconciled by the operator.
#
#   NS=stardelt bash scripts/verify-compute.sh
#
# Read-only. Exit 0 = PASS, 1 = FAIL, 3 = UNVERIFIED (could not see the subject).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NS="${NS:-${NAMESPACE:-stardelt}}"
CRD="sparkclusters.stardelt.io"
CATALOGUE="stardelt-spark-runtimes"
GRACE=120

command -v kubectl >/dev/null 2>&1 || { echo "verify-compute: kubectl not found" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "UNVERIFIED (python3 not found)" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "UNVERIFIED (jq not found)" >&2; exit 3; }

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "UNVERIFIED (namespace $NS does not exist)"
  exit 3
fi

problems=0
clusters=0

# ---------------------------------------------------------------------------
# 1. Not installed is a pass: a cluster without the Compute tier has nothing
#    to be broken (install-core, the identity-only install).
# ---------------------------------------------------------------------------
if ! err="$(kubectl get crd "$CRD" 2>&1 >/dev/null)"; then
  if printf '%s' "$err" | grep -q 'NotFound'; then
    echo "– compute: not installed (no $CRD CRD)"
    echo "PASS (compute is not installed)"
    exit 0
  fi
  echo "UNVERIFIED ($err)"
  exit 3
fi

# ---------------------------------------------------------------------------
# 2. The schema the Compute page writes. Nova sends owner, size, runtime,
#    state and idleStopMinutes and reads status.phase; a CRD served with an
#    older schema rejects the create with a 422 and the page looks broken
#    (the #539/#819 family).
# ---------------------------------------------------------------------------
if ! schema="$(kubectl get crd "$CRD" -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)["spec"]["versions"][0]["schema"]["openAPIV3Schema"]
props = s.get("properties") or {}
spec = sorted(((props.get("spec") or {}).get("properties") or {}))
status = sorted(((props.get("status") or {}).get("properties") or {}))
print(" ".join(spec) + " | " + " ".join(status))
' 2>&1)"; then
  echo "✗ crd       cannot read the served schema of $CRD: $schema"
  echo "            hint: make install-operator"
  problems=$((problems + 1))
else
  spec_fields="${schema%% | *}"
  status_fields="${schema##* | }"
  missing=""
  for field in owner size runtime state idleStopMinutes; do
    case " $spec_fields " in
      *" $field "*) ;;
      *) missing="$missing spec.$field" ;;
    esac
  done
  case " $status_fields " in
    *" phase "*) ;;
    *) missing="$missing status.phase" ;;
  esac
  if [ -z "$missing" ]; then
    echo "✓ crd       $CRD carries owner, size, runtime, state, idleStopMinutes"
  else
    echo "✗ crd       $CRD lacks$missing — the Compute page cannot write or read it"
    echo "            hint: make install-operator"
    problems=$((problems + 1))
  fi
fi

# ---------------------------------------------------------------------------
# 3. The runtime catalogue: the repository's chart/files/spark-runtimes.json is
#    the one catalogue, and the cluster must carry the same ConfigMap, or a
#    SparkCluster cannot start (platform#819). Every entry must parse as JSON
#    and name an image, a Spark version and a service account.
# ---------------------------------------------------------------------------
if ! cm_json="$(kubectl -n "$NS" get configmap "$CATALOGUE" -o json 2>&1)"; then
  echo "✗ catalogue no ConfigMap $CATALOGUE in $NS — no SparkCluster can start"
  echo "            hint: make install-spark (on an operator install: make install-operator)"
  problems=$((problems + 1))
else
  catalogue_ok=1
  if ! diff <(printf '%s' "$cm_json" | jq -S '.data') \
       <(jq -S 'with_entries(.value |= tojson)' chart/files/spark-runtimes.json) >/dev/null 2>&1; then
    echo "✗ catalogue $CATALOGUE differs from chart/files/spark-runtimes.json"
    diff <(printf '%s' "$cm_json" | jq -S '.data' | jq -r 'keys[]' 2>/dev/null) \
         <(jq -S 'with_entries(.value |= tojson)' chart/files/spark-runtimes.json | jq -r 'keys[]' 2>/dev/null) \
      | sed 's/^</             only on the cluster:/; s/^>/             only in the repository:/' || true
    echo "            hint: make install-spark (on an operator install: make install-operator)"
    problems=$((problems + 1))
    catalogue_ok=0
  fi
  entry_report="$(printf '%s' "$cm_json" | python3 -c '
import json, sys
data = (json.load(sys.stdin).get("data") or {})
names, bad = [], []
for name in sorted(data):
    names.append(name)
    try:
        entry = json.loads(data[name])
    except ValueError:
        bad.append("%s is not JSON" % name)
        continue
    if not isinstance(entry, dict):
        bad.append("%s is not an object" % name)
        continue
    for field in ("image", "sparkVersion", "serviceAccount"):
        if not entry.get(field):
            bad.append("%s has no %s" % (name, field))
if not names:
    bad.append("the catalogue is empty")
print(json.dumps({"names": names, "bad": bad}))
')"
  bad="$(printf '%s' "$entry_report" | python3 -c 'import json,sys; print("; ".join(json.load(sys.stdin)["bad"]))')"
  names="$(printf '%s' "$entry_report" | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin)["names"]))')"
  n="$(printf '%s' "$entry_report" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["names"]))')"
  if [ -n "$bad" ]; then
    echo "✗ catalogue $CATALOGUE entries are incomplete: $bad"
    echo "            hint: make install-spark (on an operator install: make install-operator)"
    problems=$((problems + 1))
  elif [ "$catalogue_ok" -eq 1 ]; then
    if [ "$n" -eq 1 ]; then
      echo "✓ catalogue $CATALOGUE matches chart/files/spark-runtimes.json (1 runtime: $names)"
    else
      echo "✓ catalogue $CATALOGUE matches chart/files/spark-runtimes.json ($n runtimes: $names)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Nova may reach them. The Compute page lists and Start/Stop patches
#    SparkCluster (platform#823); without the rule the route answers 502.
#    There is no Role named `nova`: the ServiceAccount gets its rules through
#    bindings (nova-workload-reader, nova-pipelines), so find the Role through
#    the bindings and accept whichever grants the resource.
# ---------------------------------------------------------------------------
granted=""
while read -r kind name; do
  [ "$kind" = "Role" ] || continue
  found="$(kubectl -n "$NS" get role "$name" -o json \
    | jq -r '.rules[] | select(.resources | index("sparkclusters")) | .verbs | join(",")' | head -n 1)"
  if [ -n "$found" ]; then
    granted="$granted$name: $found"$'\n'
  fi
done < <(kubectl -n "$NS" get rolebinding -o json \
  | jq -r '.items[] | select(any(.subjects[]?; .kind == "ServiceAccount" and .name == "nova")) | "\(.roleRef.kind) \(.roleRef.name)"' \
  | sort -u)

if [ -z "$granted" ]; then
  echo "✗ rbac      no Role bound to ServiceAccount nova grants sparkclusters — the Compute page answers 502"
  echo "            hint: make install-operator / make step-nova"
  problems=$((problems + 1))
else
  chosen=""
  lacking=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    role="${line%%:*}"
    verbs="${line#*: }"
    miss=""
    for verb in get list patch create delete; do
      case ",$verbs," in
        *",$verb,"*) ;;
        *) miss="$miss $verb" ;;
      esac
    done
    if [ -z "$miss" ]; then
      chosen="$role"
      break
    fi
    if [ -z "$lacking" ]; then
      lacking="$role may$miss"
    fi
  done <<< "$granted"
  if [ -n "$chosen" ]; then
    echo "✓ rbac      $chosen may get, list, patch, create, delete sparkclusters"
  else
    echo "✗ rbac      $lacking sparkclusters — the Compute page answers 502"
    echo "            hint: make install-operator / make step-nova"
    problems=$((problems + 1))
  fi
fi

# ---------------------------------------------------------------------------
# 5. Every SparkCluster reconciles. A stale phase means the controller never
#    saw the object; Running must have its SparkConnect `spc-<name>` and
#    Stopped must not (Start/Stop is delete-and-recreate, operator#460). The
#    120 s grace keeps a create in flight from failing the check.
# ---------------------------------------------------------------------------
operator_present=1
if ! kubectl -n "$NS" get deploy stardelt-operator >/dev/null 2>&1; then
  echo "✗ operator  no stardelt-operator in $NS — nothing reconciles SparkCluster"
  echo "            hint: make install-operator"
  problems=$((problems + 1))
  operator_present=0
fi

if ! clusters_json="$(kubectl -n "$NS" get "$CRD" -o json 2>&1)"; then
  echo "✗ clusters  cannot list $CRD in $NS: $clusters_json"
  problems=$((problems + 1))
else
  clusters="$(printf '%s' "$clusters_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items") or []))')"
  if [ "$clusters" -eq 0 ]; then
    echo "– clusters  0 SparkCluster(s)"
  fi
  rows="$(printf '%s' "$clusters_json" | python3 -c '
import json, sys
from datetime import datetime, timezone

now = datetime.now(timezone.utc)
for item in (json.load(sys.stdin).get("items") or []):
    meta = item.get("metadata") or {}
    spec = item.get("spec") or {}
    status = item.get("status") or {}
    age = ""
    created = meta.get("creationTimestamp")
    if created:
        try:
            age = int((now - datetime.fromisoformat(created.replace("Z", "+00:00"))).total_seconds())
        except ValueError:
            age = ""
    # Unit separator: a tab is IFS whitespace, so read would collapse the
    # empty phase of an unreconciled object and shift every later field.
    print("\x1f".join([
        meta.get("name") or "?",
        str(spec.get("size") if spec.get("size") is not None else ""),
        spec.get("state") or "",
        status.get("phase") or "",
        str(age),
    ]))
')"
  while IFS=$'\x1f' read -r name size state phase age; do
    [ -n "$name" ] || continue
    echo "$name  $size  $state  phase=${phase:-none}"
    [ "$operator_present" -eq 1 ] || continue
    old=0
    if [ -n "$age" ] && [ "$age" -ge "$GRACE" ]; then
      old=1
    fi
    if [ -z "$phase" ] && [ "$old" -eq 1 ]; then
      echo "✗ $name   the controller has not reconciled it (no status.phase after ${age}s)"
      problems=$((problems + 1))
      continue
    fi
    if [ "$state" = "Running" ]; then
      if ! kubectl -n "$NS" get sparkconnects.sparkoperator.k8s.io "spc-$name" >/dev/null 2>&1 && [ "$old" -eq 1 ]; then
        echo "✗ $name   Running but SparkConnect spc-$name does not exist after ${age}s"
        problems=$((problems + 1))
      fi
    elif [ "$state" = "Stopped" ]; then
      if kubectl -n "$NS" get sparkconnects.sparkoperator.k8s.io "spc-$name" >/dev/null 2>&1 && [ "$old" -eq 1 ]; then
        echo "✗ $name   Stopped but SparkConnect spc-$name still exists after ${age}s"
        problems=$((problems + 1))
      fi
    fi
  done <<< "$rows"
fi

# ---------------------------------------------------------------------------
# 6. Verdict.
# ---------------------------------------------------------------------------
if [ "$problems" -gt 0 ]; then
  echo "FAIL ($problems problem(s))"
  exit 1
fi

echo "PASS (compute is wired, $clusters SparkCluster(s))"
