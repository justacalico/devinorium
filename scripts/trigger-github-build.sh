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
PUSH_REF="${4:-}"

if [ -n "$PUSH_REF" ]; then
  if [ "$PUSH_REF" = "HEAD" ] && [ -n "${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-}" ]; then
    if [ -n "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-}" ]; then
      PUSH_REF="$CI_MERGE_REQUEST_SOURCE_BRANCH_SHA"
    else
      git remote add origin "https://gitlab.com/${CI_PROJECT_PATH}.git" 2>/dev/null || true
      git remote update origin 2>/dev/null || true
      PUSH_REF=$(git rev-parse --verify "refs/remotes/origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>/dev/null || git rev-parse HEAD)
    fi
  fi
  echo "Pushing $PUSH_REF to GitHub branch $REF..."
  git remote add github "git@github.com:$REPO.git" 2>/dev/null || true
  git remote update github
  git push -f github "$PUSH_REF:refs/heads/$REF"
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
if ! gh workflow run "$WORKFLOW" -R "$REPO" --ref "$REF" \
  -f build_all="$BUILD_ALL" \
  -f create_release="$CREATE_RELEASE"; then
  echo "Failed to trigger GitHub workflow" >&2
  update_comment finish failure
  exit 1
fi

echo "Looking for run ID..."
RUN_ID=""
for i in {1..30}; do
  sleep 5
  # Use the API directly so it works on older gh versions in the container.
  RUN_ID=$(gh api "repos/$REPO/actions/runs?branch=$REF&event=workflow_dispatch&per_page=1" -q '.workflow_runs[0].id' 2>/dev/null || true)
  if [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ]; then
    break
  fi
done

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
  echo "Could not find GitHub run for $REF" >&2
  update_comment finish failure
  exit 1
fi

export RUN_ID
update_comment update

echo "Watching GitHub run $RUN_ID..."
FINAL_CONCLUSION="unknown"
for attempt in 1 2 3; do
  if gh run watch "$RUN_ID" -R "$REPO" --exit-status 2>&1; then
    FINAL_CONCLUSION="success"
    break
  fi

  # watch can fail due to transient GitHub API errors; verify the real run conclusion.
  CONCLUSION=$(gh api "repos/$REPO/actions/runs/$RUN_ID" -q '.conclusion' 2>/dev/null || true)
  case "$CONCLUSION" in
    success)
      FINAL_CONCLUSION="success"
      break
      ;;
    failure|cancelled|timed_out|startup_failure|action_required|stale)
      FINAL_CONCLUSION="$CONCLUSION"
      break
      ;;
    *)
      echo "gh run watch lost connection (attempt $attempt), retrying..."
      sleep 10
      ;;
  esac
done

if [ "$FINAL_CONCLUSION" != "success" ]; then
  [ "$FINAL_CONCLUSION" = "unknown" ] && FINAL_CONCLUSION="failure"
  update_comment finish "$FINAL_CONCLUSION"
  exit 1
fi

update_comment finish success
