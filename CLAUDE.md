# CLAUDE.md

Machine provisioning for the Debian VM that runs Claude Code. Shell scripts
only — no build, no lint, no package manager. Every script opens with a comment
explaining why it exists and what would break if it ran elsewhere in the order,
so read the script rather than looking for a second copy of it here.

`provision.sh` is the only entry point and runs as root. It creates the user
and hands to `setup.sh`, which refuses root and calls `bootstrap-system.sh`,
`install.sh`, `login.sh`, `keys.sh`, `harden-ssh.sh` in that order.

Public, and holds nothing personal — the shell, the runtimes and `~/.claude`
come from the private `claude-dotfiles`, which `install.sh` clones once `gh` is
logged in. The split is *works before you can authenticate* against *needs an
account*.

## Committing

Commit and push to main directly, no branch and no PR. Standing permission, and
an exception to the global rules on branching and asking before a push.

## Rules

- Nothing may depend on the account being named `claude`: paths go through
  `$HOME` or `getent passwd`, and the sshd drop-in's `__USER__` is substituted
  at install time. (`claude-dotfiles` does assume that name. This repo does
  not.)
- Nothing personal ships from here. `assert.sh` fails if a `home/` or `.claude`
  path appears.
- The clone is disposable: nothing symlinks out of it, and only
  `harden-ssh.sh` still reads a file from it. Keep it that way.
- Debian only, refused up front.

## Testing

`test/run.sh` — several minutes, so run it in the background. The
`provision.sh` stage clones, so it tests HEAD and not the working tree; commit
first. A container has no authenticated `gh`, so the handover to the private
repo is never reached here — that is covered by CI in `claude-dotfiles`.

## Environment knobs

`DEBIAN_INIT_USER`, `DEBIAN_INIT_REPO`, `DEBIAN_INIT_DIR`,
`CLAUDE_DOTFILES_REPO`, `CLAUDE_DOTFILES_DIR`, `SSH_PUBLIC_KEYS` (headless key
handoff to `provision.sh`), `FORCE_HARDEN`, `KEEP`.
