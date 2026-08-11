#!/usr/bin/env bash
# Build the Flutter web frontend and copy output to frontend/dist/ so the
# Rust backend's `include_dir!("frontend/dist")` picks it up at compile time.
#
# This REPLACES the Dioxus frontend in frontend/dist. To switch back to the
# Dioxus frontend, run scripts/build-frontend.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FLUTTER_DIR="$PROJECT_DIR/flutter"

cd "$FLUTTER_DIR"

echo "Building Flutter web frontend (release, wasm)..."
flutter build web --release --wasm

BUILD_OUTPUT="$FLUTTER_DIR/build/web"
DIST_DIR="$PROJECT_DIR/frontend/dist"

echo "Copying build output to $DIST_DIR..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -r "$BUILD_OUTPUT"/* "$DIST_DIR/"

echo "Flutter frontend build complete. Output in $DIST_DIR"
echo "Rebuild the Rust binary (cargo build --release) to embed it."
