#!/bin/bash

# The per-user half of the run: everything from a working account onwards. See
# README.md for the steps that stay manual.
#
# Not an entry point. provision.sh is, and it runs as root because a VM arrives
# with nothing else — it creates the account and calls this as it. Rerunning
# this by hand from the clone is fine and is how you pick up a change; running
# it as root is not, since every path here belongs to one user.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "setup.sh runs as the user it is setting up, not as root — everything" >&2
  echo "here lands in \$HOME. On a bare VM start with provision.sh instead," >&2
  echo "which creates the account and calls this from it." >&2
  exit 1
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$repo/bootstrap-system.sh"
"$repo/install.sh"

# Before keys.sh, because that reads user.email out of the .gitconfig only the
# dotfiles carry, and login.sh is what fetches them. Both need a terminal for
# their browser flows.
if [ -t 0 ]; then
  "$repo/login.sh"
  "$repo/tailscale.sh"
else
  echo
  echo "Skipped login.sh and tailscale.sh — no terminal. Run $repo/login.sh to"
  echo "log in to GitHub and Claude Code and fetch the dotfiles, and"
  echo "$repo/tailscale.sh to put the machine on the tailnet."
fi

keys_failed=0

# Prompts for a paste, so there has to be a terminal to prompt at.
if [ -t 0 ]; then
  "$repo/keys.sh" || keys_failed=1
else
  echo
  echo "Skipped keys.sh — no terminal. Run $repo/keys.sh to install the SSH keys."
fi

# Last, because it is the step that turns password logins off. It skips itself
# when there is no authorized_keys yet, rather than locking you out.
"$repo/harden-ssh.sh"

echo
echo "Done. What is left:"
echo

# Still not logged in means login.sh was skipped or did not finish, and with it
# the dotfiles and the Claude Code login: the account is still on bash with
# nothing but Debian's rc.
if ! gh auth status >/dev/null 2>&1; then
  echo "  - $repo/login.sh — GitHub and Claude Code, and the rerun that fetches"
  echo "    the dotfiles in between."
else
  # claude arrives with the dotfiles, in ~/.local/bin, which this shell has no
  # reason to have on PATH.
  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v claude >/dev/null 2>&1; then
    echo "  - $repo/install.sh — it did not get as far as installing claude."
  elif ! claude auth status >/dev/null 2>&1; then
    echo "  - claude auth login — $repo/login.sh tried and did not get there."
  fi
fi

# Its own if rather than part of the cascade above: tailscale is a browser flow
# that fails on its own, and the GitHub login says nothing about it.
if ! tailscale status >/dev/null 2>&1; then
  echo "  - sudo tailscale up — $repo/tailscale.sh tried and did not get there."
fi

cat <<'EOF'
  - Log out and back in so the docker group and the zsh login shell take hold.
EOF

# tailscale.sh advertises tailscale ssh, and that is as far as a machine can
# take it: who may use it is tailnet policy, and tailscaled answers those
# sessions itself, so nothing in the sshd drop-in applies to them.
if tailscale status >/dev/null 2>&1; then
  cat <<'EOF'
  - Add an ssh rule for this machine in the tailscale admin console. It
    advertises ssh but nobody can use it until the policy allows it — and that
    policy is what governs the tailscale way in, not the sshd hardening.
EOF
fi

exit "$keys_failed"
