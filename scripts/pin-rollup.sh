#!/usr/bin/env bash
# Roll the four image pins to the digests their tags resolve to right now, in one PR.
# The fourth is the pipeline loader, `ghcr.io/stardelt/airflow:demo` (tag `demo`, not `dev`).
#   bash scripts/pin-rollup.sh            # local: rewrite the files, no git
#   OPEN_PR=1 bash scripts/pin-rollup.sh  # CI: commit, force-push branch, open/refresh the PR
#                                          # (a repository that forbids Actions from opening PRs
#                                          # keeps the branch and exits 0 — platform#648)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

pin() { PRINT_DIGEST=1 ./scripts/pin-image.sh "$1"; }

extract_digest() {
  python3 - "$1" "$2" <<'PY'
import re, sys
path, kind = sys.argv[1], sys.argv[2]
text = open(path).read()
if kind == 'operator':
    m = re.search(r'^\s+tag:\s*[^\s@]+@(sha256:[0-9a-f]{64})\s*$', text, re.M)
elif kind == 'nova':
    m = re.search(r'^\s+image:\s*ghcr\.io/stardelt/nova:[^\s@]+@(sha256:[0-9a-f]{64})\s*$', text, re.M)
elif kind == 'spark':
    m = re.search(r'ghcr\.io/stardelt/spark:[^\s@]+@(sha256:[0-9a-f]{64})', text)
elif kind == 'airflow':
    m = re.search(r'^\s*digest:\s*(sha256:[0-9a-f]{64})\s*$', text, re.M)
else:
    sys.exit(f'unknown kind {kind}')
if not m:
    sys.exit(f'could not find digest for {kind} in {path}')
print(m.group(1))
PY
}

rewrite_files() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import re, sys
op_path, nova_path, spark_path, op_digest, nova_digest, spark_digest = sys.argv[1:7]

# operator: helm-values/operator.yaml, tag: dev@sha256:...
text = open(op_path).read()
text, n = re.subn(
    r'(^\s+tag:\s*[^\s@]+)@sha256:[0-9a-f]{64}\s*$',
    lambda m: f'{m.group(1)}@{op_digest}',
    text, flags=re.M)
if n != 1:
    sys.exit(f'expected exactly one operator tag line in {op_path}, found {n}')
open(op_path, 'w').write(text)

# nova: manifests/nova-deployment.yaml
text = open(nova_path).read()
text, n = re.subn(
    r'(^\s+image:\s*ghcr\.io/stardelt/nova:[^\s@]+)@sha256:[0-9a-f]{64}\s*$',
    lambda m: f'{m.group(1)}@{nova_digest}',
    text, flags=re.M)
if n != 1:
    sys.exit(f'expected exactly one nova image line in {nova_path}, found {n}')
open(nova_path, 'w').write(text)

# spark: manifests/spark.yaml (two lines)
text = open(spark_path).read()
text, n = re.subn(
    r'(ghcr\.io/stardelt/spark:[^\s@]+)@sha256:[0-9a-f]{64}',
    lambda m: f'{m.group(1)}@{spark_digest}',
    text)
if n != 2:
    sys.exit(f'expected exactly two spark image refs in {spark_path}, found {n}')
open(spark_path, 'w').write(text)
PY
}

short() { printf '%s' "${1#sha256:}" | cut -c1-8; }

OP_FILE="helm-values/operator.yaml"
NOVA_FILE="manifests/nova-deployment.yaml"
SPARK_FILE="manifests/spark.yaml"
AIRFLOW_FILE="helm-values/airflow.yaml"
AIRFLOW_GROUP_FILE="manifests/airflow-group-roles.yaml"

old_operator="$(extract_digest "$OP_FILE" operator)"
old_nova="$(extract_digest "$NOVA_FILE" nova)"
old_spark="$(extract_digest "$SPARK_FILE" spark)"
old_airflow="$(extract_digest "$AIRFLOW_FILE" airflow)"

operator_digest="$(pin stardelt-operator)"
nova_digest="$(pin nova)"
spark_digest="$(pin spark)"
airflow_digest="$(pin airflow)"

# Normalize: pin-image.sh may print whitespace
operator_digest="$(printf '%s' "$operator_digest" | tr -d '[:space:]')"
nova_digest="$(printf '%s' "$nova_digest" | tr -d '[:space:]')"
spark_digest="$(printf '%s' "$spark_digest" | tr -d '[:space:]')"
airflow_digest="$(printf '%s' "$airflow_digest" | tr -d '[:space:]')"

changes=()
[ "$old_operator" != "$operator_digest" ] && changes+=("operator $(short "$old_operator") → $(short "$operator_digest")")
[ "$old_nova" != "$nova_digest" ] && changes+=("nova $(short "$old_nova") → $(short "$nova_digest")")
[ "$old_spark" != "$spark_digest" ] && changes+=("spark $(short "$old_spark") → $(short "$spark_digest")")
[ "$old_airflow" != "$airflow_digest" ] && changes+=("airflow $(short "$old_airflow") → $(short "$airflow_digest")")

