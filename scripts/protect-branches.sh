#!/usr/bin/env bash
# Protect `main` in every stardelt repository (issue #38).
#
#   scripts/protect-branches.sh              # apply — idempotent, safe to re-run
#   scripts/protect-branches.sh --dry-run    # print what would change, touch nothing
#
# What it sets, and why:
#   * Required status checks: the CI job names each repo reports for pull
#     requests, so a red build cannot be merged. Because a required check that
#     never reports (typo, renamed job, push-only or path-filtered workflow)
#     silently blocks *every* merge, the names are validated against checks
#     actually seen on recent pull requests first, and a mismatch is fatal.
#   * A pull request is required, but no approvals: the maintainer and AI agents
#     merge under one owner account — CI is the gate, not a second reviewer.
#     (Without the PR requirement, write users could push straight to main and
#     bypass the checks.)
#   * enforce_admins=false: the owner keeps an emergency bypass.
#   * No force pushes, no deletions, linear history: `main` only moves forward,
#     by squash/rebase merges.
#
# Collaboration/release branch protection is deliberately out of scope (issue #38).
#
# Requires an authenticated `gh` with admin rights on the repos (owner account).
set -euo pipefail

OWNER="${OWNER:-stardelt}"
BRANCH="${BRANCH:-main}"
DRY_RUN=false
# How many recent pull requests to sample when validating check names.
PR_SAMPLE="${PR_SAMPLE:-20}"

REPOS=(
  stardelt-docs
  stardelt-platform
  stardelt-nova
  stardelt-operator
  stardelt-demos
)

# Required status checks per repo — the check-run names, exactly as reported on
# pull requests. Discover them with, e.g.:
#   sha=$(gh api /repos/$OWNER/<repo>/commits/main --jq .sha)
#   gh api "/repos/$OWNER/<repo>/commits/$sha/check-runs" --jq '.check_runs[].name'
# Only checks that run on *every* pull request may be listed: a path-filtered
# workflow (platform's `Image`) or a job skipped on PRs (demos' nightly demo)
# never reports on most PRs and would block them forever.
required_checks_for() {
  case "$1" in
    stardelt-docs)
      printf '%s\n' "Docs build (broken links fail)"
      ;;
    stardelt-platform)
      printf '%s\n' "Lint (yamllint + shell + renovate.json)" "Helm lint"
      ;;
    stardelt-nova)
      printf '%s\n' "Backend (Rust)" "Frontend (Node 20)" "Build and push ghcr.io/stardelt/nova"
      ;;
    stardelt-operator)
      printf '%s\n' "check" "Build and push ghcr.io/stardelt/stardelt-operator"
      ;;
    stardelt-demos)
      printf '%s\n' "Lint (shellcheck + hadolint)" "install + smoke on a clean kind cluster"
      ;;
    *)
      return 1
      ;;
  esac
}

die() {
  printf 'protect-branches: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Protect `main` in every stardelt repository (issue #38).

Usage:
  scripts/protect-branches.sh [--dry-run]

  -n, --dry-run   print the differences, change nothing
  -h, --help      this help

Requires an authenticated `gh` with admin rights on the repos.
Idempotent: a second run reports "unchanged" for every repo.
EOF
}

# Check-run names reported on the head commits of the most recent pull requests.
# This is the population branch protection gates on; a name that is not in here
# must not be required.
observed_pr_checks() {
  local repo="$1" sha heads
  heads="$(gh pr list --repo "$OWNER/$repo" --state all --limit "$PR_SAMPLE" \
    --json headRefOid --jq '.[].headRefOid')" || return 1
  while IFS= read -r sha; do
    [ -n "$sha" ] || return 0
    gh api "/repos/$OWNER/$repo/commits/$sha/check-runs?per_page=100" \
      --jq '.check_runs[].name' 2>/dev/null || true
  done <<<"$heads" | sort -u
}

