#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

RELEASE_TAG="${RELEASE_TAG:-}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-}"
PROJECT_DIR="${CI_PROJECT_DIR:-$PWD}"

GITHUB_REPO="justacalico/devinorium"

cd "$PROJECT_DIR"

# Determine which GitHub release to sync.
if [ -z "$RELEASE_TAG" ]; then
  RELEASE_TAG=$(gh release view -R "$GITHUB_REPO" --json tagName -q .tagName)
fi

echo "Syncing GitHub release: $RELEASE_TAG"

# Resolve the commit that the release tag points to on GitHub.
# The GitLab pipeline may run on main, but the actual release tag may be a
# different commit (e.g. a version bump), so we use the tag's target commit.
RELEASE_COMMIT=$(gh api "repos/$GITHUB_REPO/commits?sha=$RELEASE_TAG&per_page=1" -q '.[0].sha' 2>/dev/null || true)
if [ -z "$RELEASE_COMMIT" ]; then
  echo "Warning: could not resolve tag $RELEASE_TAG on GitHub, falling back to $CI_COMMIT_SHA" >&2
  RELEASE_COMMIT="$CI_COMMIT_SHA"
fi

# Download assets from the GitHub release.
rm -rf release-assets SHA256SUMS.txt
mkdir -p release-assets
gh release download "$RELEASE_TAG" -R "$GITHUB_REPO" --dir release-assets

# Fetch GitHub Actions job logs if a run ID was provided.
if [ -n "$GITHUB_RUN_ID" ]; then
  gh run view "$GITHUB_RUN_ID" -R "$GITHUB_REPO" --log > github-logs.txt 2>/dev/null || true
  if [ -s github-logs.txt ]; then
    cp github-logs.txt release-assets/
  fi
fi

# Generate checksums.
cd release-assets
sha256sum * > "$PROJECT_DIR/SHA256SUMS.txt"
cd "$PROJECT_DIR"
cp SHA256SUMS.txt release-assets/

ls -la release-assets/

# Remove any stale GitLab release, tag and generic package so the
# package-registry upload does not collide with existing assets and the release
# is recreated at the current commit.
glab release delete "$RELEASE_TAG" -R "$CI_PROJECT_PATH" -y 2>/dev/null || true
PKG_ID=$(glab api "projects/$CI_PROJECT_ID/packages?package_name=release-assets&package_version=$RELEASE_TAG" 2>/dev/null | jq -r '.[0].id // empty')
if [ -n "$PKG_ID" ] && [ "$PKG_ID" != "null" ]; then
  glab api --method DELETE "projects/$CI_PROJECT_ID/packages/$PKG_ID" 2>/dev/null || true
fi

# Move the release tag to the same commit as GitHub using an SSH deploy key.
# The CI job token cannot modify tags, but a deploy key with write access can.
if [ -n "${GITLAB_RELEASE_SSH_KEY:-}" ]; then
  git remote add gitlab-ssh "git@gitlab.com:${CI_PROJECT_PATH}.git" 2>/dev/null || true
  git tag -f "$RELEASE_TAG" "$RELEASE_COMMIT"
  git push -f gitlab-ssh "$RELEASE_TAG"
fi

# Mirror to a GitLab release. The tag is kept the same as GitHub.
# glab in CI will use CI_JOB_TOKEN when GLAB_ENABLE_CI_AUTOLOGIN is set.
glab release create "$RELEASE_TAG" \
  --name "Devinorium $RELEASE_TAG" \
  --notes "Mirrored from the GitHub release." \
  --ref "$RELEASE_COMMIT" \
  --use-package-registry \
  "$PROJECT_DIR/release-assets"/*
