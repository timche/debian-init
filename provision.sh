#!/bin/bash

# The entry point a bare VM has, and the only one that runs as root. A VM
# arrives the way a provider hands it over — root over SSH, no unprivileged
# account yet — so the run has to start as root whether or not the account
# already exists.
#
#   curl -fsSL https://raw.githubusercontent.com/timche/debian-init/main/provision.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/timche/debian-init/main/provision.sh | bash -s claude
#
# The first leaves a plain Debian box; the second puts Claude Code on top of
# it.
#
# It asks what the account should be called, creates it, gives it the keys root
# is already reachable with, and hands everything else to setup.sh running as it
# — then to claude.sh, if that is what was asked for. The overlay does not ask:
# claude-dotfiles hardcodes the name, so a Claude run is always `claude`. Nothing here duplicates either of them: this is
# the part that cannot be done from inside the account it is creating, which is
# why it is short and setup.sh is not.
#
# Safe to re-run: an existing user is reused, and keys are merged rather than
# replaced.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

repo_url="${DEBIAN_INIT_REPO:-https://github.com/timche/debian-init.git}"

# Asked for below unless the environment or the overlay settles it. The name a
# provider's own Debian image uses, so it is the least surprising thing to land
# on when nobody answers.
default_user=debian

# Extra keys to authorize, one per line, for runs with nobody at the keyboard.
extra_keys="${SSH_PUBLIC_KEYS:-}"

root_keys=/root/.ssh/authorized_keys
sudoers_drop_in="/etc/sudoers.d/90-debian-init-provision"

# The overlay is opt-in, and the argument is the whole of the interface to it.
# Anything else is refused rather than ignored: a typo that quietly provisions
# a machine without the half you asked for is worse than one that stops.
overlay=false

if [ "$#" -gt 0 ]; then
  if [ "$#" -eq 1 ] && [ "$1" = claude ]; then
    overlay=true
  else
    echo "usage: provision.sh [claude]" >&2
    echo "'claude' asks for the Claude Code overlay on top of the machine;" >&2
    echo "there is no other argument." >&2
    exit 1
  fi
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "provision.sh has to run as root — it creates the user, authorizes keys" >&2
  echo "and lends itself sudo for the run. Log in as root and start again." >&2
  exit 1
fi

distro="$(. /etc/os-release && echo "$ID")"
if [ "$distro" != debian ]; then
  echo "unsupported distribution: $distro (expected debian)" >&2
  exit 1
fi

# The account

# Under the documented curl install stdin is the pipe feeding this script, so a
# prompt on it would never be seen and an answer never typed. The terminal
# itself is the one to ask at, when there is one.
if (exec </dev/tty) 2>/dev/null; then
  prompt=/dev/tty
elif [ -t 0 ]; then
  prompt=/dev/stdin
else
  prompt=""
fi

# useradd's own rule, near enough: what sshd, sudo and every path built from
# $HOME will accept without argument.
usable_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$1" != root ]
}

user="${DEBIAN_INIT_USER:-}"

# claude-dotfiles hardcodes the name, so the overlay has only one answer and
# asking would be a question with a wrong answer available.
if [ -z "$user" ] && [ "$overlay" = true ]; then
  user=claude
fi

if [ -z "$user" ] && [ -n "$prompt" ]; then
  echo
  echo "The account to create and hand the machine to. It gets sudo, docker and"
  echo "the keys root is reachable with."
  echo

  while :; do
    read -r -p "account [$default_user]> " user <"$prompt" || user=""
    user="${user:-$default_user}"

    usable_name "$user" && break

    echo "  not a usable account name; lowercase, starting with a letter." >&2
    user=""
  done
fi

user="${user:-$default_user}"

if ! usable_name "$user"; then
  echo "unusable account name: $user" >&2
  exit 1
fi

# A run killed outright — SIGKILL, a reboot, the VM pulled out from under it —
# never reaches the trap that takes the sudo grant at the end back out, and what
# it leaves behind is a standing passwordless sudo. Clearing it up front is what
# makes the re-run heal that rather than step over it.
rm -f "$sudoers_drop_in"

# Enough to create the user and clone the repo. bootstrap-system.sh, running
# later as the user, is what installs the rest.
apt-get update
apt-get install -y ca-certificates curl git openssh-client sudo

# User

if ! id -u "$user" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$user"
  echo "created $user"
fi

usermod -aG sudo "$user"

home="$(getent passwd "$user" | cut -d: -f6)"

# useradd leaves the account locked, so sudo has nothing to authenticate
# against later. Group membership alone is useless without this.
#
# Generated rather than asked for, and printed at the end of the run: that is
# the only copy, so a headless provision ends with a usable sudo too.
#
# Empty unless this run set one, which is what the closing block keys off.
generated_password=""

set_password() {
  # head takes a fixed count and exits on its own, so nothing in the pipeline
  # dies of SIGPIPE and trips pipefail.
  local candidate
  candidate="$(head -c 18 /dev/urandom | base64)"

  if printf '%s:%s\n' "$user" "$candidate" | chpasswd; then
    generated_password="$candidate"
  else
    echo "warning: no password set. Run 'passwd $user' before relying on sudo." >&2
  fi
}

if [ "$(passwd -S "$user" | awk '{print $2}')" != P ]; then
  set_password
elif [ -n "$prompt" ]; then
  echo
  read -r -p "$user already has a password. Replace it with a generated one? [y/N] " \
    answer <"$prompt"
  if [ "$answer" = y ] || [ "$answer" = Y ]; then
    set_password
  fi
