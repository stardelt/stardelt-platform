#!/usr/bin/env bash
# Prove every Catalog's maintenance CronJob is the one the operator intends (operator#477,
# #490): the staggered default schedule (never `0 2 * * *`), the container command, the
# team principal's token Secret, `MaintenanceReady=True`, and the newest run's verdict.
#
#   NS=stardelt bash scripts/verify-maintenance.sh
#
# Read-only: it creates, patches and deletes nothing. Exit 0 = PASS, 1 = FAIL,
# 3 = UNVERIFIED (could not see the subject).
#
# It does not prove the maintenance *work* — that the tables were actually compacted. The
# Job's own JSON lines and `Catalog.status.maintenance` are the operator's slice c, not
# this guard.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NS="${NS:-${NAMESPACE:-stardelt}}"
CRD="catalogs.stardelt.io"

command -v kubectl >/dev/null 2>&1 || { echo "verify-maintenance: kubectl not found" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "UNVERIFIED (python3 not found)" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "UNVERIFIED (jq not found)" >&2; exit 3; }

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "UNVERIFIED (namespace $NS does not exist)"
  exit 3
fi

problems=0

# ---------------------------------------------------------------------------
# 1. Not installed is a pass: a cluster without the operator has no Catalog,
#    so there is no maintenance job to be wrong (install-core).
# ---------------------------------------------------------------------------
if ! err="$(kubectl get crd "$CRD" 2>&1 >/dev/null)"; then
  if printf '%s' "$err" | grep -q 'NotFound'; then
    echo "– maintenance: not installed (no $CRD CRD)"
    echo "PASS (maintenance is not installed)"
    exit 0
  fi
  echo "UNVERIFIED ($err)"
  exit 3
fi

# ---------------------------------------------------------------------------
# 2. The schema the maintenance controller needs: `spec.maintenance` with the
#    policy the CLI reads and `status.conditions` for `MaintenanceReady`. A CRD
#    served with an older schema silently drops the policy a Catalog sets.
# ---------------------------------------------------------------------------
if ! missing="$(kubectl get crd "$CRD" -o json | python3 -c '
import json, sys
schema = json.load(sys.stdin)["spec"]["versions"][0]["schema"]["openAPIV3Schema"]
props = (schema.get("properties") or {})
spec = (props.get("spec") or {}).get("properties") or {}
maint = (spec.get("maintenance") or {}).get("properties") or {}
missing = [f for f in ("schedule", "optimize", "expireSnapshots", "removeOrphanFiles") if f not in maint]
for parent, child in (("optimize", "minSmallFiles"), ("expireSnapshots", "retention"), ("removeOrphanFiles", "retention")):
    nested = (maint.get(parent) or {}).get("properties") or {}
    if parent in maint and child not in nested:
        missing.append(parent + "." + child)
status = (props.get("status") or {}).get("properties") or {}
if "conditions" not in status:
    missing.append("status.conditions")
print(" ".join(missing))
' 2>&1)"; then
  echo "✗ crd       cannot read the served schema of $CRD: $missing"
  echo "            hint: make install-operator"
  problems=$((problems + 1))
elif [ -n "$missing" ]; then
  echo "✗ crd       $CRD lacks$missing — Catalog.spec.maintenance cannot be written or read"
  echo "            hint: make install-operator"
  problems=$((problems + 1))
else
  echo "✓ crd       $CRD carries spec.maintenance and status.conditions"
fi

# ---------------------------------------------------------------------------
# 3. The Trino catalogs the platform rendered. A `Catalog` created after the
#    last `make catalogs` has a warehouse and a maintenance CronJob but no
#    `<name>.properties` in ConfigMap `trino-catalog`, so its maintenance run
#    fails with CATALOG_NOT_FOUND (platform#914). Read-only; the ConfigMap name
#    is overridable so the failure path can be proven without a broken cluster.
# ---------------------------------------------------------------------------
TRINO_CONFIGMAP="${TRINO_CONFIGMAP:-trino-catalog}"
trino_cm=""
if out="$(kubectl -n "$NS" get configmap "$TRINO_CONFIGMAP" -o json 2>&1)"; then
  trino_cm="$out"
fi

# ---------------------------------------------------------------------------
# 4-7. One read of everything the checks need: the Catalogs, their CronJobs, the
#    ServicePrincipals that run them and the Jobs those CronJobs produced.
# ---------------------------------------------------------------------------
if ! json="$(kubectl -n "$NS" get catalogs,cronjobs,serviceprincipals,jobs -o json 2>&1)"; then
  echo "UNVERIFIED (cannot list catalogs, cronjobs, serviceprincipals and jobs in $NS: $json)"
  exit 3
fi

if ! report="$(printf '%s' "$json" | python3 -c '
import json, sys

