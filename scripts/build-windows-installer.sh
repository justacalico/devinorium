#!/usr/bin/env bash
# Compile the Devinorium Windows installer (packaging/windows/devinorium.iss)
# with Inno Setup.
#
# Usage: scripts/build-windows-installer.sh <release-dir> <version> <arch> <output-file>
#   release-dir: the Flutter Release dir (build/windows/<x64|arm64>/runner/Release)
#                with the bundled server already copied into server/
#   arch:        x86_64 or arm64
#   output-file: path of the setup exe to produce
set -euo pipefail

RELEASE_DIR="${1:?usage: build-windows-installer.sh <release-dir> <version> <arch> <output-file>}"
VERSION="${2:?usage: build-windows-installer.sh <release-dir> <version> <arch> <output-file>}"
ARCH="${3:?usage: build-windows-installer.sh <release-dir> <version> <arch> <output-file>}"
OUT="${4:?usage: build-windows-installer.sh <release-dir> <version> <arch> <output-file>}"

if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "arm64" ]; then
  echo "build-windows-installer: unsupported arch: $ARCH" >&2
  exit 1
fi
if [ ! -d "$RELEASE_DIR" ]; then
  echo "build-windows-installer: release dir not found: $RELEASE_DIR" >&2
  exit 1
fi
# ISCC resolves relative SourceDir paths against the .iss location, not the
# caller's cwd, so the path must be absolute before cygpath converts it.
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd)"
for f in "$RELEASE_DIR/devinorium_frontend.exe" "$RELEASE_DIR/server/devinorium.exe"; do
  if [ ! -f "$f" ]; then
    echo "build-windows-installer: $RELEASE_DIR is missing $f" >&2
    exit 1
  fi
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
ISS="$REPO_ROOT/packaging/windows/devinorium.iss"
ICON="$REPO_ROOT/flutter/windows/runner/resources/app_icon.ico"
LICENSE_FILE="$REPO_ROOT/LICENSE"
for f in "$ISS" "$ICON" "$LICENSE_FILE"; do
  if [ ! -f "$f" ]; then
    echo "build-windows-installer: missing packaging asset: $f" >&2
    exit 1
  fi
done

find_iscc() {
  if command -v iscc >/dev/null 2>&1; then
    command -v iscc
    return
  fi
  if command -v ISCC.exe >/dev/null 2>&1; then
    command -v ISCC.exe
    return
  fi
  local base
  for base in \
    "$(printenv 'ProgramFiles(x86)' 2>/dev/null)" \
    "$(printenv 'ProgramFiles' 2>/dev/null)" \
    '/c/Program Files (x86)' \
    '/c/Program Files'; do
    [ -n "$base" ] && [ -f "$base/Inno Setup 6/ISCC.exe" ] && {
      printf '%s\n' "$base/Inno Setup 6/ISCC.exe"
      return
    }
  done
  return 1
}

ISCC_BIN="$(find_iscc)" || {
  echo "build-windows-installer: ISCC.exe not found; install Inno Setup 6.3+ first" >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
OUT_NAME="$(basename "$OUT" .exe)"

# MSYS2_ARG_CONV_EXCL keeps Git Bash from rewriting the /D /O /F options as
# paths; every real path is converted to a Windows path with cygpath instead.
MSYS2_ARG_CONV_EXCL='*' "$ISCC_BIN" \
  /Q \
  "/DMyAppVersion=$VERSION" \
  "/DSourceDir=$(cygpath -w "$RELEASE_DIR")" \
  "/DArch=$ARCH" \
  "/DIconFile=$(cygpath -w "$ICON")" \
  "/DLicenseFile=$(cygpath -w "$LICENSE_FILE")" \
  "/O$(cygpath -w "$OUT_DIR")" \
  "/F$OUT_NAME" \
  "$(cygpath -w "$ISS")"

if [ ! -f "$OUT_DIR/$OUT_NAME.exe" ]; then
  echo "build-windows-installer: expected output missing: $OUT_DIR/$OUT_NAME.exe" >&2
  exit 1
fi
echo "build-windows-installer: $OUT_DIR/$OUT_NAME.exe"
