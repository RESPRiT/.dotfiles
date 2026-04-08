# Dotfiles

## Directory structure

- `claude-global/` — Global Claude Code settings managed as dotfiles (symlinked to `~/.claude/`). This is where committed Claude settings live (e.g., `settings.local.json`).
- `.claude/` — Project-local Claude Code settings for *this repo*. Not the same as the dotfiles that get symlinked to the home directory.
- `hooks/` — Git hooks managed by the repo. `install.sh` symlinks these into `.git/hooks/`.
- `migrations/` — Numbered migration scripts (e.g., `001-name.sh`) for handling breaking changes between repo versions.
- `ghostty/` — Ghostty terminal config, symlinked to `~/.config/ghostty/`.

## install.sh

Idempotent setup script. Symlinks dotfiles into `$HOME`, installs plugins, sets up git hooks, and runs pending migrations. Safe to re-run — already-correct symlinks are skipped, existing files are backed up.

Machine-specific config goes in `~/.zshrc.local` or `~/.bashrc.local` (created by install.sh if missing).

## Local override pattern

All configuration files managed by this repo should strive to support a "dotfiles base + machine-local override" pattern, so per-host tweaks don't require forking the committed config:

1. **Symlink the committed file** into `$HOME` using the `link_shell` helper in `install.sh` (not the plain `link` helper). On first install, any pre-existing real file at the destination is moved to a sibling `*.local` path instead of being backed up to `.bak`, and an empty `*.local` file is seeded if none exists.
2. **Source the local file last** from the committed config, so anything in the local file overrides the defaults. The local file should be optional — guard the source with an existence check.

Examples in the repo:
- `zshrc:64` sources `~/.zshrc.local` after everything else
- `tmux.conf` sources `~/.tmux.local.conf` via `if-shell` at the bottom

When adding a new config file to the repo, prefer this pattern over the plain `link` helper unless there's a specific reason not to (e.g., the file format has no include/source mechanism).

**Known gap:** Claude Code configuration files (`~/.claude/settings.local.json`, etc.) do not currently follow this pattern — they're symlinked directly with no local override mechanism, because JSON has no native include syntax and Claude Code doesn't merge multiple settings files. Revisit if/when Claude Code supports layered config.

## Shell parity (bash + zsh)

This repo treats bash and zsh as first-class shells. Shared shell config lives in `shellrc`, which is sourced by both `bashrc` and `zshrc`. When adding shell-level functionality (functions, aliases, exports, PATH tweaks), prefer `shellrc` so the behavior is consistent across both shells. Only put code in `zshrc`/`bashrc` directly when it's genuinely shell-specific (zsh completion, bash readline bindings, shell-specific prompt escapes, etc.).

`shellrc` should stick to syntax that works in both shells:
- Use `[ ... ]` (POSIX test), not `[[ ... ]]` (bash/zsh extension).
- Use `printf '%q '` for shell-quoting args, not `${(q)@}` (zsh-only).
- Use `command -v` (or a subshell `unset -f` trick when a function shadows the binary you're looking for) instead of `whence` (zsh-only) or `type -P` (bash-only).
- `local` is acceptable — both shells support it, and the file already uses it.

When in doubt, test the change in both `bash` and `zsh` before committing.

## Migration system

Breaking changes between repo versions are handled by numbered scripts in `migrations/`. The system works as follows:

- `hooks/post-merge` runs automatically after `git pull`, executing any migrations newer than `~/.dotfiles-migrated`.
- `install.sh` seeds `~/.dotfiles-migrated` to `0` on first run, then runs all pending migrations.
- The post-merge hook exits early if no tracker exists, so cloning without running install.sh won't trigger migrations.
- Each migration script should be idempotent — check state before acting.
- Naming convention: `NNN-description.sh` (e.g., `001-claude-global-rename.sh`).
