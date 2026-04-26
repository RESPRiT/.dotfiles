# Dotfiles

## Directory structure

- `claude-global/` — Global Claude Code settings managed as dotfiles (symlinked to `~/.claude/`). This is where committed Claude settings live (e.g., `settings.local.json`).
- `.claude/` — Project-local Claude Code settings for *this repo*. Not the same as the dotfiles that get symlinked to the home directory.
- `hooks/` — Git hooks managed by the repo. `install.sh` symlinks these into `.git/hooks/`.
- `migrations/` — Numbered migration scripts (e.g., `001-name.sh`) for handling breaking changes between repo versions.
- `ghostty/` — Ghostty terminal config, symlinked to `~/.config/ghostty/`.
- `powershell/` — PowerShell profile and Windows installer (`install.ps1`). Profile is symlinked to `$HOME\Documents\PowerShell\profile.ps1` ($PROFILE.CurrentUserAllHosts). Per-machine overrides live in `$HOME\Documents\PowerShell\profile.local.ps1`.

## Installers

Two installers, one per platform family. Both are idempotent (safe to re-run; already-correct symlinks are skipped, existing files are backed up) and share the same `.state/decisions` file.

- **`install.sh`** (POSIX — Linux, macOS, WSL, Git Bash): symlinks the bash/zsh/vim/tmux/ghostty config into `$HOME`, installs CLI tools (rust, go, zoxide, atuin, keychain, tmux 3.5+), wires the post-merge git hook, and runs pending migrations.
- **`powershell/install.ps1`** (Windows): symlinks `powershell/profile.ps1` into `$HOME\Documents\PowerShell\`, installs CLI tools via winget (zoxide, atuin, neovim, gh CLI, eza). Self-elevates via UAC because symlink creation requires admin (Developer Mode off). Does **not** run bash migrations — seeds `.state/migrated` to the current max so `post-merge` doesn't replay them when `git pull` is run from Git Bash on the same machine.

Machine-specific config goes in `~/.zshrc.local` / `~/.bashrc.local` (POSIX) or `$HOME\Documents\PowerShell\profile.local.ps1` (Windows). All are created automatically if missing.

## Local override pattern

All configuration files managed by this repo should strive to support a "dotfiles base + machine-local override" pattern, so per-host tweaks don't require forking the committed config:

1. **Symlink the committed file** into `$HOME` using the `link_shell` helper in `install.sh` (not the plain `link` helper). On first install, any pre-existing real file at the destination is moved to a sibling `*.local` path instead of being backed up to `.bak`, and an empty `*.local` file is seeded if none exists.
2. **Source the local file last** from the committed config, so anything in the local file overrides the defaults. The local file should be optional — guard the source with an existence check.

Examples in the repo:
- `zshrc:64` sources `~/.zshrc.local` after everything else
- `tmux.conf` sources `~/.tmux.local.conf` via `if-shell` at the bottom
- `powershell/profile.ps1` sources `profile.local.ps1` (in `$PROFILE`'s parent dir) at the bottom

When adding a new config file to the repo, prefer this pattern over the plain `link` helper unless there's a specific reason not to (e.g., the file format has no include/source mechanism). On the PowerShell side, `Link-Shell` in `install.ps1` is the equivalent of bash's `link_shell`.

**Claude Code settings (special case):** Claude Code has no `include` directive and no user-scope `.local.json` overlay (only project-scope), so the symlink-plus-source pattern doesn't work. Instead, `~/.claude/settings.json` is **generated** at install time by `claude-global/merge-settings.sh`, which deep-merges:

- `claude-global/settings.json` — committed base, shared across machines
- `~/.claude/settings.local.json` — machine-local overlay (seeded as `{}` on first install; not in repo)

into the destination `~/.claude/settings.json`. Merge rules: objects deep-merge (right wins on scalars), string arrays concat-and-dedupe (so `permissions.allow` accumulates from both files), object arrays concat (so hook lists chain). The merge runs in `install.sh` and `hooks/post-merge`, so pulling new base settings auto-regenerates. Direct edits to `~/.claude/settings.json` are blocked by the `protect-settings.sh` PreToolUse hook — agents are directed to the base or overlay. The destination is a real file, not a symlink, because Claude Code has a known bug where symlinked `settings.json` triggers permission failures (anthropics/claude-code#3575).

## Shell parity (bash + zsh, plus PowerShell on Windows)

This repo treats bash and zsh as first-class shells. Shared shell config lives in `shellrc`, which is sourced by both `bashrc` and `zshrc`. When adding shell-level functionality (functions, aliases, exports, PATH tweaks), prefer `shellrc` so the behavior is consistent across both shells. Only put code in `zshrc`/`bashrc` directly when it's genuinely shell-specific (zsh completion, bash readline bindings, shell-specific prompt escapes, etc.).

PowerShell is a separate-shell-family case (Windows). Its config lives in `powershell/profile.ps1` and aims for behavioral parity with the POSIX side — same prompt shape (`user@host cwd(branch) >`), same aliases (`ll`/`l`/`gs`/`cd`→`z`/`..`/`...`/`extract`/`reload`), same git-branch coloring rules (red dirty / pink main|master / green other). When changing prompt/alias semantics, update both sides.

`shellrc` should stick to syntax that works in both shells:
- Use `[ ... ]` (POSIX test), not `[[ ... ]]` (bash/zsh extension).
- Use `printf '%q '` for shell-quoting args, not `${(q)@}` (zsh-only).
- Use `command -v` (or a subshell `unset -f` trick when a function shadows the binary you're looking for) instead of `whence` (zsh-only) or `type -P` (bash-only).
- `local` is acceptable — both shells support it, and the file already uses it.

When in doubt, test the change in both `bash` and `zsh` before committing.

## Migration system

Breaking changes between repo versions are handled by numbered scripts in `migrations/`. The system works as follows:

- Per-machine state lives in `.state/` (gitignored) at the repo root: `.state/migrated` (last-applied migration number) and `.state/decisions` (stored `[N]` answers for install.sh prompts).
- `hooks/post-merge` runs automatically after `git pull`, executing any migrations newer than `.state/migrated`.
- `install.sh` seeds `.state/migrated` to `0` on first run, then runs all pending migrations.
- The post-merge hook exits early if no tracker exists, so cloning without running install.sh won't trigger migrations.
- Both `install.sh` and `post-merge` will relocate legacy `~/.dotfiles-{migrated,decisions}` into `.state/` if found, so existing machines upgrade transparently.
- Each migration script should be idempotent — check state before acting.
- Naming convention: `NNN-description.sh` (e.g., `001-claude-global-rename.sh`).
- Migrations are bash scripts (POSIX). On Windows, `install.ps1` seeds `.state/migrated` to the highest existing migration number so historical bash migrations don't run when `git pull` triggers `post-merge` via Git Bash. New migrations added later still run on Windows via Git Bash, so they should be written defensively (e.g., guard tmux/keychain steps with `command -v` checks) so they no-op cleanly on Windows.
