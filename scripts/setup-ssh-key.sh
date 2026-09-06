#!/bin/sh
set -eu

# Write a private SSH key from a GitLab CI/CD variable (text or File type) to
# ~/.ssh/id_ed25519, normalize common paste formats, validate it with ssh-keygen,
# and fetch the host key into ~/.ssh/known_hosts.

KEY_VAR="${1:-}"
HOST="${2:-}"

if [ -z "$KEY_VAR" ] || [ -z "$HOST" ]; then
  echo "Usage: $0 <env-var-name> <ssh-host>" >&2
  exit 1
fi

# Indirect expansion: get the value of the variable whose name is in KEY_VAR.
KEY_VALUE=$(eval "printf '%s' \"\${$KEY_VAR:-}\"")

if [ -z "$KEY_VALUE" ]; then
  echo "$KEY_VAR is not set, skipping SSH key setup" >&2
  exit 0
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh

TMP=~/.ssh/id_ed25519.tmp
if [ -f "$KEY_VALUE" ]; then
  cp "$KEY_VALUE" "$TMP"
else
  printf '%s\n' "$KEY_VALUE" > "$TMP"
fi

# Normalize pasted keys that use literal \n and remove any stray carriage returns.
sed 's/\\n/\n/g' "$TMP" | tr -d '\r' > ~/.ssh/id_ed25519
rm -f "$TMP"

# Ensure a trailing newline; some tools reject a key that ends mid-line.
printf '\n' >> ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519

if ! ssh-keygen -y -f ~/.ssh/id_ed25519 >/dev/null 2>&1; then
  echo "ERROR: $KEY_VAR is not a loadable SSH private key" >&2
  exit 1
fi

ssh-keyscan -t ed25519 "$HOST" > ~/.ssh/known_hosts
