#!/usr/bin/env bash
# Pin a deployment to the newest published digest of an image tag.
#
#   ./scripts/pin-image.sh nova              # ghcr.io/stardelt/nova:dev → namespace stardelt
#   ./scripts/pin-image.sh stardelt-operator stardelt main
#   APP=trino NS=lab TAG=v480 ./scripts/pin-image.sh
#   ./scripts/pin-image.sh airflow           # the loader (`:demo`, airflow-api-server, three files)
#   WRITE_MANIFEST_ONLY=1 ./scripts/pin-image.sh jupyter   # the notebook image, three files, no cluster
#   ./scripts/pin-image.sh superset          # the BI image, two files (values + group-roles CronJob)
#
# Why this exists: a moving tag is not an upgrade path. CI publishes `dev` on
# every merge to main, but a node that already has layers for that tag can keep
# serving the older image after a pod restart, so "the tag moved" and "the
# cluster changed" are different events. Deployments pin digests; this resolves
# the tag to its current digest in the registry and applies that.
#
# Works for public packages anonymously, and for private ones with `gh` logged
# in (the token is passed to the registry, never printed).
set -euo pipefail

# The deployment an app runs in, when it is not named after the app: Spark runs in
# `spark-connect`. `DEPLOY=` still overrides it.
deployment_for() {
  case "$1" in
    spark)   echo "spark-connect" ;;
    airflow) echo "airflow-api-server" ;;
    jupyter) echo "" ;;
    *)       echo "$1" ;;
  esac
}

# The tag an app publishes, when it is not `dev`: the Airflow loader is built by
# stardelt-demos and published as `demo`. `TAG=` still overrides it.
default_tag() {
  case "$1" in
    airflow) echo "demo" ;;
    *)       echo "dev" ;;
  esac
}

# The image an app publishes, when it is not the app name: the notebook image is
# `jupyter-singleuser`.
image_name() {
  case "$1" in
    jupyter) echo "jupyter-singleuser" ;;
    *)       echo "$1" ;;
  esac
}

APP="${1:-${APP:-nova}}"
NS="${2:-${NS:-stardelt}}"
TAG="${3:-${TAG:-$(default_tag "$APP")}}"
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-stardelt}"
REPO="$OWNER/$(image_name "$APP")"
DEPLOY="${DEPLOY:-$(deployment_for "$APP")}"
CONTAINER="${CONTAINER:-}"

for tool in curl kubectl; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

# Anonymous pull token first; GHCR issues one for public packages without auth.
token=$(curl -fsS "https://$REGISTRY/token?scope=repository:$REPO:pull&service=$REGISTRY" 2>/dev/null \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || token=""

accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

resolve() {
  curl -fsSI -H "Authorization: Bearer $1" -H "Accept: $accept" \
    "https://$REGISTRY/v2/$REPO/manifests/$TAG" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}

digest=$(resolve "$token" || true)

if [ -z "$digest" ] && command -v gh >/dev/null; then
  # Private package: the gh token carries read:packages for GHCR.
  gh_user=$(gh api user --jq .login 2>/dev/null || true)
  gh_token=$(gh auth token 2>/dev/null || true)
  if [ -n "$gh_user" ] && [ -n "$gh_token" ]; then
    basic=$(printf '%s:%s' "$gh_user" "$gh_token" | base64 | tr -d '\n')
    private_token=$(curl -fsS -H "Authorization: Basic $basic" \
      "https://$REGISTRY/token?scope=repository:$REPO:pull&service=$REGISTRY" 2>/dev/null \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || private_token=""
    [ -n "$private_token" ] && digest=$(resolve "$private_token" || true)
  fi
fi

if [ -z "$digest" ]; then
  # Never substitute a constant here: the pin would silently stop moving (platform#530 added one
  # for the operator that was already a build behind). A tag that cannot be resolved is an error.
  echo "$REGISTRY/$REPO:$TAG not resolvable (private package needs read:packages?)" >&2
  exit 1
fi

# `PRINT_DIGEST=1` answers "what would you pin?" and touches nothing — `make dev-watch`
# and the CI checks read it. It exits before the first kubectl call, so it works without
# a cluster.
if [ "${PRINT_DIGEST:-0}" = "1" ]; then
  printf '%s\n' "$digest"
  exit 0
fi

# `WRITE_MANIFEST_ONLY=1` rewrites the pinned files and exits without a cluster: the daily
# pin rollup (scripts/pin-rollup.sh) runs on a GitHub runner with no kubeconfig and needs
# the airflow writer below, which needs only the digest (platform#739).
CRDS_DIR=""
if [ "${WRITE_MANIFEST_ONLY:-0}" = "1" ]; then
  echo "› $NS/$DEPLOY: manifest only (no cluster)"
fi

if [ "${WRITE_MANIFEST_ONLY:-0}" != "1" ] && [ -n "$DEPLOY" ]; then

if [ -z "$CONTAINER" ]; then
  CONTAINER=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].name}')
