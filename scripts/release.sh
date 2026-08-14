#!/usr/bin/env bash
set -euo pipefail

VERSION_TAG="$1"
REPO="${CI_PROJECT_PATH:-}"
BIN="target/release/devinorium"

if [ -z "$REPO" ]; then
  echo "Error: CI_PROJECT_PATH is not set" >&2
  exit 1
fi

if [ ! -f "$BIN" ]; then
  echo "Error: release binary not found at $BIN" >&2
  exit 1
fi

ASSET="devinorium-${VERSION_TAG}-linux-x86_64"

# Generate release notes for this version only so a v10.1.1 release does not
# include the changelog of every previous release.
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT

cog changelog --at "$VERSION_TAG" > "$NOTES_FILE"

glab release create "$VERSION_TAG" \
  --repo "$REPO" \
  --notes-file "$NOTES_FILE" \
  "${BIN}#${ASSET}"
