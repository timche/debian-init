#!/bin/bash

# The Claude Code overlay: the half of the provisioning that needs a GitHub or
# an Anthropic account. setup.sh leaves a working Debian box; this is what
# turns that box into the one Claude Code runs on.
#
# The second entry point, and the only one that is optional. provision.sh runs
# it when asked to, and running it by hand against a box setup.sh already built
# is the other way in — it is also what you rerun when a token expires.
#
# Nothing here is fatal but a fumbled signing-key paste. Everything else it
# installs is an account, and an account can be sorted out later.
#
# Safe to re-run: logins already in place are left alone, and the dotfiles
# clone is pulled rather than recloned.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

distro="$(. /etc/os-release && echo "$ID")"
if [ "$distro" != debian ]; then
  echo "unsupported distribution: $distro (expected debian)" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "claude.sh runs as the user it is setting up, not as root — the logins" >&2
  echo "and everything they fetch land in \$HOME. On a bare VM start with" >&2
  echo "'provision.sh claude' instead, which creates the account and calls this" >&2
  echo "from it." >&2
  exit 1
fi

architecture="$(dpkg --print-architecture)"

# The packages the generic half has no caller for. github-cli publishes one
# tree for every release, so unlike docker's and tailscale's sources this one
# is not keyed on the codename.
sudo install -d -m 0755 /etc/apt/keyrings

sudo curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
sudo chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$architecture signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

# unzip is what bun's installer extracts with and jq is what the settings.json
# hooks parse and login.sh patches ~/.claude.json with — neither is obvious
# from its name. glow renders the markdown claude-dotfiles' preview-markdown
# skill puts in front of the user; Debian ships the current release, and the
# version is the same on every machine, so apt owns it rather than mise.
#
# zsh is installed but not switched to. Making it the login shell before
# ~/.zshrc exists drops the next interactive login into zsh-newuser-install,
# and that file comes from claude-dotfiles — so the shell and its config are
# turned on together, by the installer that carries both.
sudo apt-get update
sudo apt-get install -y gh glow jq unzip zsh zsh-syntax-highlighting

"$repo/claude/install.sh"

# After install.sh, which cannot reach the private dotfiles until this has put
# a token on the machine, and reruns itself from here once it has. Needs a
# terminal for the browser flows.
if [ -t 0 ]; then
  "$repo/claude/login.sh"
else
  echo
  echo "Skipped login.sh — no terminal. Run $repo/claude/login.sh to log in to"
  echo "GitHub and Claude Code, and to fetch the dotfiles."
fi

signing_failed=0

# After login.sh, because the principal this writes into allowed_signers is the
# user.email out of the .gitconfig only the dotfiles carry. Prompts for a
# paste, so there has to be a terminal to prompt at.
if [ -t 0 ]; then
  "$repo/claude/signing-key.sh" || signing_failed=1
else
  echo
  echo "Skipped signing-key.sh — no terminal. Run $repo/claude/signing-key.sh"
  echo "to install the commit-signing key."
fi

echo
echo "Claude Code side done. What is left:"
echo

# Still not logged in means login.sh was skipped or did not finish, and with it
# the dotfiles and the Claude Code login: the account is still on bash with
# nothing but Debian's rc.
if ! gh auth status >/dev/null 2>&1; then
  echo "  - $repo/claude/login.sh — GitHub and Claude Code, and the rerun that"
  echo "    fetches the dotfiles in between."
else
  # claude arrives with the dotfiles, in ~/.local/bin, which this shell has no
  # reason to have on PATH.
  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v claude >/dev/null 2>&1; then
    echo "  - $repo/claude/install.sh — it did not get as far as installing"
    echo "    claude."
  elif ! claude auth status >/dev/null 2>&1; then
    echo "  - claude auth login — $repo/claude/login.sh tried and did not get"
    echo "    there."
  fi
fi

# The dotfiles installer is what makes zsh the login shell, so this line belongs
# to the overlay rather than to setup.sh, which no longer installs zsh at all.
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$SHELL" ]; then
  echo "  - Log out and back in for the login shell the dotfiles set."
fi

exit "$signing_failed"
