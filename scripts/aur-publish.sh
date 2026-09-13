#!/usr/bin/env bash
# Publish the Devinorium AUR packages.
#
#   scripts/aur-publish.sh git            push devinorium-git + devinorium-server-git
#   scripts/aur-publish.sh stable <tag>   push devinorium + devinorium-server at <tag>
#
# Needs SSH access to aur.archlinux.org, either via ~/.ssh/id_ed25519 or the
# AUR_SSH_PRIVATE_KEY env var. makepkg refuses to run as root, so inside a
# root container the script re-execs itself as a build user.
#
# AUR_PUBLISH_DRYRUN=1 stages and validates everything but skips the push and
# keeps the staging dir so it can be inspected.
set -euo pipefail

MODE="${1:?usage: aur-publish.sh <stable|git> [tag]}"
TAG="${2:-${RELEASE_TAG:-}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT/packaging/aur"
AUR_URL_BASE="ssh://aur@aur.archlinux.org"
DRYRUN="${AUR_PUBLISH_DRYRUN:-}"

write_key() {
  # $1: home dir that gets the key
  local home="$1" key="$2"
  install -d -m 700 "$home/.ssh"
  printf '%s\n' "$key" | sed 's/\\n/\n/g' | tr -d '\r' > "$home/.ssh/id_ed25519"
  printf '\n' >> "$home/.ssh/id_ed25519"
  chmod 600 "$home/.ssh/id_ed25519"
  ssh-keygen -y -f "$home/.ssh/id_ed25519" >/dev/null
}

# makepkg refuses to run as root; CI containers run as root, so re-exec as a
# dedicated user with the SSH material copied over.
if [ "$(id -u)" -eq 0 ]; then
  id -u aur-builder >/dev/null 2>&1 || useradd -m -s /bin/bash aur-builder
  if [ -n "${AUR_SSH_PRIVATE_KEY:-}" ]; then
    write_key /root "$AUR_SSH_PRIVATE_KEY"
    install -d -m 700 -o aur-builder -g aur-builder /home/aur-builder/.ssh
    cp /root/.ssh/id_ed25519 /home/aur-builder/.ssh/
    chown aur-builder:aur-builder /home/aur-builder/.ssh/id_ed25519
  fi
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u aur-builder -- env HOME=/home/aur-builder bash "$ROOT/scripts/aur-publish.sh" "$@"
  fi
  exec su aur-builder -s /bin/bash -c "cd '$ROOT' && HOME=/home/aur-builder bash '$ROOT/scripts/aur-publish.sh' $*"
fi

if [ -n "${AUR_SSH_PRIVATE_KEY:-}" ]; then
  write_key "$HOME" "$AUR_SSH_PRIVATE_KEY"
fi

ssh-keyscan -t ed25519 aur.archlinux.org >> ~/.ssh/known_hosts 2>/dev/null || true

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
if [ -f ~/.ssh/id_ed25519 ]; then
  SSH_OPTS+=(-i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes)
fi
export GIT_SSH_COMMAND="ssh ${SSH_OPTS[*]}"

if ! ssh "${SSH_OPTS[@]}" aur@aur.archlinux.org help >/dev/null 2>&1; then
  echo "aur-publish: SSH auth to aur.archlinux.org failed (set AUR_SSH_PRIVATE_KEY)" >&2
  exit 1
fi

VERSION=""
ARCHIVE_SHA=""
GITVER=""
case "$MODE" in
  git)
    PKGS=(devinorium-git devinorium-server-git)
    # Bake the version of the remote main HEAD into the pushed PKGBUILD; that is
    # what -git package builds check out.
    tmpclone="$(mktemp -d)"
    git -C "$tmpclone" init -q
    if git -C "$tmpclone" fetch --quiet --tags "https://gitlab.com/HttpAnimations/devinorium.git" main 2>/dev/null; then
      GITVER=$(git -C "$tmpclone" describe --long --tags FETCH_HEAD 2>/dev/null | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g' || true)
    fi
    rm -rf "$tmpclone"
    if [ -z "$GITVER" ]; then
      GITVER=$(git -C "$ROOT" -c safe.directory="$ROOT" describe --long --tags HEAD 2>/dev/null | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g' || true)
    fi
    [ -n "$GITVER" ] || GITVER="0.0.0"
    echo "git package version: $GITVER"
    ;;
  stable)
    PKGS=(devinorium devinorium-server)
    if [ -z "$TAG" ]; then
      echo "aur-publish: stable mode needs a tag (arg or RELEASE_TAG)" >&2
      exit 1
    fi
    VERSION="${TAG#v}"
    # Deterministic source tarball uploaded by the release job (git archive).
    ARCHIVE_URL="https://github.com/justacalico/devinorium/releases/download/v$VERSION/devinorium-v$VERSION-source.tar.gz"
    echo "Resolving sha256 for $ARCHIVE_URL"
    ARCHIVE_SHA="$(curl -fsSL "$ARCHIVE_URL" | sha256sum | cut -d' ' -f1)"
    [ -n "$ARCHIVE_SHA" ] || { echo "aur-publish: could not hash archive" >&2; exit 1; }
    ;;
  *)
    echo "aur-publish: unknown mode '$MODE'" >&2
    exit 1
    ;;
esac

publish() {
  local pkgbase="$1"
  local stage repo f newver
  stage="$(mktemp -d)"
  repo="$stage/$pkgbase"

  echo "=== $pkgbase ==="
  if ! git clone --quiet "$AUR_URL_BASE/$pkgbase.git" "$repo" 2>/dev/null; then
    git init -q "$repo"
    git -C "$repo" remote add origin "$AUR_URL_BASE/$pkgbase.git"
  fi
  git -C "$repo" checkout -q -B master

  cp "$PKG_DIR/$pkgbase/PKGBUILD" "$repo/PKGBUILD"

  local aux=()
  case "$pkgbase" in
    *server*) aux=(devinorium.service devinorium.sysusers devinorium.env) ;;
    *)        aux=(devinorium.desktop devinorium.svg) ;;
  esac
  for f in "${aux[@]}"; do
    cp "$PKG_DIR/files/$f" "$repo/$f"
  done

  if [ "$MODE" = stable ]; then
    sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$repo/PKGBUILD"
    sed -i "0,/'SKIP'/s/'SKIP'/'$ARCHIVE_SHA'/" "$repo/PKGBUILD"
  else
    sed -i "s/^pkgver=.*/pkgver=$GITVER/" "$repo/PKGBUILD"
  fi

  (cd "$repo" && makepkg --printsrcinfo > .SRCINFO)
  # makepkg may drop VCS clones or build dirs in srcdir; keep them out of the commit.
  rm -rf "$repo/devinorium" "$repo/src" "$repo/pkg"
  newver=$(grep -m1 'pkgver = ' "$repo/.SRCINFO" | awk '{print $3}')

  git -C "$repo" add -A
  if git -C "$repo" diff --cached --quiet; then
    echo "$pkgbase: already up to date ($newver)"
  elif [ "$DRYRUN" = 1 ]; then
    echo "$pkgbase: dry run, would commit + push ($newver)"
  else
    git -C "$repo" -c user.name="${GIT_AUTHOR_NAME:-Devinorium CI}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-devinorium-ci@localhost}" \
      commit -q -m "更新至 $newver"
    git -C "$repo" push origin master
    echo "$pkgbase: published $newver"
  fi
  if [ "$DRYRUN" = 1 ]; then
    echo "$pkgbase: staged at $repo"
  else
    rm -rf "$stage"
  fi
}

for p in "${PKGS[@]}"; do
  publish "$p"
done
echo "Done."
