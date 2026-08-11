#!/usr/bin/env bash
# Build the Dioxus WASM frontend and copy output to frontend/dist/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$PROJECT_DIR/frontend"

cd "$FRONTEND_DIR"

# Step 1: Build Tailwind CSS from input.css → assets/styles.css
echo "Building Tailwind CSS..."
npx tailwindcss -i ./src/input.css -o ./assets/styles.css --minify

# Step 2: Build Dioxus WASM frontend
echo "Building Dioxus frontend (release)..."
dx build --release

# Copy build output to frontend/dist/
BUILD_OUTPUT="$PROJECT_DIR/target/dx/devinorium-frontend/release/web/public"
DIST_DIR="$FRONTEND_DIR/dist"

echo "Copying build output to $DIST_DIR..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -r "$BUILD_OUTPUT"/* "$DIST_DIR/"

echo "Frontend build complete. Output in $DIST_DIR"