fi

current=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}")
# The reference keeps the tag for readability and adds the digest the kubelet resolves
# (`repo:dev@sha256:…`), the same form the manifests carry: the two must agree, or
# every `kubectl apply` flips the pod spec and rolls the pods for nothing.
pinned="$REGISTRY/$REPO:$TAG@$digest"
echo "› $NS/$DEPLOY $CONTAINER"
echo "    now:  $current"
echo "    new:  $pinned"

# Which CRD schema moves with the image: the one the image was built from, not whatever the
# operator checkout happens to have. The digest comes from the registry (the build of the
# merge on `origin/main`), so the schema must come from the same commit; a checkout that is
# behind applies an old schema and the dry run passes against the old files (platform#588:
# the image moved to a build whose `spec.stopped` the cluster's CRD did not have).
# ALLOW_STALE_CRDS=1 is the only way to accept the working tree while it is behind, and it
# names both revisions.
CRDS_DIR=""
CRDS_TMP=""
if [ "$APP" = "stardelt-operator" ] && [ "${APPLY_CRDS:-1}" = "1" ]; then
  op_dir="${OPERATOR_DIR:-../stardelt-operator}"
  crds="$op_dir/chart/crds"
  if [ -d "$crds" ] && git -C "$op_dir" rev-parse --git-dir >/dev/null 2>&1; then
    head_rev=$(git -C "$op_dir" rev-parse HEAD)
    main_ref=""
    for ref in origin/main origin/master; do
      if git -C "$op_dir" rev-parse --verify --quiet "$ref" >/dev/null; then
        main_ref="$ref"
        break
      fi
    done
    if [ -n "$main_ref" ]; then
      main_rev=$(git -C "$op_dir" rev-parse "$main_ref")
      if [ "$head_rev" != "$main_rev" ]; then
        if [ "${ALLOW_STALE_CRDS:-0}" = "1" ]; then
          echo "  › WARNING: $op_dir is at ${head_rev:0:7}, $main_ref is ${main_rev:0:7} — applying the working tree's CRDs (ALLOW_STALE_CRDS=1)" >&2
        else
          CRDS_TMP=$(mktemp -d)
          trap 'rm -rf "$CRDS_TMP"' EXIT
          git -C "$op_dir" archive "$main_ref" chart/crds | tar -x -C "$CRDS_TMP"
          crds="$CRDS_TMP/chart/crds"
          echo "  › CRDs from $main_ref ${main_rev:0:7} (the checkout is at ${head_rev:0:7})"
        fi
      fi
    fi
  fi
  CRDS_DIR="$crds"
fi

# Validate the operator's CRDs before the image moves. `set -euo pipefail` turns a
# refused dry run into an immediate exit, so a CRD the API server rejects (platform#555:
# "estimated rule cost exceeds budget") cannot leave the cluster on a new binary with
# the old schema.
if [ -n "$CRDS_DIR" ]; then
  if [ -d "$CRDS_DIR" ]; then
    kubectl apply --server-side --force-conflicts --dry-run=server -f "$CRDS_DIR" >/dev/null
    echo "  › CRDs pass a server-side dry run"
  fi
fi

# The deployment and the manifest are updated independently: skipping the first because the
# cluster already matches must not skip the second, or the manifest keeps the old digest and
# the next `kubectl apply` puts it back. (That hole shipped once — the early exit said
# "already pinned" and left the file alone.)
# Compare the digests, not the strings: a reference without the tag names the same
# image, so it is already pinned and the pods are left alone.
current_digest=$(printf '%s' "$current" | sed -n 's/.*@\(sha256:[0-9a-f]*\)$/\1/p')

if [ "$current_digest" = "$digest" ]; then
  echo "already pinned"
else
  kubectl -n "$NS" set image "deploy/$DEPLOY" "$CONTAINER=$pinned" >/dev/null
  if [ "${NOWAIT:-0}" = "1" ]; then
    echo "  › not waiting for the rollout (NOWAIT=1)"
  else
    kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout="${TIMEOUT:-300s}"
  fi
