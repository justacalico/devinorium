#!/usr/bin/env bash
# Copy the devinorium server binary into a built Flutter bundle so the desktop
# app can spawn it from <dir containing the app executable>/server/devinorium.
#
# Usage: scripts/bundle-server.sh <devinorium-binary> <app-executable-dir>
set -euo pipefail

BIN="${1:?usage: bundle-server.sh <devinorium-binary> <app-executable-dir>}"
DEST_DIR="${2:?usage: bundle-server.sh <devinorium-binary> <app-executable-dir>}"

if [ ! -f "$BIN" ]; then
  echo "bundle-server: binary not found: $BIN" >&2
  exit 1
fi

mkdir -p "$DEST_DIR/server"
cp "$BIN" "$DEST_DIR/server/"
chmod +x "$DEST_DIR/server/"* || true
echo "bundle-server: $BIN -> $DEST_DIR/server/"
