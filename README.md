# Debian Init

[![test](https://github.com/timche/debian-init/actions/workflows/test.yml/badge.svg)](https://github.com/timche/debian-init/actions/workflows/test.yml)

Provisioning for a Debian VM, and optionally for the one that runs Claude Code. As root, which is how a VM arrives from a provider:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/debian-init/main/provision.sh | bash            # a plain Debian box
curl -fsSL https://raw.githubusercontent.com/timche/debian-init/main/provision.sh | bash -s claude  # the same, plus Claude Code
```

Both create the account, clone this repo and run `setup.sh` as that user. The second then runs `claude.sh` on top, and that is the whole of the difference.

## The machine

`setup.sh` installs docker and tailscale, switches unattended-upgrades on, asks for the public keys you connect with, and hardens sshd down to keys only, no root, one user. It brings the machine up on the tailnet advertising ssh, which is the second way in that lets the hardening be as strict as it is. Nothing it leaves behind needs an account anywhere.

## The Claude Code overlay

`claude.sh` installs `gh`, zsh and the rest of what the private `claude-dotfiles` expects, logs in to GitHub and to Claude Code, and hands over to the dotfiles for the shell, the prompt, the runtimes and `~/.claude`. It also installs the commit-signing key and registers it with GitHub. Run it on its own against a box `setup.sh` has already built, and rerun it when a token expires.

The machine runs Claude Code with `bypassPermissions`, which is the point of giving it a VM of its own: there is nothing on it worth guarding Claude from.

## Two things worth knowing

The tailscale ssh policy is not this repo's to write. The machine advertises ssh on the tailnet, but nobody can use it until a rule in the admin console says so — and tailscaled answers those sessions itself, so the sshd hardening has no say over them.

docker writes its own iptables rules and goes around a host firewall, so a firewall at the provider is the one that counts.

`CLAUDE.md` has the details: the order the scripts run in, the constraints that are not obvious from reading them, and how to test.
