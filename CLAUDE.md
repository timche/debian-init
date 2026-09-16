# CLAUDE.md

Machine provisioning for a Debian VM, with an optional overlay that turns it into the one Claude Code runs on. Shell scripts only — no build, no lint, no package manager. Every script opens with a comment explaining why it exists and what would break if it ran elsewhere in the order, so read the script rather than looking for a second copy of it here.

Two entry points. `provision.sh` is the one a bare VM has: it runs as root, creates the user, authorizes keys, clones the repo, and hands to `machine.sh` running as that user — then to `claude.sh`, if it was given the one argument it takes, `claude`. Anything else is an error, so a typo cannot quietly produce a generic box.

`machine.sh` refuses root and calls `bootstrap-system.sh`, `keys.sh`, `tailscale.sh`, `harden-ssh.sh` in that order. That is the whole of the machine, and none of it needs an account anywhere.

`claude.sh` is the overlay and the second entry point. It installs the two packages that have to exist before the private repo can be reached — `gh` and its apt source, and the `jq` `login.sh` uses — then calls `claude/install.sh`, `claude/login.sh` and `claude/signing-key.sh` in that order: the dotfiles need a token, the token comes from the login, and the signing key needs the `user.email` the dotfiles carry. `claude/register-signing-key.sh` is called by the two of those that end up holding a key to register. Run `claude.sh` by hand against a box `machine.sh` has already built, and rerun it when a token expires.

Public, and holds nothing personal — the shell, the runtimes and `~/.claude` come from the private `claude-dotfiles`, which `claude/install.sh` clones once `gh` is logged in. The split is *works before you can authenticate* against *needs an account*.

## Committing

Commit and push to main directly, no branch and no PR. Standing permission, and an exception to the global rules on branching and asking before a push.

## Rules

- The generic half may not depend on the Claude half. `machine.sh` and everything it calls must leave a usable machine with no account anywhere, and must not name `claude.sh` or anything under `claude/`. Only `provision.sh` knows both exist.
- Nothing may depend on the account being named `claude`: paths go through `$HOME` or `getent passwd`, and the sshd drop-in's `__USER__` is substituted at install time. (`claude-dotfiles` does assume that name. This repo does not.) `provision.sh` asks for the name, falling back to `debian`; the `claude` argument answers it as `claude` without asking, and `DEBIAN_INIT_USER` overrides both. That one line is the only place the name is decided.
- Every paste a plain box needs is asked for in `provision.sh`, before `bootstrap-system.sh`'s upgrade — the long part of the run. `tailscale.sh` reads `TS_AUTHKEY` from the environment and asks only if the variable is not set at all; set-but-empty means `provision.sh` asked and was told no, and a second ask is the thing the front-loading exists to avoid.
- Prompts in `provision.sh` read from `/dev/tty`, not stdin: under the documented curl install stdin is the pipe feeding the script, so a prompt on it is one nobody can answer.
- `$HOME/debian-init`, the `DEBIAN_INIT_*` knobs and the sudoers drop-in are named for the generic half even though the VM this provisions is usually the Claude one. The exception is the signing key at `~/.ssh/claude`, which is Claude-side and whose path `claude-dotfiles`' `.gitconfig` points `user.signingkey` at — moving it here means moving it there too.
- Nothing personal ships from here. `assert.sh` fails if a `home/` or `.claude` path appears.
- The clone is disposable: nothing symlinks out of it, and the only files read from it are the two under `system/` — the sshd drop-in and docker's `daemon.json`. Keep it that way.
- Debian only, refused up front.

## Testing

`test/run.sh` — several minutes, so run it in the background. Per image it runs `machine.sh` and `test/assert.sh`, then `claude.sh` and `test/assert-claude.sh`, then two pty stages that paste an authorized key into `keys.sh` and a signing key into `claude/signing-key.sh`, then the hardening ones. A second container runs `provision.sh` with no argument and asserts that none of the Claude half happened. That stage clones, so it tests HEAD and not the working tree; commit first. A container has no authenticated `gh`, so the handover to the private repo is never reached here — that is covered by CI in `claude-dotfiles`.

## Environment knobs

`DEBIAN_INIT_USER`, `DEBIAN_INIT_REPO`, `DEBIAN_INIT_DIR`, `DEBIAN_INIT_SKIP_SETUP` (the account and the overlay without the machine, for a box somebody else built), `CLAUDE_DOTFILES_REPO`, `CLAUDE_DOTFILES_DIR`, `SSH_PUBLIC_KEYS` and `TS_AUTHKEY` (headless key handoff to `provision.sh`, which passes the tailscale one through `su -w`), `FORCE_HARDEN`, `KEEP`.
