#!/bin/bash
set -euo pipefail

# Post or update a comment on a GitLab merge request so the MR shows the live
# state of the GitHub build. Each GitLab pipeline gets its own comment.

ACTION="${1:-start}"
MR_IID="${CI_MERGE_REQUEST_IID:-}"
PROJECT_ID="${CI_PROJECT_ID:-}"
PIPELINE_ID="${CI_PIPELINE_ID:-}"
JOB_NAME="${CI_JOB_NAME:-}"
RUN_ID="${RUN_ID:-}"

[ -n "$MR_IID" ] || exit 0
[ -n "$PROJECT_ID" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

TOKEN="${GITLAB_MR_COMMENT_TOKEN:-${CI_JOB_TOKEN:-}}"
[ -n "$TOKEN" ] || exit 0

SERVER_URL="${CI_SERVER_URL:-https://gitlab.com}"
API_BASE="${SERVER_URL}/api/v4"
PROJECT_PATH="${CI_PROJECT_PATH:-HttpAnimations/devinorium}"
MARKER="<!-- mr-pipeline-${PIPELINE_ID} -->"
PIPELINE_URL="${SERVER_URL}/${PROJECT_PATH}/-/pipelines/${PIPELINE_ID}"
RUN_URL="https://github.com/justacalico/devinorium/actions/runs/${RUN_ID}"

# CI job tokens can only read the Notes API, so an MR comment token is needed.
# If GITLAB_MR_COMMENT_TOKEN is set (PAT) we use PRIVATE-TOKEN.
# Otherwise we fall back to CI_JOB_TOKEN with the JOB-TOKEN header, which can only read.
AUTH_HEADER_FILE="$(mktemp)"
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT
if [ -n "${GITLAB_MR_COMMENT_TOKEN:-}" ]; then
  printf 'PRIVATE-TOKEN: %s\n' "$TOKEN" > "$AUTH_HEADER_FILE"
else
  printf 'JOB-TOKEN: %s\n' "$TOKEN" > "$AUTH_HEADER_FILE"
fi

post_or_update() {
  local body="$1"
  local note_id
  note_id=$(curl -fsS --header "@$AUTH_HEADER_FILE" "${API_BASE}/projects/${PROJECT_ID}/merge_requests/${MR_IID}/notes?per_page=100" | jq -r --arg marker "$MARKER" '.[] | select(.body | contains($marker)) | .id' | head -n1)
  if [ -n "$note_id" ] && [ "$note_id" != "null" ]; then
    curl -fsS -X PUT --header "@$AUTH_HEADER_FILE" "${API_BASE}/projects/${PROJECT_ID}/merge_requests/${MR_IID}/notes/${note_id}" --data-urlencode "body=${body}"
  else
    curl -fsS -X POST --header "@$AUTH_HEADER_FILE" "${API_BASE}/projects/${PROJECT_ID}/merge_requests/${MR_IID}/notes" --data-urlencode "body=${body}"
  fi
}

case "$ACTION" in
  start)
    body="${MARKER}
**Pipeline ${PIPELINE_ID}** · ${JOB_NAME} · [in progress](${PIPELINE_URL})

GitHub run: ${RUN_URL:+[View on GitHub](${RUN_URL})}"
    post_or_update "$body"
    ;;

  update)
    body="${MARKER}
**Pipeline ${PIPELINE_ID}** · ${JOB_NAME} · [in progress](${PIPELINE_URL})

GitHub run: [View on GitHub](${RUN_URL})"
    post_or_update "$body"
    ;;

  finish)
    conclusion="${2:-failed}"
    icon="❌"
    [ "$conclusion" = "success" ] && icon="✅"

    jobs=""
    downloads=""
    if [ -n "$RUN_ID" ] && command -v gh >/dev/null 2>&1; then
      jobs=$(gh run view "$RUN_ID" -R justacalico/devinorium --json jobs 2>/dev/null | jq -r '.jobs[] | select(.conclusion != null or .status != null) | "- **\(.name)**: \(.conclusion // .status)"' || true)
      downloads=$(gh api "repos/justacalico/devinorium/actions/runs/${RUN_ID}/artifacts?per_page=100" 2>/dev/null \
        | jq -r --arg run "$RUN_ID" '.artifacts[] | select(.expired != true) | "- [\(.name)](https://github.com/justacalico/devinorium/actions/runs/\($run)/artifacts/\(.id))"' || true)
    fi
    [ -n "$jobs" ] || jobs="GitHub job details unavailable."

    downloads_section=""
    if [ -n "$downloads" ]; then
      downloads_section="

Downloads (GitHub sign-in required):
${downloads}"
    fi

    body="${MARKER}
**Pipeline ${PIPELINE_ID}** · ${JOB_NAME} · ${icon} ${conclusion}

GitHub run: [View on GitHub](${RUN_URL})
GitLab pipeline: [View on GitLab](${PIPELINE_URL})

GitHub jobs:
${jobs}${downloads_section}"
    post_or_update "$body"
    ;;
esac