fi
fi # WRITE_MANIFEST_ONLY

# Keep the manifest in step, or the next `kubectl apply` puts the mutable tag back and a
# stale cached layer can serve an older image (that happened four times in one day, twice
# during an apply that looked like a no-op). The reference keeps the tag for readability
# and adds the digest the kubelet actually resolves: `:dev@sha256:…`.
#
# `WRITE_MANIFEST=0` skips this half and only moves the cluster: that is the fast dev
# loop (`make dev-refresh`), where the repository should not be dirtied for every merge
# on `main`. The stable path (`make pin-images`) is the one that writes the manifests,
# so a reproducible install still carries the digests it was tested with.
#
# The operator's image line is `tag:` under `image:` (helm-values/operator.yaml), not
# `image:`; its writer is the branch below.
case "$APP" in
  nova)  manifest="${MANIFEST:-manifests/nova-deployment.yaml}" ;;
  spark) manifest="${MANIFEST:-manifests/spark.yaml}" ;;
  stardelt-operator) manifest="${MANIFEST:-helm-values/operator.yaml}" ;;
  *)     manifest="${MANIFEST:-}" ;;
esac

if [ "${WRITE_MANIFEST:-1}" = "1" ] && [ -n "$manifest" ] && [ -f "$manifest" ] && grep -qE "^\s+image: $REGISTRY/$REPO:" "$manifest"; then
  python3 - "$manifest" "$REGISTRY/$REPO" "$digest" "$APP" <<'PYEOF'
import re, sys
path, repo, digest, app = sys.argv[1:5]
text = open(path).read()

# The Deployment's own image.
text, replaced = re.subn(
    rf"(^\s+image: ){re.escape(repo)}:([^\s@]+)(?:@sha256:[0-9a-f]+)?\s*$",
    lambda m: f"{m.group(1)}{repo}:{m.group(2)}@{digest}",
    text,
    flags=re.M,
)

# Spark executors are created by the driver from spark-defaults.conf, not from
# the Deployment spec. Pin the same digest there, or a node with a cached `dev`
# layer can run executors from an older build while the driver runs the new one.
if app == "spark":
    text, executor = re.subn(
        rf"(^\s+spark\.kubernetes\.container\.image\s+){re.escape(repo)}:([^\s@]+)(?:@sha256:[0-9a-f]+)?\s*$",
        lambda m: f"{m.group(1)}{repo}:{m.group(2)}@{digest}",
        text,
        flags=re.M,
    )
    replaced += executor

if replaced:
    open(path, "w").write(text)
    print(f"› {path}: image pinned to {repo}:…@{digest[:19]}…")
PYEOF
fi

if [ "${WRITE_MANIFEST:-1}" = "1" ] && [ "$APP" = "stardelt-operator" ] && [ -f "$manifest" ]; then
  python3 - "$manifest" "$digest" <<'PYEOF'
import re, sys
path, digest = sys.argv[1:3]
text = open(path).read()
text, replaced = re.subn(
    r"(^\s+tag:\s*[^\s@]+)(?:@sha256:[0-9a-f]+)?\s*$",
    lambda m: f"{m.group(1)}@{digest}",
    text,
    flags=re.M,
)
if replaced != 1:
    sys.exit(f"expected exactly one `tag:` line in {path}, found {replaced}")
open(path, "w").write(text)
print(f"› {path}: image pinned to …@{digest[:19]}…")
PYEOF
fi

if [ "${WRITE_MANIFEST:-1}" = "1" ] && [ "$APP" = "airflow" ]; then
  # The loader is pinned three times, in two files, and none of them matches the
  # generic `image:` writer above: a bare `digest:` under `images.airflow` and a
  # `demo@sha256:…` tag value in helm-values/airflow.yaml, and the group-roles
  # CronJob image in manifests/airflow-group-roles.yaml. They must move together;
  # `scripts/check-airflow-pin.sh` is what proves that. Each pattern must match
  # exactly once, or the pin would silently drift from one of the three.
  python3 - "$digest" <<'PYEOF'
import re, sys
digest = sys.argv[1]

def rewrite(path, patterns):
    text = open(path).read()
    for pattern, repl in patterns:
        text, count = re.subn(pattern, repl, text, flags=re.M)
        if count != 1:
            sys.exit(f"expected exactly one {pattern!r} in {path}, found {count}")
    open(path, "w").write(text)
    print(f"› {path}: image pinned to …@{digest[:19]}…")

