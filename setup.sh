#!/bin/bash

# The per-user half of the run, and the whole of the machine: packages, docker,
# tailscale, the keys it is reachable with, and a hardened sshd. What it leaves
# is a box that is worth having without an account on it anywhere.
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

keys_failed=0

# Prompts for a paste, so there has to be a terminal to prompt at.
if [ -t 0 ]; then
  "$repo/keys.sh" || keys_failed=1
else
  echo
  echo "Skipped keys.sh — no terminal. Run $repo/keys.sh to install the SSH keys."
fi

# Called either way: an auth key in TS_AUTHKEY is enough on its own, and
# without one it is the script that decides whether there is a terminal to ask
# at.
"$repo/tailscale.sh"

# Last, because it is the step that turns password logins off. It skips itself
# when there is no authorized_keys yet, rather than locking you out.
"$repo/harden-ssh.sh"

echo
echo "Done. What is left:"
echo

if ! tailscale status >/dev/null 2>&1; then
  echo "  - sudo tailscale up — $repo/tailscale.sh tried and did not get there."
fi

cat <<'EOF'
  - Log out and back in so the docker group takes hold.
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