trino_raw = sys.argv[2] if len(sys.argv) > 2 else ""
trino_cm_name = sys.argv[3] if len(sys.argv) > 3 else "trino-catalog"
doc = json.load(sys.stdin)
catalogs, cronjobs, principals, jobs = {}, {}, {}, []
for item in (doc.get("items") or []):
    kind = item.get("kind") or ""
    name = (item.get("metadata") or {}).get("name") or ""
    if kind == "Catalog":
        catalogs[name] = item
    elif kind == "CronJob":
        if name.startswith("maint-"):
            cronjobs[name] = item
    elif kind == "ServicePrincipal":
        principals[name] = item
    elif kind == "Job":
        jobs.append(item)

DEFAULT = "0 2 * * *"
ok, problems, minutes, catalog_lines, warn_lines, principal_lines, job_lines = 0, 0, [], [], [], [], []


def stagger(name):
    # FNV-1a, the operator s stagger_minute: offset basis, prime, 1 + hash % 49.
    h = 0xcbf29ce484222325
    for byte in name.encode():
        h ^= byte
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return 1 + (h % 49)


def cond(obj, ctype):
    for c in ((obj.get("status") or {}).get("conditions") or []):
        if c.get("type") == ctype:
            return c
    return None


def pod_container(cronjob):
    spec = (cronjob.get("spec") or {}).get("jobTemplate") or {}
    spec = spec.get("spec") or {}
    pod = (spec.get("template") or {}).get("spec") or {}
    containers = pod.get("containers") or []
    return containers[0] if containers else {}


def env_of(container, name):
    for var in (container.get("env") or []):
        if var.get("name") == name:
            return var
    return None


def newest_job(catalog):
    best = None
    for job in jobs:
        meta = job.get("metadata") or {}
        name = meta.get("name") or ""
        label = ((meta.get("labels") or {}).get("stardelt.io/catalog")) or ""
        if not (name.startswith("maint-%s-" % catalog) or label == catalog):
            continue
        created = meta.get("creationTimestamp") or ""
        if best is None or created > (best.get("metadata") or {}).get("creationTimestamp") or "":
            best = job
    return best


ready_principals = []
for name in sorted(catalogs):
    item = catalogs[name]
    spec = item.get("spec") or {}
    owner = spec.get("owner") or ""
    maint = spec.get("maintenance") or {}
    configured = maint.get("schedule") or DEFAULT
    expected = ("%d 2 * * *" % stagger(name)) if configured == DEFAULT else configured
    principal_name = "pipeline-" + owner
    principal = principals.get(principal_name)
    state = cond(item, "MaintenanceReady")

    if not owner:
        catalog_lines.append("✗ catalog   %s: spec.owner is empty — no principal can run it" % name)
        problems += 1
        continue

    if principal is None:
        message = (state or {}).get("message") or "no MaintenanceReady condition"
        catalog_lines.append("! %s not scheduled — %s" % (name, message))
        continue

    if (principal.get("status") or {}).get("ready") is not True:
        message = (cond(principal, "Ready") or {}).get("message") or "no Ready condition"
        catalog_lines.append("✗ catalog   %s wants %s, which is not Ready — %s" % (name, principal_name, message))
        problems += 1
        continue

    if principal_name not in ready_principals:
        ready_principals.append(principal_name)

    job_name = "maint-" + name
    cronjob = cronjobs.get(job_name)
    if cronjob is None:
        catalog_lines.append("✗ catalog   %s: no CronJob %s — the operator has not reconciled it" % (name, job_name))
        problems += 1
        continue

    cj = cronjob.get("spec") or {}
    schedule = cj.get("schedule") or ""
    container = pod_container(cronjob)
    faults = []

    if cj.get("suspend") is True:
        faults.append("spec.suspend is true — the maintenance job is turned off")
    if configured == DEFAULT and schedule == DEFAULT:
        faults.append("still runs at 0 2 * * * — the default schedule was not staggered")
    elif schedule != expected:
        faults.append("schedule %s, expected %s — hint: make install-operator" % (schedule or "(none)", expected))
    elif configured == DEFAULT:
        minute = int(schedule.split()[0])
        minutes.append(minute)
    if cj.get("concurrencyPolicy") != "Forbid":
        faults.append("concurrencyPolicy is %s, not Forbid" % (cj.get("concurrencyPolicy") or "(none)"))
    job_spec = (cj.get("jobTemplate") or {}).get("spec") or {}
    if job_spec.get("activeDeadlineSeconds") != 3600:
        faults.append("activeDeadlineSeconds is %s, not 3600" % job_spec.get("activeDeadlineSeconds"))
    if cj.get("successfulJobsHistoryLimit") != 1:
        faults.append("successfulJobsHistoryLimit is %s, not 1" % cj.get("successfulJobsHistoryLimit"))
    wanted = ["stardelt", "maintenance", "run", "--catalog", name]
    if (container.get("command") or []) != wanted:
        faults.append("container command is %s, not %s" % (json.dumps(container.get("command") or []), " ".join(wanted)))
    client_id = env_of(container, "PIPELINE_CLIENT_ID") or {}
    if client_id.get("value") != "sp-" + principal_name:
        faults.append("PIPELINE_CLIENT_ID is %s, not sp-%s" % (client_id.get("value") or "(none)", principal_name))
    secret = env_of(container, "PIPELINE_CLIENT_SECRET") or {}
    ref = ((secret.get("valueFrom") or {}).get("secretKeyRef")) or {}
    if ref.get("name") != "sp-" + principal_name or ref.get("key") != "client-secret":
        faults.append("PIPELINE_CLIENT_SECRET is not secretKeyRef sp-%s/client-secret" % principal_name)
    if state is None:
        faults.append("no MaintenanceReady condition")
    elif state.get("status") != "True":
        faults.append("MaintenanceReady is %s (%s), not True" % (state.get("status"), state.get("reason") or "no reason"))
    elif (state.get("message") or "") != "%s on %s" % (job_name, schedule):
        faults.append("MaintenanceReady message is %s, not %s on %s" % (json.dumps(state.get("message") or ""), job_name, schedule))

    if faults:
        for fault in faults:
            catalog_lines.append("✗ catalog   %s: %s" % (name, fault))
            problems += 1
    else:
        ok += 1
        catalog_lines.append("✓ catalog   %s: %s on %s" % (name, job_name, schedule))

    job = newest_job(name)
    if job is None:
        job_lines.append("– %s not run yet" % name)
        continue
    job_state = ""
    for ctype in ("Complete", "Failed"):
        condition = cond(job, ctype)
        if condition is not None and condition.get("status") == "True":
            job_state = ctype
            break
    if not job_state:
        job_state = "Running" if (job.get("status") or {}).get("active") else "Pending"
    current = (job.get("metadata") or {}).get("name") or job_name
    if job_state == "Failed":
        job_lines.append("✗ job       %s: newest Job %s Failed — hint: kubectl -n %s logs job/%s" % (job_name, current, sys.argv[1], current))
        problems += 1
    else:
        job_lines.append("✓ job       %s: newest Job %s" % (job_name, job_state))

