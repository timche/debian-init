#!/bin/bash

# Install the authorized_keys for the devices you connect from. provision.sh
# inherits whatever root was already reachable with; this is where the rest are
# pasted in, and where a VM that inherited nothing gets its first one.
#
# Every pasted line is put through ssh-keygen before it lands, because
# harden-ssh.sh reads this file as proof there is a way back in and turns
# password logins off on the strength of it — a wrapped or truncated paste
# caught after that is caught too late.
#
# Safe to re-run: keys already in the file are left alone, new ones appended.

set -euo pipefail

authorized_keys="$HOME/.ssh/authorized_keys"

if [ ! -t 0 ]; then
  echo "keys.sh needs a terminal to prompt for a paste — run it directly." >&2
  exit 0
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

install_authorized_keys() {
  echo
  echo "Paste the public keys allowed to SSH in, one per line."
  echo "A blank line ends the list; ctrl-D also works."
  echo

  local line added=0
  local staged
  staged="$(mktemp)"

  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || break

    printf '%s\n' "$line" >"$staged"
    if ! ssh-keygen -l -f "$staged" >/dev/null 2>&1; then
      echo "  that does not parse as a public key; try again." >&2
      continue
    fi

    if [ -f "$authorized_keys" ] && grep -qxF "$line" "$authorized_keys"; then
      echo "  already present, skipped"
      continue
    fi

    printf '%s\n' "$line" >>"$authorized_keys"
    added=$((added + 1))
  done

  rm -f "$staged"

  touch "$authorized_keys"
  chmod 600 "$authorized_keys"

  if [ "$added" -gt 0 ]; then
    echo "added $added key(s) to $authorized_keys"
  else
    echo "no new keys added"
  fi
}

install_authorized_keys
