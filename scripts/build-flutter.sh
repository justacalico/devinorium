#!/usr/bin/env bash
# Build the Flutter web frontend and copy output to frontend/dist/ so the
# Rust backend's `include_dir!("frontend/dist")` picks it up at compile time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FLUTTER_DIR="$PROJECT_DIR/flutter"

cd "$FLUTTER_DIR"

echo "Cleaning previous Flutter build artifacts..."
flutter clean
flutter pub get

MERGE_REQUEST_ID="${MERGE_REQUEST_ID:-}"
MERGE_REQUEST_URL="${MERGE_REQUEST_URL:-}"

DART_DEFINES=()
if [ -n "$MERGE_REQUEST_ID" ]; then
  DART_DEFINES+=(--dart-define=MERGE_REQUEST_ID="$MERGE_REQUEST_ID")
  DART_DEFINES+=(--dart-define=MERGE_REQUEST_URL="$MERGE_REQUEST_URL")
fi

echo "Building Flutter web frontend (release, wasm)..."
flutter build web --release --wasm "${DART_DEFINES[@]}"

BUILD_OUTPUT="$FLUTTER_DIR/build/web"
DIST_DIR="$PROJECT_DIR/frontend/dist"

# The default build fetches CanvasKit/SKWasm from the Google CDN at runtime,
# so the local canvaskit/ folder is unused and only bloats the embedded binary.
echo "Removing unused local CanvasKit copy..."
rm -rf "$BUILD_OUTPUT/canvaskit"

echo "Copying build output to $DIST_DIR..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -r "$BUILD_OUTPUT"/* "$DIST_DIR/"

echo "Flutter frontend build complete. Output in $DIST_DIR"
echo "Rebuild the Rust binary (cargo build --release) to embed it."
