#!/bin/bash

# Put the machine on the tailnet, advertising SSH. A step of its own rather
# than part of setup.sh: it is the one thing here that wants a credential from
# outside the machine, and it is what you rerun when it was skipped or the node
# was logged out.
#
# --ssh has tailscaled answer SSH on the tailnet itself. That is a second way
# in, one that survives losing the key sshd wants or the provider's firewall
# closing over port 22 — and it is why harden-ssh.sh can be as strict as it is.
#
# An auth key rather than the browser flow, which is what tailscale recommends
# for a server, and the only form a run with nobody at the keyboard can use.
# Generate it tagged: a tagged node's key does not expire, and an untagged
# server drops off the tailnet when its own does.
#
# Not fatal. By the time this runs the machine is built; what is missing is a
# tailnet to put it on, and that can be sorted out later.
#
# Safe to re-run: a machine already up stays on the tailnet.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The name tailscale's own documentation uses. provision.sh hands it through
# su, for a run with nobody watching.
auth_key="${TS_AUTHKEY:-}"

if [ ! -d /run/systemd/system ]; then
  echo "no init to run tailscaled under — skipping tailscale"
  exit 0
fi

if tailscale status >/dev/null 2>&1; then
  echo "tailscale is already up"

  # It may well be up from before this script advertised SSH. set is how you
  # turn it on afterwards without taking the machine off the tailnet first.
  sudo tailscale set --ssh ||
    echo "could not advertise ssh — run 'sudo tailscale set --ssh'" >&2

  exit 0
fi

if [ -z "$auth_key" ] && [ ! -t 0 ]; then
  echo "no TS_AUTHKEY and no terminal to ask at — skipping tailscale. Run" >&2
  echo "$repo/tailscale.sh to put the machine on the tailnet." >&2
  exit 0
fi

if [ -z "$auth_key" ]; then
  cat <<'EOF'

Bringing tailscale up, advertising SSH. Paste an auth key from the admin
console — a tagged one, so the node does not expire off the tailnet.

Enter on an empty line falls back to the browser flow.

EOF

  while :; do
    read -r -p "auth key> " auth_key || break
    [ -n "$auth_key" ] || break

    # A half-selected paste otherwise comes back as a tailscale error that
    # does not say which of the two things went wrong.
    [[ "$auth_key" == tskey-* ]] && break

    echo "  that does not look like an auth key; they start with 'tskey-'." >&2
  done
fi

# Advertising is all any of this does. Nothing connects until the tailnet
# policy has an ssh rule for the machine, which is a console job; and that
# policy, not 10-hardening.conf, is what governs the tailscale path, since sshd
# never sees it. setup.sh says so at the end of the run.
if [ -n "$auth_key" ]; then
  # Passed inline, the key would sit in the process list for the length of the
  # call, which /proc shows to every user on the box. The file: form is in
  # 'tailscale up --help' rather than the documentation.
  staged="$(mktemp)"
  trap 'rm -f "$staged"' EXIT
  printf '%s\n' "$auth_key" >"$staged"

  sudo tailscale up --ssh --auth-key="file:$staged" ||
    echo "tailscale up did not finish — rerun $repo/tailscale.sh to try again" >&2
else
  cat <<'EOF'

No key, so the browser flow it is. There is no browser on this box, so
tailscale prints a URL to open on whichever machine has one.

EOF

  sudo tailscale up --ssh ||
    echo "tailscale up did not finish — rerun $repo/tailscale.sh to try again" >&2
fi
