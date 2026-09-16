#!/bin/bash

# Run both halves end to end in a throwaway container per image, then assert
# the result. Defaults to the release the repo claims to support.
#
#   test/run.sh                  # debian:13
#   test/run.sh debian:12        # another release
#   KEEP=1 test/run.sh           # leave the containers around to poke at
#
# Nothing here touches the machine it runs on; every change lands in the
# container.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
user=tester

images=("$@")
if [ ${#images[@]} -eq 0 ]; then
  images=(debian:13)
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker is not available" >&2
  exit 1
fi

# Third argument for the container that provisions its own account, which is
# named by provision.sh rather than by this script.
run_in_container() {
  local as="${3:-$user}"

  docker exec -u "$as" -e USER="$as" -e HOME="/home/$as" \
    -e DEBIAN_FRONTEND=noninteractive "$1" bash "/home/$as/debian-setup/$2"
}

start_container() {
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" -v "$repo:/repo:ro" -v "$git_common:$git_common:ro" \
    "$2" sleep 7200 >/dev/null
}

# provision.sh clones rather than copying, so its half of the suite sees the
# last commit and not the working tree.
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
  echo "note: uncommitted changes — the provision.sh stage tests HEAD without them"
fi

# In a worktree — which is where changes to this repo are made — .git is a file
# naming an absolute gitdir rather than a directory, and provision.sh's clone
# dies on a path the container knows nothing about. Mounting that directory at
# the path it is named by is what makes the pointer resolve. In a plain checkout
# it is $repo/.git and the mount is redundant.
git_common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"

# A key for provision.sh to authorize. The private half goes out with the
# temporary directory; nothing is meant to log in with it.
keydir="$(mktemp -d)"
trap 'rm -rf "$keydir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C provision-test -f "$keydir/key"
public_key="$(cat "$keydir/key.pub")"

# Root's own key, which the account must not end up with: a box this runs
# against may be reachable as root by someone the new account is not for.
ssh-keygen -q -t ed25519 -N '' -C root-test -f "$keydir/root"
root_public_key="$(cat "$keydir/root.pub")"

failed=0

for image in "${images[@]}"; do
  container="debian-setup-test-$(echo "$image" | tr ':/.' '---')"
  log="$(mktemp)"

  echo "==> $image"

  start_container "$container" "$image"

  # A fresh VM has a sudo-capable non-root user; the base images do not.
  docker exec -e DEBIAN_FRONTEND=noninteractive "$container" bash -c "
    set -e
    apt-get update -qq
    apt-get install -y -qq sudo passwd adduser >/dev/null
    useradd -m -s /bin/bash -G sudo $user
    echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user
    cp -r /repo /home/$user/debian-setup
    chown -R $user:$user /home/$user/debian-setup
  " >>"$log" 2>&1

  stage_failed=0

  # provision.sh is the entry point, so machine.sh has to turn root away: every
  # path in it lands in one user's $HOME, and root running it would scatter
  # them through /root.
  echo "--- machine.sh as root"
  if docker exec -e DEBIAN_FRONTEND=noninteractive "$container" \
    bash "/home/$user/debian-setup/machine.sh" >>"$log" 2>&1; then
    echo "  FAIL  machine.sh refuses to run as root"
    stage_failed=1
  else
    echo "  ok    machine.sh refuses to run as root"
  fi

  echo "--- machine.sh"
  if ! run_in_container "$container" machine.sh >>"$log" 2>&1; then
    echo "  FAIL  machine.sh exited non-zero"
    stage_failed=1
  fi

  if [ "$stage_failed" -eq 0 ]; then
    run_in_container "$container" test/assert.sh || stage_failed=1

    # The overlay, on top of the box machine.sh just built. No gh is ever logged
    # in here, so it gets as far as its packages and stops — and has to do that
    # with an exit status of zero.
    echo "--- claude.sh"
    if ! run_in_container "$container" claude.sh >>"$log" 2>&1; then
      echo "  FAIL  claude.sh exited non-zero"
      stage_failed=1
    else
      run_in_container "$container" test/assert-claude.sh || stage_failed=1
    fi

    # install.sh is documented as safe to re-run, so prove it.
    echo "--- claude/install.sh again"
    if run_in_container "$container" claude/install.sh >>"$log" 2>&1; then
      run_in_container "$container" test/assert-claude.sh || stage_failed=1
    else
      echo "  FAIL  install.sh is not idempotent"
      stage_failed=1
    fi

    # machine.sh skipped keys.sh for want of a terminal, so drive it under a pty
    # from bsdutils' script(1) — Essential, so it is on every Debian. A
    # throwaway key stands in for the paste, and the empty line after it ends
    # the list.
    echo "--- keys.sh"
    if docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      ssh-keygen -q -t ed25519 -N '' -C authorized -f /tmp/authorized
      { cat /tmp/authorized.pub; printf '\n'; } |
        script -qec /home/$user/debian-setup/keys.sh /dev/null
      grep -qFf /tmp/authorized.pub /home/$user/.ssh/authorized_keys
    " >>"$log" 2>&1; then
      echo "  ok    keys.sh installs a pasted authorized key"
    else
      echo "  FAIL  keys.sh installs a pasted authorized key"
      stage_failed=1
    fi

    # A second run with a key already in place must not go back to the paste
    # prompt: on a fresh VM provision.sh has just asked for one, and machine.sh
    # reaching keys.sh straight after is what made that two asks for the same
    # key. Enter alone takes the default, and the file has to come out of it
    # unchanged.
    echo "--- keys.sh again"
    if docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      cp /home/$user/.ssh/authorized_keys /tmp/before
      printf '\n' | script -qec /home/$user/debian-setup/keys.sh /dev/null
      cmp -s /tmp/before /home/$user/.ssh/authorized_keys
    " >>"$log" 2>&1; then
      echo "  ok    keys.sh does not ask again for a key it already has"
    else
      echo "  FAIL  keys.sh does not ask again for a key it already has"
      stage_failed=1
    fi

    # claude.sh skipped signing-key.sh for the same reason, so the same again.
    # Signing a commit and verifying it is the assertion: it exercises the
    # derived .pub and the trust list signing-key.sh writes, and fails if the
    # paste handling is wrong.
    #
    # The signing config is written here rather than coming from a linked
    # .gitconfig, because that file lives in claude-dotfiles now and no
    # container ever gets that far. It has to be in place before
    # signing-key.sh runs: user.email is what it writes into allowed_signers as
    # the principal, and a signature verifies against nothing if the two
    # disagree.
    echo "--- claude/signing-key.sh"
    if docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      git config --global user.name tester
      git config --global user.email tester@example.com
      git config --global gpg.format ssh
      git config --global user.signingkey '~/.ssh/claude.pub'
      git config --global gpg.ssh.allowedSignersFile '~/.ssh/allowed_signers'
      git config --global commit.gpgsign true
      ssh-keygen -q -t ed25519 -N '' -C pasted -f /tmp/pasted
      script -qec /home/$user/debian-setup/claude/signing-key.sh /dev/null \
        </tmp/pasted
      test ! -L /home/$user/.ssh/allowed_signers
      cmp -s /tmp/pasted /home/$user/.ssh/claude
      rm -rf /tmp/signing && mkdir /tmp/signing && cd /tmp/signing
      git init -q .
      git commit --allow-empty -q -m signed
      git log --format='%G?' -1 | grep -qx G
    " >>"$log" 2>&1; then
      echo "  ok    signing-key.sh installs a pasted key that verifies"
    else
      echo "  FAIL  signing-key.sh installs a pasted key that verifies"
      stage_failed=1
    fi

    # Non-empty is not the same as usable: a wrapped or truncated paste leaves
    # a file with lines in it that parse as nothing, and hardening on the
    # strength of that is a box nobody can log in to.
    echo "--- harden-ssh.sh with an unusable key"
    docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      mkdir -p /home/$user/.ssh
      chmod 700 /home/$user/.ssh
      printf 'ssh-ed25519 AAAAtruncated\n' > /home/$user/.ssh/authorized_keys
    " >>"$log" 2>&1

    if run_in_container "$container" harden-ssh.sh >>"$log" 2>&1 &&
      docker exec "$container" test ! -f /etc/ssh/sshd_config.d/10-hardening.conf; then
      echo "  ok    harden-ssh.sh refuses a key sshd cannot use"
    else
      echo "  FAIL  harden-ssh.sh refuses a key sshd cannot use"
      stage_failed=1
    fi

    # machine.sh leaves the box unhardened, since keys.sh cannot prompt without a
    # terminal. Seed a key the way a real run would and the drop-in should land.
    echo "--- harden-ssh.sh"
    docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      mkdir -p /home/$user/.ssh
      chmod 700 /home/$user/.ssh
      ssh-keygen -q -t ed25519 -N '' -C $user -f /tmp/$user
      install -m 0600 /tmp/$user.pub /home/$user/.ssh/authorized_keys
    " >>"$log" 2>&1

    if run_in_container "$container" harden-ssh.sh >>"$log" 2>&1; then
      run_in_container "$container" test/assert.sh || stage_failed=1
    else
      echo "  FAIL  harden-ssh.sh exited non-zero"
      stage_failed=1
    fi
  fi

  # The root entry point, from the other end: a bare image with nothing but
  # root, where the user machine.sh needs does not exist yet. A key is handed in
  # the way a headless run would, so hardening happens on the way through. No
  # argument, so this is the plain Debian box and not the Claude one.
  #
  # DEBIAN_SETUP_USER is left unset here, unlike the stage above: with no
  # terminal to ask at, provision.sh falls back to the name it documents, and
  # the account it settles on is the assertion. Between the two stages the suite
  # covers both the knob and the default, and neither account is named claude —
  # which is the repo's rule about the name, tested rather than claimed.
  echo "--- provision.sh"
  provision_container="$container-provision"
  start_container "$provision_container" "$image"

  # git refuses to clone from a directory owned by someone else, and the
  # mounted repo belongs to whoever checked it out — uid 1000 on a dev box,
  # someone else on a CI runner. The container is thrown away either way.
  docker exec -e DEBIAN_FRONTEND=noninteractive "$provision_container" bash -c "
    set -e
    apt-get update -qq
    apt-get install -y -qq git >/dev/null
    git config --system --add safe.directory '*'
    install -d -m 0700 /root/.ssh
    printf '%s\n' '$root_public_key' > /root/.ssh/authorized_keys
  " >>"$log" 2>&1

  # A typo must not read as a request for the plain box: the argument is the
  # only thing standing between a machine someone wanted Claude Code on and one
  # they have to provision again. Refused before root, sudoers or apt are
  # touched, so it costs nothing to run here.
  if docker exec "$provision_container" bash /repo/provision.sh bogus \
    >>"$log" 2>&1; then
    echo "  FAIL  provision.sh refuses an argument it does not know"
    stage_failed=1
  else
    echo "  ok    provision.sh refuses an argument it does not know"
  fi

  provisioned_user=debian

  # Keeps the clone because the assertions below run out of it — and in doing so
  # covers the knob, the default being covered by the skipped stage further down.
  if docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    -e DEBIAN_SETUP_REPO=/repo \
    -e DEBIAN_SETUP_KEEP_CLONE=1 \
    -e SSH_PUBLIC_KEYS="$public_key" \
    "$provision_container" bash /repo/provision.sh >>"$log" 2>&1; then
    if docker exec "$provision_container" id -u "$provisioned_user" >/dev/null 2>&1; then
      echo "  ok    provision.sh names the account itself when nothing else does"
    else
      echo "  FAIL  provision.sh names the account itself when nothing else does"
      stage_failed=1
    fi

    if docker exec "$provision_container" \
      test -d "/home/$provisioned_user/debian-setup/.git"; then
      echo "  ok    DEBIAN_SETUP_KEEP_CLONE keeps the clone"
    else
      echo "  FAIL  DEBIAN_SETUP_KEEP_CLONE keeps the clone"
      stage_failed=1
    fi

    if docker exec "$provision_container" bash -c \
      "! grep -qF '$root_public_key' /home/$provisioned_user/.ssh/authorized_keys"; then
      echo "  ok    root's own key is not authorized for the account"
    else
      echo "  FAIL  root's own key is not authorized for the account"
      stage_failed=1
    fi

    run_in_container "$provision_container" test/assert.sh "$provisioned_user" ||
      stage_failed=1

    # Two things only root can see: that sshd will parse what was installed,
    # and that the sudo grant provision.sh lends itself for the run is gone
    # again. Left behind, that grant would be a standing one.
    if docker exec "$provision_container" /usr/sbin/sshd -t >>"$log" 2>&1; then
      echo "  ok    sshd accepts the drop-in"
    else
      echo "  FAIL  sshd accepts the drop-in"
      stage_failed=1
    fi

    if docker exec "$provision_container" \
      test ! -f /etc/sudoers.d/90-debian-setup-provision; then
      echo "  ok    the temporary sudo grant was withdrawn"
    else
      echo "  FAIL  the temporary sudo grant was withdrawn"
      stage_failed=1
    fi

    # Nobody asked for the overlay, so none of it may have happened. gh is the
    # cheapest thing to look for: the generic half has no reason to install it.
    if docker exec "$provision_container" bash -c '! command -v gh'; then
      echo "  ok    the claude half stayed out of a plain run"
    else
      echo "  FAIL  the claude half stayed out of a plain run"
      stage_failed=1
    fi

    # The password is generated, so a run with nobody watching leaves a usable
    # sudo behind rather than the locked account useradd creates.
    if docker exec "$provision_container" \
      bash -c "passwd -S $provisioned_user | awk '{print \$2}' | grep -qx P"; then
      echo "  ok    the user has a password"
    else
      echo "  FAIL  the user has a password"
      stage_failed=1
    fi
  else
    echo "  FAIL  provision.sh exited non-zero"
    stage_failed=1
  fi

  # The same entry point against a machine somebody else built: the account and
  # the overlay are wanted, machine.sh is not. Worth its own container because
  # what it asserts is an absence, and every earlier stage has already run the
  # half that would fill it in.
  echo "--- provision.sh with DEBIAN_SETUP_SKIP_MACHINE=1"
  skip_container="$container-skip"
  start_container "$skip_container" "$image"

  docker exec -e DEBIAN_FRONTEND=noninteractive "$skip_container" bash -c "
    set -e
    apt-get update -qq
    apt-get install -y -qq git >/dev/null
    git config --system --add safe.directory '*'
  " >>"$log" 2>&1

  # The overlay always provisions claude, and run from a worktree this suite
  # mounts the git common dir read-only at its own absolute path — which is
  # under /home/claude on the machine this repo is worked on. That leaves the
  # home directory existing and owned by root before useradd sees it, so the
  # clone cannot go anywhere inside it: /tmp for this stage only.
  if docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    -e DEBIAN_SETUP_REPO=/repo \
    -e DEBIAN_SETUP_DIR=/tmp/debian-setup \
    -e DEBIAN_SETUP_SKIP_MACHINE=1 \
    -e SSH_PUBLIC_KEYS="$public_key" \
    "$skip_container" bash /repo/provision.sh claude >>"$log" 2>&1; then

    # The overlay names the account, so this is the claude one. gh stands in for
    # the whole of claude.sh having run, the way it does in the plain stage.
    if docker exec "$skip_container" bash -c 'id -u claude && command -v gh' \
      >>"$log" 2>&1; then
      echo "  ok    the account and the overlay happen without machine.sh"
    else
      echo "  FAIL  the account and the overlay happen without machine.sh"
      stage_failed=1
    fi

    # btop comes from bootstrap-system.sh and the drop-in from harden-ssh.sh,
    # which is the half that must not have run: on a real machine it would have
    # rewritten an sshd config its owner wrote.
    if docker exec "$skip_container" bash -c \
      '! command -v btop && test ! -f /etc/ssh/sshd_config.d/10-hardening.conf'; then
      echo "  ok    machine.sh stayed out of a skipped run"
    else
      echo "  FAIL  machine.sh stayed out of a skipped run"
      stage_failed=1
    fi

    # Nothing on the machine points into the clone, and a rerun curls the script
    # again, so a run that made one takes it away.
    if docker exec "$skip_container" test ! -e /tmp/debian-setup; then
      echo "  ok    the clone this run made is gone again"
    else
      echo "  FAIL  the clone this run made is gone again"
      stage_failed=1
    fi

    if docker exec "$skip_container" \
      test ! -f /etc/sudoers.d/90-debian-setup-provision; then
      echo "  ok    the temporary sudo grant was withdrawn"
    else
      echo "  FAIL  the temporary sudo grant was withdrawn"
      stage_failed=1
    fi
  else
    echo "  FAIL  provision.sh exited non-zero with machine.sh skipped"
    stage_failed=1
  fi

  if [ "$stage_failed" -ne 0 ]; then
    failed=1
    echo "--- last 40 lines of output"
    tail -40 "$log" | sed 's/^/  /'
    echo "  full log: $log"
  else
    rm -f "$log"
  fi

  if [ "${KEEP:-}" = 1 ]; then
    echo "  containers kept: $container $provision_container $skip_container"
  else
    docker rm -f "$container" "$provision_container" "$skip_container" \
      >/dev/null 2>&1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "PASSED"