if [ "${#changes[@]}" -eq 0 ]; then
  echo "pins current (operator $(short "$operator_digest"), nova $(short "$nova_digest"), spark $(short "$spark_digest"), airflow $(short "$airflow_digest"))"
  exit 0
fi

rewrite_files "$OP_FILE" "$NOVA_FILE" "$SPARK_FILE" "$operator_digest" "$nova_digest" "$spark_digest"

# The loader is pinned three times in the two files below; its writer stays in
# pin-image.sh so the two callers cannot drift. WRITE_MANIFEST_ONLY skips every
# cluster call — this script runs on a GitHub runner with no kubeconfig.
if [ "$old_airflow" != "$airflow_digest" ]; then
  APP=airflow WRITE_MANIFEST_ONLY=1 ./scripts/pin-image.sh >/dev/null
fi

for c in "${changes[@]}"; do echo "$c"; done

if [ "${OPEN_PR:-0}" != "1" ]; then
  exit 0
fi

# CI path: run the two checks the workflow cannot trigger via bot push, then open/refresh the PR.
helm_out="$(helm lint chart 2>&1)" || helm_rc=$?
helm_rc=${helm_rc:-0}
parity_out="$(bash scripts/check-version-parity.sh 2>&1)" || parity_rc=$?
parity_rc=${parity_rc:-0}

body_file="$(mktemp "${TMPDIR:-/tmp}/pin-rollup-body.XXXXXX")"
trap 'rm -f "$body_file"' EXIT
{
  echo "## Digest changes"
  echo ""
  for c in "${changes[@]}"; do echo "- \`$c\`"; done
  echo ""
  echo "## Verification (bot push suppresses pull-request checks)"
  echo ""
  echo "Pull-request checks do not run for pushes made with \`GITHUB_TOKEN\`, so the rollup ran these two checks itself. A reviewer can trust these results instead."
  echo ""
  echo "\`helm lint chart\` renders the umbrella chart's templates with its sub-charts not fetched (a GitHub release download 504 blocks the roll; they are unrelated to a digest pin). The merge to \`main\` runs the full CI \`Helm lint\` job with every dependency."
  echo ""
  echo "### helm lint chart (exit ${helm_rc})"
  echo '```'
  echo "$helm_out"
  echo '```'
  echo ""
  echo "### scripts/check-version-parity.sh (exit ${parity_rc})"
  echo '```'
  echo "$parity_out"
  echo '```'
} > "$body_file"

git config user.name "github-actions[bot]" 2>/dev/null || true
git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true

branch="chore/pin-rollup"
git switch -C "$branch"
git add "$OP_FILE" "$NOVA_FILE" "$SPARK_FILE" "$AIRFLOW_FILE" "$AIRFLOW_GROUP_FILE"
git commit -m "chore(pins): rollup image digests

$(for c in "${changes[@]}"; do echo "- $c"; done)"

# The checkout has no remote-tracking ref for the rolling branch, and
# `--force-with-lease` refuses to overwrite a ref it has not seen ("stale info"):
# fetch it first (it is absent on the very first run, which is fine).
if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  git fetch --quiet origin "$branch"
fi
git push --force-with-lease origin "$branch"

# Reuse the open PR only. A merged or closed one for the same branch must not be
# edited: after a merge the branch is deleted and the next run opens a new PR.
title="chore(pins): rollup image digests"
pr_number="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // ""')"
if [ -n "$pr_number" ]; then
  gh pr edit "$pr_number" --title "$title" --body-file "$body_file"
  echo "updated PR #$pr_number for $branch"
else
  # The repository forbids Actions from creating pull requests (platform#648, option 2):
  # keep the pushed branch, say how to open the PR, and do not fail the roll for a
  # repository setting. The daily `pin-freshness` workflow files the visible issue
  # while the pins on `main` are behind.
  if pr_out="$(gh pr create --head "$branch" --base main --title "$title" --body-file "$body_file" 2>&1)"; then
    printf '%s\n' "$pr_out"
  else
    case "$pr_out" in
      *"not permitted to create"*|*"permitted to create or approve pull requests"*)
        echo "branch $branch pushed but no PR was opened: this repository forbids Actions from creating pull requests (platform#648)." >&2
        echo "open it by hand: gh pr create --head $branch --base main --title '$title'" >&2
        ;;
      *)
        printf '%s\n' "$pr_out" >&2
        exit 1
        ;;
    esac
  fi
fi

# The bot push suppresses the pull-request checks, so these two are the gate: a
# red workflow is the only signal left. The PR body already carries both results.
if [ "$helm_rc" -ne 0 ] || [ "$parity_rc" -ne 0 ]; then
  echo "rollup checks failed (helm lint chart: $helm_rc, version parity: $parity_rc)" >&2
  exit 1
fi
