#!/bin/bash

# Assertions against a machine that setup.sh has just finished with — the
# generic half only, with assert-claude.sh covering the overlay. Runs inside
# the test container as the unprivileged user; see run.sh.
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

# This repo is public and holds no personal configuration at all — the shell,
# the runtimes and ~/.claude all come from the private one. A stray dot
# directory here would be a leak.
check "no personal config in this repo" \
  '! find "$HOME/debian-init" \( -name .claude -o -name home \) -not -path "*/.git/*" | grep -q .'

# Nothing in the generic half has an opinion about the shell: the account keeps
# whatever provision.sh created it with, and no rc file of this repo's comes
# with it.
check "login shell is left alone" 'getent passwd "$USER" | cut -d: -f7 | grep -qv zsh'
check "no rc file was planted"    '[ ! -e "$HOME/.zshrc" ]'
check "the stock .bashrc is untouched" \
  '[ -f "$HOME/.bashrc" ] && [ ! -e "$HOME/.bashrc.backup" ]'

# System side.
check "user is in docker group" 'id -nG "$USER" | tr " " "\n" | grep -qx docker'
check "user is in sudo group"   'id -nG "$USER" | tr " " "\n" | grep -qx sudo'
check "docker installed"        'command -v docker'
check "tailscale installed"     'command -v tailscale'
check "btop installed"          'command -v btop'
check "ssh-keygen installed"    'command -v ssh-keygen'
check "sshd installed"          '[ -x /usr/sbin/sshd ]'
check "daemon.json installed"   'grep -q 127.0.0.1 /etc/docker/daemon.json'
check "unattended-upgrades switched on" \
  'grep -q "Unattended-Upgrade \"1\"" /etc/apt/apt.conf.d/20auto-upgrades'

# harden-ssh.sh holds the drop-in back until there is a key to log in with, so
# which half of this is asserted depends on whether run.sh has seeded one yet.
# Both halves matter: the refusal is what keeps a fresh VM reachable. The test
# is the one harden-ssh.sh gates on, not -s, or a file of unusable lines sends
# this down the wrong half.
if ssh-keygen -l -f "$HOME/.ssh/authorized_keys" >/dev/null 2>&1; then
  check "sshd drop-in names this user" \
    'grep -qx "AllowUsers $USER" /etc/ssh/sshd_config.d/10-hardening.conf'
  check "sshd drop-in kept no placeholder" \
    '[ -f /etc/ssh/sshd_config.d/10-hardening.conf ] && ! grep -q __USER__ /etc/ssh/sshd_config.d/10-hardening.conf'
  check "sshd drop-in disables passwords" \
    'grep -qx "PasswordAuthentication no" /etc/ssh/sshd_config.d/10-hardening.conf'
  # Whether sshd will parse it is asserted from root in run.sh — reading the
  # host keys needs privileges this user may no longer have.
  check "sshd drop-in belongs to root" \
    '[ "$(stat -c "%U %a" /etc/ssh/sshd_config.d/10-hardening.conf)" = "root 644" ]'
  check "authorized_keys is not group or world readable" \
    '[ "$(stat -c %a "$HOME/.ssh/authorized_keys")" = 600 ]'
  check "authorized_keys belongs to this user" \
    '[ "$(stat -c %U "$HOME/.ssh/authorized_keys")" = "$USER" ]'
else
  check "no drop-in until there is a key to log in with" \
    '[ ! -f /etc/ssh/sshd_config.d/10-hardening.conf ]'
  check "harden-ssh.sh refuses rather than failing the run" \
    '"$HOME/debian-init/harden-ssh.sh"'
fi

# keys.sh prompts for a paste. If it ever stops bailing out without a terminal,
# setup.sh blocks forever here instead of finishing.
check "keys.sh exits without a terminal" \
  '"$HOME/debian-init/keys.sh" < /dev/null'

# Same again for tailscale.sh, which drives a browser flow and would sit on it
# forever. timeout, because the failure mode is a hang and not an exit status.
check "tailscale.sh exits without a terminal" \
  'timeout 30 "$HOME/debian-init/tailscale.sh" < /dev/null'

if [ "$failures" -gt 0 ]; then
  echo "  $failures check(s) failed"
  exit 1
fi
