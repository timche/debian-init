#!/bin/bash

# Assertions against a machine claude.sh has just finished with. Runs inside
# the test container as the unprivileged user; see run.sh, and assert.sh for
# the generic half this sits on top of.
#
# A container has no authenticated gh, so claude.sh gets as far as its packages
# and no further: the dotfiles are never cloned, nothing is ever logged in, and
# what is asserted here is the half that works without an account. The other
# half is covered by CI in claude-dotfiles.
#
# To add a case, add a check line: a description and a shell snippet that
# exits non-zero when the expectation is not met.

set -uo pipefail

failures=0

check() {
  local description="$1" snippet="$2"

  if bash -c "$snippet" >/dev/null 2>&1; then
    echo "  ok    $description"
  else
    echo "  FAIL  $description"
    failures=$((failures + 1))
  fi
}

check "gh installed"    'command -v gh'
check "zsh installed"   'command -v zsh'
check "unzip installed" 'command -v unzip'
check "glow installed"  'command -v glow'
check "jq installed"    'command -v jq'

# zsh is installed but not switched to: claude-dotfiles owns that, because it
# owns the .zshrc without which the next login hits zsh-newuser-install. Those
# dotfiles are the part a container never reaches, so here both stay as they
# were.
check "login shell is left alone" 'getent passwd "$USER" | cut -d: -f7 | grep -qv zsh'
check "no rc file was planted"    '[ ! -e "$HOME/.zshrc" ]'

# Nothing is logged in here, which is the state every fresh VM is in. Each of
# these has to skip out of that rather than fail the run — or, worse, sit on a
# prompt. timeout on the one driving browser flows, because that failure mode
# is a hang and not an exit status.
check "login.sh exits without a terminal" \
  'timeout 30 "$HOME/debian-init/claude/login.sh" < /dev/null'
check "signing-key.sh exits without a terminal" \
  '"$HOME/debian-init/claude/signing-key.sh" < /dev/null'
check "register-signing-key.sh skips when gh cannot help" \
  '"$HOME/debian-init/claude/register-signing-key.sh"'

if [ "$failures" -gt 0 ]; then
  echo "  $failures check(s) failed"
  exit 1
fi
