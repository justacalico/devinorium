#!/usr/bin/env bash
# Package a built Flutter Linux bundle as an RPM for Fedora and friends.
# Installs to /opt/devinorium with a /usr/bin/devinorium symlink, matching the
# layout used by the .deb package built in CI.
#
# Usage: scripts/build-rpm.sh <bundle-dir> <version> <rpm-arch> <output-file> [release]
#   rpm-arch: x86_64 or aarch64
#   release: rpm release number, defaults to 1 (CI passes the build number so
#            nightly rpms stay upgradeable via dnf)
set -euo pipefail

BUNDLE_DIR="${1:?usage: build-rpm.sh <bundle-dir> <version> <rpm-arch> <output-file> [release]}"
VERSION="${2:?usage: build-rpm.sh <bundle-dir> <version> <rpm-arch> <output-file> [release]}"
ARCH="${3:?usage: build-rpm.sh <bundle-dir> <version> <rpm-arch> <output-file> [release]}"
OUT="${4:?usage: build-rpm.sh <bundle-dir> <version> <rpm-arch> <output-file> [release]}"
RELEASE="${5:-1}"

if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "build-rpm: rpmbuild not found (install the rpm/rpm-build package)" >&2
  exit 1
fi
if [ ! -d "$BUNDLE_DIR" ]; then
  echo "build-rpm: bundle dir not found: $BUNDLE_DIR" >&2
  exit 1
fi
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
  echo "build-rpm: unsupported arch: $ARCH" >&2
  exit 1
fi

# rpm forbids '-' in Version; '~' is the rpm convention for prereleases and
# sorts before the final release.
RPM_VERSION="$(printf '%s' "$VERSION" | tr '-' '~')"

TOPDIR="$(mktemp -d)"
trap 'rm -rf "$TOPDIR"' EXIT
mkdir -p "$TOPDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$TOPDIR/SPECS/devinorium.spec" <<'EOF'
Name: devinorium
Version: %{pkg_version}
Release: %{pkg_release}%{?dist}
Summary: Devinorium desktop client
License: AGPL-3.0-only
URL: https://gitlab.com/HttpAnimations/devinorium

# The bundle is already compiled; skip debug packages and buildroot policy
# scripts (strip, rpath checks) that would mangle or reject the prebuilt libs.
%global debug_package %{nil}
%global __os_install_post %{nil}
# Bundled libs must not leak into the rpm provides namespace.
%global __provides_exclude_from ^/opt/devinorium/.*

%description
A secure, self-hostable Material 3 client for managing Devin work.

%install
mkdir -p %{buildroot}/opt/devinorium %{buildroot}/usr/bin
cp -a %{bundle_dir}/. %{buildroot}/opt/devinorium/
ln -sf /opt/devinorium/devinorium_frontend %{buildroot}/usr/bin/devinorium

%files
/opt/devinorium
/usr/bin/devinorium
EOF

rpmbuild -bb \
  --target "$ARCH" \
  --define "_topdir $TOPDIR" \
  --define "pkg_version $RPM_VERSION" \
  --define "pkg_release $RELEASE" \
  --define "bundle_dir $(realpath "$BUNDLE_DIR")" \
  "$TOPDIR/SPECS/devinorium.spec"

RPM_PATH="$(find "$TOPDIR/RPMS" -name '*.rpm' -print -quit)"
if [ -z "$RPM_PATH" ]; then
  echo "build-rpm: rpmbuild produced no rpm" >&2
  exit 1
fi
cp "$RPM_PATH" "$OUT"
echo "build-rpm: $RPM_PATH -> $OUT"
