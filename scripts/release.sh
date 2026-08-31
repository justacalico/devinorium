#!/usr/bin/env bash
set -euo pipefail

VERSION_TAG="$1"
REPO="${CI_PROJECT_PATH:-}"
BIN="target/release/devinorium"

if [ -z "$VERSION_TAG" ]; then
  echo "Error: version tag is required" >&2
  exit 1
fi

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

# Collect every binary that should be attached to the release. The backend
# binary is always present; frontend artifacts are produced by the build-android
# and build-linux CI jobs and pulled in via the release job's `needs:`. Missing
# frontend files are skipped with a warning so a partial build never blocks the
# release.
ASSETS=("${BIN}#${ASSET}")

for entry in \
  "devinorium-android.apk:devinorium-android-${VERSION_TAG}.apk" \
  "devinorium-android.aab:devinorium-android-${VERSION_TAG}.aab" \
  "devinorium-linux-x86_64.tar.gz:devinorium-linux-x86_64-${VERSION_TAG}.tar.gz" \
  "devinorium-linux-x86_64.zip:devinorium-linux-x86_64-${VERSION_TAG}.zip" \
  "devinorium-linux-x86_64.deb:devinorium-linux-x86_64-${VERSION_TAG}.deb"
do
  src="${entry%%:*}"
  dst="${entry##*:}"
  if [ -f "$src" ]; then
    ASSETS+=("${src}#${dst}")
  else
    echo "Warning: $src not found, skipping" >&2
  fi
done

glab release create "$VERSION_TAG" \
  --repo "$REPO" \
  --notes-file "$NOTES_FILE" \
  "${ASSETS[@]}"
