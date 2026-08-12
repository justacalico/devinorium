#!/usr/bin/env bash
set -euo pipefail

VERSION="$1"

sed -i "0,/^version = /s/^version = \"[^\"]*\"/version = \"${VERSION}\"/" Cargo.toml
sed -i "s/^version: .*/version: ${VERSION}+1/" flutter/pubspec.yaml
