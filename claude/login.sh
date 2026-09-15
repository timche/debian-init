#!/bin/bash

# The account logins that need a browser: GitHub and Claude Code. Split out of
# claude.sh because both want a person at the keyboard, and kept a script of
# its own because it is what you rerun when one was skipped or has since
# expired. The tailnet is the machine's business rather than an account's, so
# tailscale.sh stays in the generic half.
#
# Neither of them is fatal. By the time this runs the machine is built; what is
# missing is an account on it, and that can be sorted out later.
#
# Safe to re-run: a login already in place is left alone.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -t 0 ]; then
  echo "login.sh needs a terminal for the browser flows — run it directly." >&2
  exit 0
fi

# Whether the gh login happened here is what decides if install.sh has anything
# new to pick up at the end, so it has to be sampled before the attempt.
gh_was_authenticated=false
if gh auth status >/dev/null 2>&1; then
  gh_was_authenticated=true
fi

# GitHub

if [ "$gh_was_authenticated" = true ]; then
  echo "gh is already authenticated"
else
  cat <<'EOF'

Logging in to GitHub. There is no browser on this box, so gh prints a code and
a URL to open on whichever machine has one.

EOF

  # write:ssh_signing_key is not in the default set and the interactive flow
  # never offers it, so asking here is what saves a later 'gh auth refresh'
  # before register-signing-key.sh can do anything. https because that is how
  # this repo and its private half are cloned; asking also skips the prompt.
  gh auth login --hostname github.com --git-protocol https --web \
    --scopes write:ssh_signing_key ||
    echo "gh login did not finish — rerun $repo/login.sh to try again" >&2
fi

# install.sh skipped its gh-authenticated half on the way here — the gh-stack
# extension, the signing key, the private dotfiles. It is idempotent, and this
# is the pass that picks them up. Only worth it if this run is what logged in;
# otherwise the earlier pass already had everything it needed.
if [ "$gh_was_authenticated" = false ] && gh auth status >/dev/null 2>&1; then
  echo
  echo "gh is logged in now — rerunning install.sh for the parts that needed it."
  echo

  "$repo/install.sh"
fi

# Claude Code

# Last, because claude arrives with the dotfiles the rerun above fetches, and it
# lands in ~/.local/bin, which this shell has no reason to have on PATH.
export PATH="$HOME/.local/bin:$PATH"

if ! command -v claude >/dev/null 2>&1; then
  echo "claude is not installed, so it was not logged in — it comes with the" >&2
  echo "dotfiles, so sort those out and rerun $repo/login.sh" >&2
elif claude auth status >/dev/null 2>&1; then
  echo "claude is already authenticated"
else
  cat <<'EOF'

Logging in to Claude Code. Same as the others: a URL to open on whichever
machine has a browser.

EOF

  claude auth login ||
    echo "claude login did not finish — rerun $repo/login.sh to try again" >&2
fi

# The credential is only half of it: the TUI gates its first run on setup state
# kept separately in ~/.claude.json, which no amount of `claude auth login`
# writes. Without this the first interactive claude walks its first-launch
# setup, and the opening screen of that is the login one all over again.
#
# hasCompletedOnboarding is not a documented setting, so this is written to
# fall through quietly rather than fail the run: the cost of it going stale is
# one login prompt, which is where we were anyway.
config="$HOME/.claude.json"

if claude auth status >/dev/null 2>&1 && [ -f "$config" ]; then
  # Alongside the file rather than in /tmp, so the replacement is a rename on
  # the same filesystem and never a half-written config.
  patched="$(mktemp "$config.XXXXXX")"

  if jq '.hasCompletedOnboarding = true' "$config" >"$patched"; then
    mv "$patched" "$config"
  else
    rm -f "$patched"
    echo "could not mark first-launch setup done in $config — the first" >&2
    echo "interactive claude will ask to log in again" >&2
  fi
fi
