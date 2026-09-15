#!/bin/bash

# System setup for a bare Debian VM: packages, docker, tailscale. Needs sudo,
# and only has to run once.
#
# The sshd drop-in is not installed here — see harden-ssh.sh, which setup.sh
# runs once there are keys to log in with.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

distro="$(. /etc/os-release && echo "$ID")"
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
architecture="$(dpkg --print-architecture)"

if [ "$distro" != debian ]; then
  echo "unsupported distribution: $distro (expected debian)" >&2
  exit 1
fi

# openssh-client is the one that is not obvious from its name: ssh-keygen is
# what keys.sh checks a pasted key with, and what harden-ssh.sh asks before it
# turns password logins off.
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y \
  btop ca-certificates curl git openssh-client openssh-server sudo \
  unattended-upgrades vim

# Installing the package does not reliably imply it is switched on.
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Third-party repositories. Docker and tailscale publish a tree per release,
# so both of these are keyed on the codename.

sudo install -d -m 0755 /etc/apt/keyrings

sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
sudo curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list

sudo apt-get update
sudo apt-get install -y tailscale \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# System configuration

sudo install -m 0644 "$repo/system/docker/daemon.json" /etc/docker/daemon.json

# Skipped inside containers, where there is no init to talk to.
if [ -d /run/systemd/system ]; then
  sudo systemctl restart docker
  sudo systemctl enable --now tailscaled
  sudo systemctl enable --now unattended-upgrades
fi

sudo usermod -aG docker "$USER"
