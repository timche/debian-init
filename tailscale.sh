#!/bin/bash

# Put the machine on the tailnet, advertising SSH. A browser flow like the
# account logins, so it is a script of its own rather than part of setup.sh:
# this is what you rerun when it was skipped or the machine has since been
# logged out.
#
# --ssh has tailscaled answer SSH on the tailnet itself. That is a second way
# in, one that survives losing the key sshd wants or the provider's firewall
# closing over port 22 — and it is why harden-ssh.sh can be as strict as it is.
#
# Not fatal. By the time this runs the machine is built; what is missing is a
# tailnet to put it on, and that can be sorted out later.
#
# Safe to re-run: a machine already up stays on the tailnet.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -t 0 ]; then
  echo "tailscale.sh needs a terminal for the browser flow — run it directly." >&2
  exit 0
fi

# Advertising is all this does. Nothing connects until the tailnet policy has
# an ssh rule for the machine, which is a console job; and that policy, not
# 10-hardening.conf, is what governs the tailscale path, since sshd never sees
# it. setup.sh says so at the end of the run.
if [ ! -d /run/systemd/system ]; then
  echo "no init to run tailscaled under — skipping tailscale"
elif tailscale status >/dev/null 2>&1; then
  echo "tailscale is already up"

  # It may well be up from before this script advertised SSH. set is how you
  # turn it on afterwards without taking the machine off the tailnet first.
  sudo tailscale set --ssh ||
    echo "could not advertise ssh — run 'sudo tailscale set --ssh'" >&2
else
  cat <<'EOF'

Bringing tailscale up, advertising SSH. There is no browser on this box, so it
prints a URL to open on whichever machine has one.

EOF

  sudo tailscale up --ssh ||
    echo "tailscale up did not finish — rerun $repo/tailscale.sh to try again" >&2
fi
