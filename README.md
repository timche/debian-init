# Debian Setup

[![test](https://github.com/timche/debian-setup/actions/workflows/test.yml/badge.svg)](https://github.com/timche/debian-setup/actions/workflows/test.yml)

Provisioning for a Debian VM, and optionally for the one that runs Claude Code. As root, which is how a VM arrives from a provider:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/debian-setup/main/provision.sh | bash            # a plain Debian box
curl -fsSL https://raw.githubusercontent.com/timche/debian-setup/main/provision.sh | bash -s claude  # the same, plus Claude Code
```

Both create the account, clone this repo and run `machine.sh` as that user. The second then runs `claude.sh` on top, and that is the whole of the difference.

On a machine that is already built — docker, tailscale and an sshd hardened the way its owner wants them — the same entry point can create the account and go straight to the Claude half:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/debian-setup/main/provision.sh | DEBIAN_SETUP_SKIP_MACHINE=1 bash -s claude
```

`DEBIAN_SETUP_SKIP_MACHINE=1` leaves `machine.sh` out of either run. The account, the key it asks you for, the password sudo needs and the overlay all still happen; docker, tailscale and sshd are left exactly as they are, where a run without it would rewrite the sshd drop-in and bring tailscale up again. It does not ask for a tailnet key either, since nothing in a skipped run would use one — and if the account ends up with no key at all it says so rather than leaving it to the `keys.sh` that never runs.

The plain run asks what the account should be called, defaulting to `debian`; the Claude one does not ask, because the private dotfiles hardcode `claude`. Either way `DEBIAN_SETUP_USER` settles it without a prompt, which is what a run with nobody at the keyboard wants.

## The machine

`machine.sh` installs docker and tailscale, switches unattended-upgrades on, asks for the public keys you connect with, brings the machine up on the tailnet advertising ssh, and then hardens sshd down to keys only, no root, one user. The tailnet is the second way in that lets the hardening be as strict as it is — `provision.sh` asks for a tailscale auth key up front, so every question a plain box has comes before the long part of the run and you can leave it to it; `TS_AUTHKEY` answers it for a run with nobody at the keyboard. Make it a tagged key: a tagged node's key does not expire, and an untagged server drops off the tailnet when its own does. Nothing it leaves behind needs an account anywhere.

## The Claude Code overlay

`claude.sh` installs `gh` and `jq`, the two packages that have to exist before the private `claude-dotfiles` can be cloned, logs in to GitHub and to Claude Code, and hands over to the dotfiles — cloned to `~/.claude-dotfiles`, hidden because it is machinery rather than work — for everything after that: the shell and its own packages, the prompt, the runtimes and `~/.claude`. It also installs the commit-signing key and registers it with GitHub. Run it on its own against a box `machine.sh` has already built, and rerun it when a token expires.

The machine runs Claude Code with `bypassPermissions`, which is the point of giving it a VM of its own: there is nothing on it worth guarding Claude from.

## Two things worth knowing

The tailscale ssh policy is not this repo's to write. The machine advertises ssh on the tailnet, but nobody can use it until a rule in the admin console says so — and tailscaled answers those sessions itself, so the sshd hardening has no say over them.

docker writes its own iptables rules and goes around a host firewall, so a firewall at the provider is the one that counts.

`CLAUDE.md` has the details: the order the scripts run in, the constraints that are not obvious from reading them, and how to test.
