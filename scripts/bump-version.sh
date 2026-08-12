#!/usr/bin/env bash
set -euo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
  echo "Error: version is required" >&2
  exit 1
fi

# Update Cargo.toml package version
awk -v ver="$VERSION" '
/^\[package\]/ { in_package = 1 }
in_package && /^version = / {
  print "version = \"" ver "\""
  in_package = 0
  next
}
{ print }
' Cargo.toml > Cargo.toml.tmp && mv Cargo.toml.tmp Cargo.toml

# Update flutter/pubspec.yaml version and increment build number
if [[ -f flutter/pubspec.yaml ]]; then
  build=1
  if grep -q '^version: .*+' flutter/pubspec.yaml; then
    build=$(grep '^version: ' flutter/pubspec.yaml | sed 's/.*+//')
    build=$((build + 1))
  fi
  sed -i "s/^version: .*/version: ${VERSION}+${build}/" flutter/pubspec.yaml
fi

# Verify
if ! grep -q "^version = \"$VERSION\"" Cargo.toml; then
  echo "Error: Cargo.toml version not updated" >&2
  exit 1
fi
if ! grep -q "^version: ${VERSION}+" flutter/pubspec.yaml; then
  echo "Error: flutter/pubspec.yaml version not updated" >&2
  exit 1
fi