rewrite("helm-values/airflow.yaml", [
    (r"^(\s*digest: )sha256:[0-9a-f]{64}$", lambda m: m.group(1) + digest),
    (r"demo@sha256:[0-9a-f]{64}", "demo@" + digest),
])
rewrite("manifests/airflow-group-roles.yaml", [
    (r"ghcr\.io/stardelt/airflow:demo@sha256:[0-9a-f]{64}",
     "ghcr.io/stardelt/airflow:demo@" + digest),
])
PYEOF
fi

if [ "${WRITE_MANIFEST:-1}" = "1" ] && [ "$APP" = "jupyter" ]; then
  # The notebook image is pinned three times and neither spelling matches the generic writer:
  # a quoted `tag:` under `singleuser.image` (helm-values/jupyterhub.yaml and the product
  # chart's jupyterhub.singleuser.image.tag in chart/values.yaml), and a full reference under
  # PIPELINE_NOTEBOOK_IMAGE. Find each block by its marker line, then the first key line
  # after it — the same rule scripts/check-notebook-image-pin.sh applies. Each must match
  # exactly once, or the pin drifts from one place.
  python3 - "$digest" <<'PYEOF'
import re, sys
digest = sys.argv[1]

def rewrite(path, marker, key):
    lines = open(path).read().splitlines(keepends=True)
    for i, line in enumerate(lines):
        if re.search(marker, line):
            for j in range(i + 1, len(lines)):
                if re.match(key, lines[j]):
                    new, count = re.subn(r"sha256:[0-9a-f]{64}", digest, lines[j])
                    if count != 1:
                        sys.exit(f"expected one digest on {path}:{j + 1}, found {count}")
                    lines[j] = new
                    open(path, "w").writelines(lines)
                    print(f"› {path}: notebook image pinned to …@{digest[:19]}…")
                    return
            sys.exit(f"no {key!r} line after {marker!r} in {path}")
    sys.exit(f"no {marker!r} line in {path}")

rewrite("helm-values/jupyterhub.yaml", r"name: ghcr\.io/stardelt/jupyter-singleuser$", r"^\s*tag:")
rewrite("helm-values/airflow.yaml", r"name: PIPELINE_NOTEBOOK_IMAGE$", r"^\s*value:")
rewrite("chart/values.yaml", r"name: ghcr\.io/stardelt/jupyter-singleuser$", r"^\s*tag:")
PYEOF
fi

if [ "${WRITE_MANIFEST:-1}" = "1" ] && [ "$APP" = "superset" ]; then
  # Superset is pinned twice and neither spelling matches the generic writer: a quoted
  # `tag:` under `image:` and the group-roles CronJob's full reference. Both must move
  # together; scripts/check-superset-roles.sh proves it.
  python3 - "$digest" <<'PYEOF'
import re, sys
digest = sys.argv[1]

def rewrite(path, pattern):
    text = open(path).read()
    # The trailing `()` is an empty second group so the lambda below is the same for both
    # files: group(1) is the text before the digest, group(2) the text after it.
    text, count = re.subn(pattern + "()", lambda m: m.group(1) + digest + m.group(2), text, flags=re.M)
    if count != 1:
        sys.exit(f"expected exactly one Superset digest in {path}, found {count}")
    open(path, "w").write(text)
    print(f"› {path}: image pinned to …@{digest[:19]}…")

rewrite("helm-values/superset.yaml", r'(^\s*tag:\s*"dev@)sha256:[0-9a-f]{64}("\s*$)')
rewrite("manifests/superset-group-roles.yaml", r'(ghcr\.io/stardelt/superset:dev@)sha256:[0-9a-f]{64}')
PYEOF
fi

# The operator's image carries its API. Helm applies chart/crds/ on `helm install` only, never on
# `helm upgrade`, so a cluster keeps the schema it was first installed with while the new binary
# expects the new fields — and when the generated CRD itself is invalid the apply fails silently
# for the schema and only the image moves (stardelt-platform#539, stardelt-operator#267). Moving
# the operator's digest therefore moves its schemas too — resolved above from the same commit
# the image was built from, never from a checkout that may be behind.
# APPLY_CRDS=0 skips it; a missing checkout prints a note instead of failing, because this script
# runs for other images on machines without the operator repo.
if [ -n "$CRDS_DIR" ]; then
  if [ -d "$CRDS_DIR" ]; then
    kubectl apply --server-side --force-conflicts -f "$CRDS_DIR"
  else
    echo "  › no operator CRDs at $CRDS_DIR — the CRD schema was not updated (set OPERATOR_DIR)" >&2
  fi
fi