fi

# SSH keys

# The directory has to be user-owned either way, or the VM cannot write
# known_hosts, which breaks git over SSH from inside it.
install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"

authorized_keys="$home/.ssh/authorized_keys"
staged="$(mktemp)"
trap 'rm -f "$staged" "$staged.one"' EXIT

# Whatever is already there stays: cloud-init's key, or a previous run's.
[ -f "$authorized_keys" ] && cat "$authorized_keys" >>"$staged"
[ -s "$root_keys" ] && cat "$root_keys" >>"$staged"
[ -n "$extra_keys" ] && printf '%s\n' "$extra_keys" >>"$staged"

collect_keys() {
  grep -Ev '^[[:space:]]*(#|$)' "$staged" | sort -u >"$staged.one" || true
  mv "$staged.one" "$staged"
}

collect_keys

# Nothing to inherit and someone is watching, so ask rather than quietly leave
# the account unreachable.
if [ ! -s "$staged" ] && [ -n "$prompt" ]; then
  echo
  echo "No SSH public key found for $user, and root has none to inherit."
  echo "Paste one, e.g. 'ssh-ed25519 AAAA... tim@macbook'."
  echo "Enter on an empty line moves on."

  while :; do
    read -r -p "key> " pasted <"$prompt" || break
    [ -n "$pasted" ] || break

    printf '%s\n' "$pasted" >"$staged.one"

    if ssh-keygen -l -f "$staged.one" >/dev/null 2>&1; then
      cat "$staged.one" >>"$staged"
      echo "  ok — paste another, or Enter to move on."
    else
      echo "  that does not parse as a public key; try again." >&2
    fi

    rm -f "$staged.one"
  done

  collect_keys
fi

if [ -s "$staged" ]; then
  # install(1) sets owner and mode as it creates, so the file is never
  # world-readable in between.
  install -m 0600 -o "$user" -g "$user" "$staged" "$authorized_keys"
  echo "authorized $(wc -l <"$authorized_keys") key(s) for $user"
else
  # setup.sh reaches keys.sh later, and harden-ssh.sh holds off until then.
  echo "no keys authorized yet for $user — keys.sh will ask"
fi

# The repo

target="${DEBIAN_INIT_DIR:-$home/debian-init}"

if [ -d "$target/.git" ]; then
  sudo -u "$user" git -C "$target" pull --ff-only
else
  sudo -u "$user" git clone "$repo_url" "$target"
fi

# Hand over

# Both halves sudo their way through a long apt run as $user, and the password
# just set would expire out of sudo's timestamp partway through. Lift the
# requirement for the length of this run only — the trap goes on first, so a
# rejected sudoers file cannot leave a standing grant behind.
trap 'rm -f "$staged" "$staged.one" "$sudoers_drop_in"' EXIT

cat >"$sudoers_drop_in" <<EOF
$user ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "$sudoers_drop_in"
visudo -cf "$sudoers_drop_in" >/dev/null

# A machine that has been through this once may have had its login shell
# changed from under it, and a second run would hand these to a shell whose rc
# files expect a terminal. -s keeps it bash.
#
# stdin may also be the curl pipe feeding this script, so pass the real
# terminal along — the key prompts and the browser flows have nowhere to go
# otherwise.
#
# su - clears the environment, so every knob the halves read has to be named
# here or it silently does nothing when the run starts from this end. -w rather
# than an assignment in the command, which would put a tailscale auth key in the
# command line for every user on the box to read out of /proc.
knobs=TS_AUTHKEY,FORCE_HARDEN,CLAUDE_DOTFILES_REPO,CLAUDE_DOTFILES_DIR

run_as_user() {
  if (exec </dev/tty) 2>/dev/null; then
    su -w "$knobs" - "$user" -s /bin/bash -c "$1" </dev/tty
  else
    su -w "$knobs" - "$user" -s /bin/bash -c "$1"
  fi
}

# A fumbled paste is enough to make either half exit non-zero, and under set -e
# that would take the closing block with it — including the generated password,
# which nothing else has a copy of. Carry the status to the end instead.
run_failed=0

run_as_user "$target/setup.sh" || run_failed=1

if [ "$overlay" = true ]; then
  run_as_user "$target/claude.sh" || run_failed=1
fi

# claude comes with the overlay, so asking a generic box for its version only
# produces a command not found that reads as a failed provision.
verify="sudo -v && docker ps"
if [ "$overlay" = true ]; then
  verify="$verify && claude --version"
fi

cat <<EOF

Provisioned. Before closing this session, from a second terminal:

    ssh $user@<host>
    $verify

One more thing worth knowing: docker writes its own iptables rules and goes
around a host firewall, so a firewall at the provider is the one that counts.
EOF

# Last, so the one thing this run produced and cannot show again is still on
# screen. The signing key was pasted in, not made here, so signing-key.sh
# printing it once is enough.

if [ -n "$generated_password" ]; then
  cat <<EOF

Password for $user, generated and shown once — sudo wants it, and nothing
else has a copy:

    $generated_password
EOF
fi

# After the password, so a half that failed is the last thing said and the one
# thing worth keeping is still above it.
if [ "$run_failed" -ne 0 ]; then
  echo
  echo "One of the halves did not finish — read back for which, and rerun it" >&2
  echo "from $target." >&2
fi

exit "$run_failed"