if ready_principals:
    for principal_name in ready_principals:
        owner = principal_name[len("pipeline-"):]
        principal_lines.append("✓ principal %s: %s Ready, Secret sp-%s" % (owner, principal_name, principal_name))

by_minute = {}
for name in sorted(catalogs):
    maint = (catalogs[name].get("spec") or {}).get("maintenance") or {}
    if (maint.get("schedule") or DEFAULT) != DEFAULT:
        continue
    cronjob = cronjobs.get("maint-" + name)
    if cronjob is None:
        continue
    schedule = (cronjob.get("spec") or {}).get("schedule") or ""
    parts = schedule.split()
    if len(parts) == 5 and parts[0].isdigit() and parts[1:] == ["2", "*", "*", "*"]:
        by_minute.setdefault(int(parts[0]), []).append(name)
for minute in sorted(by_minute):
    names = by_minute[minute]
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            warn_lines.append("! %s and %s share minute %d — allowed (the stagger hashes into 49 minutes)" % (names[i], names[j], minute))

trino_lines = []
if trino_raw:
    data = (json.loads(trino_raw).get("data") or {})
    have = {key[:-len(".properties")] for key in data if key.endswith(".properties")}
    ready = sorted(n for n in catalogs if ((catalogs[n].get("status") or {}).get("phase") or "") == "Ready")
    missing = [n for n in ready if n not in have]
    if missing:
        for name in missing:
            trino_lines.append("✗ trino     %s is Ready but ConfigMap %s has no %s.properties — hint: make catalogs" % (name, trino_cm_name, name))
            problems += 1
    else:
        trino_lines.append("✓ trino     every Ready Catalog has a Trino catalog (%d checked)" % len(ready))
else:
    trino_lines.append("– trino     no ConfigMap %s (Trino is not installed in this namespace)" % trino_cm_name)

for line in trino_lines + catalog_lines + warn_lines + principal_lines + job_lines:
    print(line)
print("__meta__ %d|%d|%d|%s" % (problems, ok, len(catalogs), ",".join(str(m) for m in sorted(minutes))))
' "$NS" "$trino_cm" "$TRINO_CONFIGMAP")"; then
  echo "✗ maintenance cannot evaluate the cluster state:"
  printf '%s\n' "$report" | sed 's/^/            /'
  exit 1
fi

meta="$(printf '%s\n' "$report" | grep '^__meta__ ' || true)"
printf '%s\n' "$report" | grep -v '^__meta__ ' || true
IFS='|' read -r script_problems scheduled total minute_list <<< "${meta#__meta__ }"
problems=$((problems + script_problems))

# ---------------------------------------------------------------------------
# 7. Verdict.
# ---------------------------------------------------------------------------
if [ "$problems" -gt 0 ]; then
  echo "FAIL ($problems problem(s))"
  exit 1
fi

echo "PASS (maintenance is wired, $scheduled of $total catalog(s) scheduled, minutes $minute_list)"
