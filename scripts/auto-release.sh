#!/bin/bash
set -euo pipefail

# Auto-release on pushes to main: when the commits since the latest tag
# warrant a version bump, cocogitto creates the version commit (using the
# lightweight "ci" hook profile) and tag, which are pushed to GitLab. The
# bump commit is pushed with ci.skip so it does not trigger another
# pipeline; the tag push starts the tag pipeline that mirrors the tag to
# GitHub where the release build and release happen.

# Base the bump on the latest remote main in case more merges landed while
# this pipeline was running.
git fetch origin main "+refs/tags/*:refs/tags/*"
git checkout -B main origin/main
git clean -fd

if ! version=$(cog bump --dry-run --auto 2>/dev/null) || [ -z "$version" ]; then
  echo "No version bump required, skipping release"
  exit 0
fi
echo "Bumping to $version"

cog bump --auto --hook-profile ci

TAG=$(git tag --points-at HEAD | head -n1)
if [ -z "$TAG" ]; then
  echo "cog bump did not create a tag" >&2
  exit 1
fi

push_bump() {
  git push -o ci.skip origin HEAD:main
}

if ! push_bump; then
  echo "Main moved while bumping, rebasing onto latest origin/main"
  git fetch origin main "+refs/tags/*:refs/tags/*"
  git rebase origin/main
  git tag -f "$TAG"
  push_bump
fi

git push origin "$TAG"
echo "Released $TAG"
