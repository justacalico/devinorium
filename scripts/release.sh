#!/usr/bin/env bash
set -euo pipefail

VERSION_TAG="$1"
REPO="${CI_PROJECT_PATH:-HttpAnimations/devinorium}"
BIN="target/release/devinorium"

if [ ! -f "$BIN" ]; then
  echo "Error: release binary not found at $BIN" >&2
  exit 1
fi

glab release create "$VERSION_TAG" \
  --repo "$REPO" \
  --notes-file CHANGELOG.md \
  "${BIN}#devinorium-linux-x86_64"