# Fallback for a repo that has no pull requests yet: every job name seen in the
# most recent run of each workflow file (dynamic workflows excluded).
observed_job_names() {
  local repo="$1" wf run
  while IFS= read -r wf; do
    run="$(gh api "/repos/$OWNER/$repo/actions/workflows/$wf/runs?per_page=1" \
      --jq '.workflow_runs[0].id // empty' 2>/dev/null || true)"
    [ -n "$run" ] || continue
    gh api "/repos/$OWNER/$repo/actions/runs/$run/jobs?per_page=100" \
      --jq '.jobs[].name' 2>/dev/null || true
  done < <(gh api "/repos/$OWNER/$repo/actions/runs?per_page=100" \
    --jq '.workflow_runs[] | select(.path | startswith(".github/workflows/")) | .workflow_id' \
    2>/dev/null | sort -u) | sort -u
}

# Current protection JSON, or empty when the branch is unprotected.
current_protection() {
  local repo="$1" out
  if out="$(gh api "/repos/$OWNER/$repo/branches/$BRANCH/protection" 2>/dev/null)"; then
    printf '%s' "$out"
  fi
}

# Human-readable diff between the current protection (JSON, empty = unprotected)
# and the desired state. Empty output means already converged.
protection_diff() {
  local current="$1"
  shift
  local -a desired=("$@")
  local json="${current:-null}" want_checks cur_checks line removed="" added=""

  # Both sides go through the same `LC_ALL=C sort`, so equal sets compare equal
  # byte-for-byte and a converged repo really reports "unchanged".
  want_checks="$(printf '%s\n' "${desired[@]}" | LC_ALL=C sort)"
  cur_checks="$(jq -r '((.required_status_checks.contexts // []) | join("\n"))' <<<"$json" | LC_ALL=C sort)"
  if [ "$want_checks" != "$cur_checks" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -qxF "$line" <<<"$want_checks" || removed="${removed}      - ${line}"$'\n'
    done <<<"$cur_checks"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -qxF "$line" <<<"$cur_checks" || added="${added}      + ${line}"$'\n'
    done <<<"$want_checks"
    printf '  ~ required checks:\n%s%s' "$removed" "$added"
  fi

  [ "$(jq -r '.required_status_checks.strict // false' <<<"$json")" = false ] ||
    printf '  ~ require branches up to date: on → off\n'
  [ "$(jq -r '.enforce_admins.enabled // false' <<<"$json")" = false ] ||
    printf '  ~ enforce for admins: on → off\n'
  [ "$(jq -r '.allow_force_pushes.enabled // false' <<<"$json")" = false ] ||
    printf '  ~ force pushes: allowed → blocked\n'
  [ "$(jq -r '.allow_deletions.enabled // false' <<<"$json")" = false ] ||
    printf '  ~ branch deletions: allowed → blocked\n'
  [ "$(jq -r '.required_linear_history.enabled // false' <<<"$json")" = true ] ||
    printf '  ~ linear history: off → on\n'
  # A pull request is required, with zero approvals — CI is the gate, not a
  # second reviewer. If the section is missing entirely, direct pushes to main
  # would be allowed for write users, so that is a change too.
  local want_reviews cur_reviews
  want_reviews='{"dismiss_stale_reviews":false,"require_code_owner_reviews":false,"require_last_push_approval":false,"required_approving_review_count":0}'
  cur_reviews="$(jq -c '(.required_pull_request_reviews // null) |
    if . == null then null else {
      dismiss_stale_reviews: (.dismiss_stale_reviews // false),
      require_code_owner_reviews: (.require_code_owner_reviews // false),
      require_last_push_approval: (.require_last_push_approval // false),
      required_approving_review_count: (.required_approving_review_count // 0)
    } end' <<<"$json")"
  if [ "$cur_reviews" != "$want_reviews" ]; then
    if [ "$cur_reviews" = null ]; then
      printf '  ~ require a pull request: off → on (no approvals needed)\n'
    else
      printf '  ~ pull-request review settings: %s → %s\n' "$cur_reviews" "$want_reviews"
    fi
  fi
  [ "$(jq -r '(.restrictions // null) == null' <<<"$json")" = true ] ||
    printf '  ~ push restrictions: set → cleared\n'
}

REPO_RESULT=""

protect_repo() {
  local repo="$1" observed current diff_lines payload updated leftover
  local -a desired=() missing=()
  local check

  echo "› $OWNER/$repo"

  # The repo must exist and be reachable with this gh login.
  if ! gh api "/repos/$OWNER/$repo" >/dev/null 2>&1; then
    echo "  ✗ repository $OWNER/$repo not found (or no admin access) — check the name" >&2
    REPO_RESULT=failed
    return
  fi

  mapfile -t desired < <(required_checks_for "$repo")
  if [ "${#desired[@]}" -eq 0 ]; then
    echo "  ✗ no required-check list for $repo — add it to required_checks_for()" >&2
    REPO_RESULT=failed
    return
  fi

  # Validate every required name against checks really reported on PRs.
  observed="$(observed_pr_checks "$repo")" || {
    echo "  ✗ could not read PR check runs for $OWNER/$repo" >&2
    REPO_RESULT=failed
    return
  }
  if [ -z "$observed" ]; then
    echo "  · no PR check runs yet — validating against job names from recent runs"
    observed="$(observed_job_names "$repo")" || true
  fi
  for check in "${desired[@]}"; do
    grep -qxF "$check" <<<"$observed" || missing+=("$check")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "  ✗ required check name(s) never reported on a pull request:" >&2
    printf '      missing: %s\n' "${missing[@]}" >&2
    echo "    check names seen recently:" >&2
    printf '      %s\n' "${observed//$'\n'/$'\n'      }" >&2
    REPO_RESULT=failed
    return
  fi

  local joined=""
  for check in "${desired[@]}"; do
    joined="${joined:+$joined; }$check"
  done
  echo "  · required checks: $joined"

  current="$(current_protection "$repo")"
  diff_lines="$(protection_diff "$current" "${desired[@]}")"
  if [ -z "$diff_lines" ]; then
    echo "  = unchanged — already protected"
    REPO_RESULT=unchanged
    return
  fi
  printf '%s\n' "$diff_lines"

  if [ "$DRY_RUN" = true ]; then
    echo "  · dry run — nothing sent"
    REPO_RESULT=changed
    return
  fi

  payload="$(jq -cn \
    --argjson contexts "$(printf '%s\n' "${desired[@]}" | jq -Rn '[inputs]')" \
    '{required_status_checks: {strict: false, contexts: $contexts},
      enforce_admins: false,
      required_pull_request_reviews: {
        dismiss_stale_reviews: false,
        require_code_owner_reviews: false,
        require_last_push_approval: false,
        required_approving_review_count: 0},
      restrictions: null,
      required_linear_history: true,
      allow_force_pushes: false,
      allow_deletions: false}')"

  if ! updated="$(printf '%s' "$payload" | gh api --method PUT \
    "/repos/$OWNER/$repo/branches/$BRANCH/protection" --input -)"; then
    echo "  ✗ could not apply protection" >&2
    REPO_RESULT=failed
    return
  fi

  # The PUT response is the new state: it must now match the desired state.
  leftover="$(protection_diff "$updated" "${desired[@]}")"
  if [ -n "$leftover" ]; then
    echo "  ✗ applied, but protection does not match the desired state:" >&2
    printf '%s\n' "$leftover" >&2
    REPO_RESULT=failed
    return
  fi

  echo "  ✓ applied"
  REPO_RESULT=changed
}

main() {
  local repo changed=0 unchanged=0 failed=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) DRY_RUN=true ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  command -v gh >/dev/null 2>&1 || die "gh CLI not found (https://cli.github.com)"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'"

  if [ "$DRY_RUN" = true ]; then
    echo "dry run: nothing will be changed"
  fi

  for repo in "${REPOS[@]}"; do
    protect_repo "$repo" || REPO_RESULT=failed
    case "$REPO_RESULT" in
      changed) changed=$((changed + 1)) ;;
      unchanged) unchanged=$((unchanged + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
    echo ""
  done

  if [ "$DRY_RUN" = true ]; then
    printf '%d repo(s): %d would change, %d already protected, %d failed\n' \
      "${#REPOS[@]}" "$changed" "$unchanged" "$failed"
  else
    printf '%d repo(s): %d changed, %d unchanged, %d failed\n' \
      "${#REPOS[@]}" "$changed" "$unchanged" "$failed"
  fi

  [ "$failed" -eq 0 ] || exit 1
}

main "$@"
