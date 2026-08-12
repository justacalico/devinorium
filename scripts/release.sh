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
glab release create "$VERSION_TAG" \
  --repo "$REPO" \
  --notes-file CHANGELOG.md \
  "${BIN}#${ASSET}"
