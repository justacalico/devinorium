#!/bin/bash
set -euo pipefail

# Find and watch a GitHub Actions run, exiting 0 only when it concludes
# "success". Any other conclusion fails the calling job so the GitLab
# pipeline reflects the GitHub build result.
#
# Usage:
#   watch-github-run.sh find --sha <commit> [--event <event>] [--branch <branch>] [--since <iso8601>]
#       Poll until a matching run appears and print its run id.
#   watch-github-run.sh <run_id>
#       Watch an existing run until it finishes.

REPO="justacalico/devinorium"
WORKFLOW="build.yml"

find_run() {
  local sha="$1" event="$2" branch="$3" since="$4" run_id="" runs=""
  local -a args=(-f "head_sha=$sha" -f per_page=10)
  [ -n "$event" ] && args+=(-f "event=$event")
  [ -n "$branch" ] && args+=(-f "branch=$branch")

  echo "Looking for GitHub run (sha=$sha event=${event:-any})..." >&2
  for _ in {1..30}; do
    sleep 5
    runs=$(gh api --method GET "repos/$REPO/actions/workflows/$WORKFLOW/runs" "${args[@]}" \
      -q '.workflow_runs[] | "\(.id) \(.created_at)"' 2>/dev/null || true)
    if [ -n "$since" ]; then
      # Skip runs created before the trigger so a stale run for the same
      # commit is not picked up while the new one is still registering.
      run_id=$(printf '%s\n' "$runs" | awk -v s="$since" '$2 >= s {print $1; exit}')
    else
      run_id=$(printf '%s\n' "$runs" | awk 'NR == 1 {print $1}')
    fi
    if [ -n "$run_id" ]; then
      echo "$run_id"
      return 0
    fi
  done
  return 1
}

watch_run() {
  local run_id="$1" conclusion=""
  echo "Watching GitHub run $run_id..."
  for attempt in 1 2 3; do
    # --exit-status does not treat every non-success conclusion as a
    # failure, so always verify the conclusion from the API afterwards.
    gh run watch "$run_id" -R "$REPO" --exit-status 2>&1 || true

    conclusion=$(gh api "repos/$REPO/actions/runs/$run_id" -q '.conclusion' 2>/dev/null || true)
    case "$conclusion" in
      success)
        return 0
        ;;
      failure | cancelled | timed_out | startup_failure | action_required | stale | skipped | neutral)
        echo "GitHub run $run_id concluded: $conclusion" >&2
        return 1
        ;;
      *)
        echo "gh run watch lost connection (attempt $attempt), retrying..."
        sleep 10
        ;;
    esac
  done

  echo "Could not determine conclusion for GitHub run $run_id" >&2
  return 1
}

case "${1:-}" in
  find)
    shift
    SHA=""
    EVENT=""
    BRANCH=""
    SINCE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --sha)
          SHA="$2"
          shift 2
          ;;
        --event)
          EVENT="$2"
          shift 2
          ;;
        --branch)
          BRANCH="$2"
          shift 2
          ;;
        --since)
          SINCE="$2"
          shift 2
          ;;
        *)
          echo "Unknown option: $1" >&2
          exit 1
          ;;
      esac
    done
    [ -n "$SHA" ] || {
      echo "find requires --sha" >&2
      exit 1
    }
    find_run "$SHA" "$EVENT" "$BRANCH" "$SINCE"
    ;;
  "")
    echo "Usage: watch-github-run.sh find --sha <commit> [--event <event>] [--branch <branch>] [--since <iso8601>]" >&2
    echo "       watch-github-run.sh <run_id>" >&2
    exit 1
    ;;
  *)
    watch_run "$1"
    ;;
esac
