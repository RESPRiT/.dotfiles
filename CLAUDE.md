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

## Migration system

Breaking changes between repo versions are handled by numbered scripts in `migrations/`. The system works as follows:

- `hooks/post-merge` runs automatically after `git pull`, executing any migrations newer than `~/.dotfiles-migrated`.
- `install.sh` seeds `~/.dotfiles-migrated` to `0` on first run, then runs all pending migrations.
- The post-merge hook exits early if no tracker exists, so cloning without running install.sh won't trigger migrations.
- Each migration script should be idempotent — check state before acting.
- Naming convention: `NNN-description.sh` (e.g., `001-claude-global-rename.sh`).
