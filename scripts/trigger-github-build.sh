#!/bin/bash
set -euo pipefail

# Trigger a GitHub Actions "Build and Release" workflow and block while
# streaming its output, so the GitLab job duration matches the GitHub run and
# the logs appear in GitLab as if it were a native runner.

REPO="justacalico/devinorium"
WORKFLOW="build.yml"

REF="${1:-main}"
BUILD_ALL="${2:-true}"
CREATE_RELEASE="${3:-false}"
PUSH_REF="${4:-HEAD}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PUSHED_SHA=""
if [ -n "$PUSH_REF" ]; then
  if [ "$PUSH_REF" = "HEAD" ] && [ -n "${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-}" ]; then
    if [ -n "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-}" ]; then
      PUSH_REF="$CI_MERGE_REQUEST_SOURCE_BRANCH_SHA"
    elif [ -n "${CI_COMMIT_SHA:-}" ]; then
      PUSH_REF="$CI_COMMIT_SHA"
    else
      git remote add origin "https://gitlab.com/${CI_PROJECT_PATH}.git" 2>/dev/null || true
      git remote update origin 2>/dev/null || true
      PUSH_REF=$(git rev-parse --verify "refs/remotes/origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>/dev/null || git rev-parse HEAD)
    fi
  fi
  PUSHED_SHA=$(git rev-parse "$PUSH_REF^{commit}")
  echo "Pushing $PUSHED_SHA to GitHub branch $REF..."
  git remote add github "git@github.com:$REPO.git" 2>/dev/null || true
  git remote update github
  git push -f github "$PUSHED_SHA:refs/heads/$REF"
fi

update_comment() {
  [ -n "${CI_MERGE_REQUEST_IID:-}" ] || return 0
  "$BASE_DIR/scripts/mr-pipeline-comment.sh" "$@" || {
    echo "Warning: MR comment update failed, continuing build" >&2
    return 0
  }
}

# Post the initial "in progress" MR comment.
update_comment start

echo "Triggering GitHub workflow: $WORKFLOW @ $REF (build_all=$BUILD_ALL, create_release=$CREATE_RELEASE)"
# Record the dispatch time (minus a clock-skew margin) so the run lookup can
# ignore older runs for the same commit.
TRIGGER_TS=$(date -u -d "@$(( $(date +%s) - 120 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
if ! gh workflow run "$WORKFLOW" -R "$REPO" --ref "$REF" \
  -F build_all="$BUILD_ALL" \
  -F create_release="$CREATE_RELEASE"; then
  echo "Failed to trigger GitHub workflow" >&2
  update_comment finish failure
  exit 1
fi

# Find the run created for the commit we pushed, so each pipeline watches
# its own run instead of whatever happens to be newest on the branch.
LOOKUP_SHA="${PUSHED_SHA:-$(git rev-parse "$REF^{commit}" 2>/dev/null || git rev-parse "origin/$REF^{commit}" 2>/dev/null || true)}"
if [ -z "$LOOKUP_SHA" ]; then
  echo "Could not resolve commit for $REF" >&2
  update_comment finish failure
  exit 1
fi
RUN_ID=$("$BASE_DIR/scripts/watch-github-run.sh" find --sha "$LOOKUP_SHA" --event workflow_dispatch --branch "$REF" --since "$TRIGGER_TS" || true)

if [ -z "${RUN_ID:-}" ]; then
  echo "Could not find GitHub run for $REF" >&2
  update_comment finish failure
  exit 1
fi

export RUN_ID
update_comment update

if ! "$BASE_DIR/scripts/watch-github-run.sh" "$RUN_ID"; then
  FINAL_CONCLUSION=$(gh api "repos/$REPO/actions/runs/$RUN_ID" -q '.conclusion' 2>/dev/null || true)
  [ -n "$FINAL_CONCLUSION" ] && [ "$FINAL_CONCLUSION" != "null" ] || FINAL_CONCLUSION="failure"
  update_comment finish "$FINAL_CONCLUSION"
  exit 1
fi

update_comment finish success
