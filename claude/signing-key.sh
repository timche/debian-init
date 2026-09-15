#!/bin/bash

# Install the commit-signing key. Claude-side rather than part of keys.sh,
# because it is not how the machine is reached but how it signs as the person
# whose accounts it works from: claude-dotfiles' .gitconfig points git at
# ~/.ssh/claude.pub, and register-signing-key.sh puts the public half on the
# GitHub account that has to accept the signature.
#
# Only the private key is asked for — its public half is derived, so there is
# one thing to paste, and deriving it doubles as validation: a truncated or
# mangled paste fails before anything lands in ~/.ssh.
#
# The allowed_signers git verifies against is written here rather than tracked
# in the repo. The same key on every machine would make a tracked copy correct,
# but writing it locally costs nothing and keeps a credential-shaped file out of
# public history.
#
# Safe to re-run: an existing key is left alone unless you say otherwise.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
signing_key="$HOME/.ssh/claude"
allowed_signers="$HOME/.ssh/allowed_signers"

if [ ! -t 0 ]; then
  echo "signing-key.sh needs a terminal to prompt for a paste — run it directly." >&2
  exit 0
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ]
}

signer_identity() {
  # The principal has to be the address the commits are authored under, or the
  # signature verifies against nothing.
  git config --get user.email || echo "$(id -un)@$(hostname)"
}

# The trust list is a plain file here, not the symlink into the repo earlier
# versions installed — writing through that link would commit a line derived
# from a private key to public history.
unlink_tracked_allowed_signers() {
  if [ -L "$allowed_signers" ]; then
    rm -f "$allowed_signers"
    echo "unlinked $allowed_signers from the copy in the repo"
  fi
}

# Drops the line for a key that is about to be replaced, so the trust list does
# not collect keys this machine no longer holds. Pasting the same key onto
# every VM makes this a no-op; replacing one is when it earns its keep.
forget_signer() {
  local key="$1"

  [ -f "$allowed_signers" ] || return 0

  local kept
  kept="$(mktemp)"
  grep -vF "$key" "$allowed_signers" >"$kept" || true
  mv "$kept" "$allowed_signers"
  chmod 644 "$allowed_signers"
}

trust_signer() {
  [ -f "$signing_key.pub" ] || return 0

  local line
  line="$(signer_identity) $(awk '{print $1" "$2}' "$signing_key.pub")"

  if [ -f "$allowed_signers" ] && grep -qxF "$line" "$allowed_signers"; then
    return 0
  fi

  printf '%s\n' "$line" >>"$allowed_signers"
  chmod 644 "$allowed_signers"

  echo "trusted the signing key in $allowed_signers"
}

# Reads pasted lines until the private key's END marker, or until EOF (ctrl-D).
read_private_key() {
  local line block=""

  while IFS= read -r line; do
    block+="$line"$'\n'
    if [[ "$line" == *END*"PRIVATE KEY"* ]]; then
      break
    fi
  done

  printf '%s' "$block"
}

install_signing_key() {
  unlink_tracked_allowed_signers

  if [ -f "$signing_key" ] && ! confirm "$signing_key already exists. Replace it?"; then
    echo "keeping the existing signing key"
    trust_signer
    return
  fi

  echo
  echo "Paste the private signing key, including the BEGIN and END lines."
  echo "It ends by itself at the END line; ctrl-D also works."
  echo

  local pasted
  pasted="$(read_private_key)"

  if [ -z "${pasted//[[:space:]]/}" ]; then
    echo "nothing pasted — skipping the signing key" >&2
    return
  fi

  local staged
  staged="$(mktemp)"
  chmod 600 "$staged"
  # Command substitution above ate the trailing newline, and an OpenSSH private
  # key is rejected without one.
  printf '%s\n' "$pasted" >"$staged"

  # Deriving the public half doubles as validation: a truncated or mangled
  # paste fails here, before anything lands in ~/.ssh.
  local derived
  if ! derived="$(ssh-keygen -y -f "$staged" 2>&1)"; then
    rm -f "$staged"
    echo "that is not a usable private key:" >&2
    echo "  $derived" >&2
    return 1
  fi

  if [ -f "$signing_key.pub" ]; then
    forget_signer "$(awk '{print $1" "$2}' "$signing_key.pub")"
  fi

  mv "$staged" "$signing_key"
  chmod 600 "$signing_key"
  printf '%s\n' "$derived" >"$signing_key.pub"
  chmod 644 "$signing_key.pub"

  echo "installed $signing_key and derived its .pub"

  trust_signer
}

if ! install_signing_key; then
  echo
  echo "The signing key was not installed. Re-run to try again." >&2
  exit 1
fi

if [ -f "$signing_key.pub" ]; then
  cat <<EOF

The signing key, public half:

$(sed 's/^/    /' "$signing_key.pub")

This machine already trusts it. GitHub is the other half — usually already done
for a key you carried in, and checked rather than assumed:
EOF

  # Pasting a key here after install.sh has already run leaves install.sh having
  # registered the key this one replaces, so the attempt belongs on both paths.
  "$repo/register-signing-key.sh" "$signing_key.pub"

  cat <<'EOF'

Locally, check signing works with:

    git commit --allow-empty -m test && git log --format='%G?' -1
EOF
fi
