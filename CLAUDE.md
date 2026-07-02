# Dotfiles

## Repo conventions

This is a **solo-developer repo** — there's no review workflow and no shared `main` to protect. Commit directly to `main` and push; don't branch or open PRs for routine changes (the default "branch before committing on main" rule does not apply here). Still write clear commit messages and keep commits scoped.

## Directory structure

- `claude-global/` — Global Claude Code settings managed as dotfiles (symlinked to `~/.claude/`). This is where committed Claude settings live (e.g., `settings.local.json`). `CLAUDE.md` is the committed base for global instructions, linked via `link_shell` with a trailing `@~/.claude/CLAUDE.local.md` import line so machine-local instructions layer on top (CLAUDE.md has no native include directive, so the local file is pulled in via Claude Code's `@import` syntax instead of being sourced). Subdir `skills/<name>/SKILL.md` holds user-global skills (each symlinked into `~/.claude/skills/<name>` by `install.sh`). `keybindings.json` (a plain symlink, like skills) is a slot for custom Claude Code key rebinds — currently empty, because the Ctrl+Z→undo rebind lives in `tmux.conf` instead (Claude Code doesn't honor a remapped `ctrl+z`, so it's done at the tmux layer; see the `@claude-running`-gated `C-z` binding).
- `.claude/` — Project-local Claude Code settings for *this repo*. Not the same as the dotfiles that get symlinked to the home directory.
- `git-hooks/` — Git hooks managed by the repo. `install.sh` symlinks these into `.git/hooks/`.
- `ssh/` — Committed `authorized_keys` (public keys only; neutral comment labels, never `user@host`, because the repo is public). Both installers' opt-in "SSH over Tailscale" step (decision keys `tailscale-sshd`, plus `wsl-sshd` for the WSL-native path) merges it append-only into the machine's live authorized keys — `~/.ssh/authorized_keys` on POSIX, `ProgramData\ssh\administrators_authorized_keys` (+ `~\.ssh\authorized_keys`) on Windows — so every opted-in machine trusts these keys. Keys are only ever applied by an explicit installer run, never by `post-merge`/auto-pull: repo write access already implies SSH-key trust, so the apply step staying manual is the review gate. Treat diffs to this file like sudoers changes.
- `lib/` — Sourceable shell libraries. `colors.sh` (color constants) and `helpers.sh` (idempotent `link` / `link_shell` / `install_wrapper` / `install_bash_profile`) are shared by `install.sh` and migrations; callers must define `$DOTFILES` first. `git-prompt.sh` exposes `_git_prompt_state` (branch + `*`dirty/`^`ahead markers + color cascade), sourced by both `shellrc`'s prompt and `claude-global/statusline-command.sh` so the two branch segments can't drift (the staged-only-change bug came from them computing dirtiness separately). PowerShell can't source it, so `powershell/profile.ps1` keeps a hand-mirrored copy.
- `migrations/` — Numbered migration scripts (e.g., `001-name.sh`) for handling breaking changes between repo versions.
- `ghostty/` — Ghostty terminal config, symlinked to `~/.config/ghostty/`.
- `powershell/` — PowerShell profile and Windows installer (`install.ps1`). Profile is symlinked to `$HOME\Documents\PowerShell\profile.ps1` ($PROFILE.CurrentUserAllHosts). Per-machine overrides live in `$HOME\Documents\PowerShell\profile.local.ps1`. Also holds `windows-terminal-newline.json`, the canonical Shift+Enter→newline keybinding that `install.ps1` injects into Windows Terminal's `settings.json` (see `docs/WINDOWS_TERMINAL_SHIFT_ENTER.md`).

## Installers

Two installers, one per platform family. Both are idempotent (safe to re-run; already-correct symlinks are skipped, existing files are backed up) and share the same `.state/decisions` file.

- **`install.sh`** (POSIX — Linux, macOS, WSL, Git Bash): symlinks the bash/zsh/vim/tmux/ghostty config into `$HOME`, installs CLI tools (rust, go, zoxide, atuin, keychain, tmux 3.5+), wires the post-merge git hook, optionally enables sshd with key-only auth + the committed `ssh/authorized_keys` (SSH over Tailscale; decision key `tailscale-sshd` on macOS/Linux), and runs pending migrations. On WSL a **separate** opt-in step (decision key `wsl-sshd`) instead runs native sshd *inside* the distro on port 2222 — but only when mirrored networking is active (detected via the `loopback0` interface), because mirrored mode is what mirrors the host's tailnet interface into WSL so the listener is reachable at the tailnet IP without a portproxy. It merges the same keys, writes the port + key-only hardening, enables the systemd unit, then prints the elevated `New-NetFirewallHyperVRule` command the user must run on the Windows host (the Hyper-V-firewall inbound allow can't be done from inside WSL). NAT-mode WSL and Git Bash still defer to `powershell/install.ps1`. The sshd hardening drop-in is named `010-dotfiles.conf` so it sorts ahead of macOS's `100-macos.conf` (sshd is first-match-wins per keyword); the WSL step reuses the same filename (with an added `Port` directive) since the macOS/Linux and WSL paths are mutually exclusive per platform.
- **`powershell/install.ps1`** (Windows): symlinks `powershell/profile.ps1` into `$HOME\Documents\PowerShell\`, installs CLI tools via winget (zoxide, atuin, neovim, gh CLI, eza), injects the Shift+Enter→newline keybinding into Windows Terminal's `settings.json` (`Add-WTNewlineBinding`; surgical, idempotent, backs up first — see `docs/WINDOWS_TERMINAL_SHIFT_ENTER.md`), and optionally enables the bundled OpenSSH server for SSH over Tailscale (key-only auth, pwsh as the SSH default shell, keys merged into `administrators_authorized_keys` with the SYSTEM+Administrators-only ACL sshd requires; needs an elevated session). Self-elevates via UAC because symlink creation requires admin (Developer Mode off). Does **not** run bash migrations — seeds `.state/migrated` to the current max so `post-merge` doesn't replay them when `git pull` is run from Git Bash on the same machine.

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

**Shell rc files (special case):** `~/.bashrc`, `~/.zshrc`, and `~/.bash_profile` are *not* symlinks. Third-party installers (nvm, conda, fzf, rustup, …) commonly do `>> ~/.bashrc` to add their setup; if those files were symlinks, the appends would mutate the dotfiles repo. Instead `install.sh`'s `install_wrapper` writes a real file containing one line — `. "<repo>/bashrc"` — and the corresponding `.local` file (still hand-curated) is sourced from the committed base near its end. Layering becomes:

- **Base** (`bashrc`/`zshrc` in the repo): canonical, never written to by anything outside the repo.
- **Local** (`~/.bashrc.local` / `~/.zshrc.local`): hand-curated machine overrides, sourced from the base.
- **Wrapper** (`~/.bashrc` / `~/.zshrc`): real file, sources the base, and is where third-party installer appends pile up.

Load order: base → local → app appends. When `install.sh`/migration `004` finds an existing wrapper (any line referencing the base path), it leaves the file alone so app appends below the source line are preserved. `~/.bash_profile` follows the same wrapper rule (sources `~/.bashrc`); the dotfiles repo no longer carries a `bash_profile` file because the wrapper inlines the one-line content.

**Claude Code settings (special case):** Claude Code has no `include` directive and no user-scope `.local.json` overlay (only project-scope), so the symlink-plus-source pattern doesn't work. Instead, `~/.claude/settings.json` is **generated** at install time by `claude-global/merge-settings.sh`, which deep-merges:

- `claude-global/settings.json` — committed base, shared across machines
- `~/.claude/settings.local.json` — machine-local overlay (seeded as `{}` on first install; not in repo)

into the destination `~/.claude/settings.json`. Merge rules: objects deep-merge (right wins on scalars), string arrays concat-and-dedupe (so `permissions.allow` accumulates from both files), object arrays concat (so hook lists chain). Direct agent edits to `~/.claude/settings.json` are blocked by the `protect-settings.sh` PreToolUse hook — agents are directed to the base or overlay. The destination is a real file, not a symlink, because Claude Code has a known bug where symlinked `settings.json` triggers permission failures (anthropics/claude-code#3575).

`merge-settings.sh` is non-destructive by default. It computes the projected merge and consults a snapshot of the last-written dest (`.state/claude-settings-last-merge.json`) to pick one of five cases: write a fresh dest, no-op (projected matches dest), no-baseline first-run write, clean propagation of an intentional base/overlay edit (`dest == snapshot`), or **drift** (`dest ≠ snapshot ∧ projected ≠ dest`, meaning Claude Code's own writers — `/plugin`, `/config`, `/permissions`, settings UI — touched dest out-of-band).

The drift case has three sub-paths, tried in order: (5a) **cosmetic-only** — if dest and projected are equal after key-sorting, just sync the snapshot; the writer reordered keys but nothing changed semantically. (5b) **auto-reconcile** — compute `subtract(base, dest)` as a candidate overlay, re-merge, and verify it reproduces dest exactly. If it does (the common case for `/plugin` adds, scalar `/config` changes, new permissions), write the candidate to overlay, refresh dest/snapshot, append the diff to `.state/claude-settings-reconcile.log`, and emit a `RECONCILED:` line on stderr so the in-session hooks can mention the auto-promotion to the user (so accidental drift can be caught and reverted via the log). (5c) **needs human judgment** — overlay can't express the change (typically a removal from a base array, since merge concat can only add). The script emits a `DRIFT:` line and exits 3 without touching dest.

The in-session `remerge-on-settings-edit.sh` (PostToolUse), `session-start-drift-check.sh` (SessionStart), and `git-hooks/post-merge` (after `git pull`) all run without `--force` and surface `RECONCILED:` and `DRIFT:` lines via `additionalContext`, with different reconciliation instructions for each. `post-merge` deliberately doesn't force: a base update from a pull is a legitimate change that propagates via case 4 when dest is unsynced, and irreconcilable dest drift gets surfaced to the next session rather than clobbered (so an out-of-band `/plugin` or `/config` change isn't silently lost just because the user happened to `git pull` afterward). `--force` overrides the 5c refusal by logging the diff to `.state/claude-settings-drift.log` (rotated past 1MB) before clobbering, and is passed by `install.sh` and `migrations/003` because they're explicitly user-invoked one-shots; auto-reconcile (5a/5b) still runs first under `--force`, so the destructive path only fires when truly needed. Both `.state/` logs rotate at 1MB.

## Shell parity (bash + zsh, plus PowerShell on Windows)

This repo treats bash and zsh as first-class shells. Shared shell config lives in `shellrc`, which is sourced by both `bashrc` and `zshrc`. When adding shell-level functionality (functions, aliases, exports, PATH tweaks), prefer `shellrc` so the behavior is consistent across both shells. Only put code in `zshrc`/`bashrc` directly when it's genuinely shell-specific (zsh completion, bash readline bindings, shell-specific prompt escapes, etc.).

PowerShell is a separate-shell-family case (Windows). Its config lives in `powershell/profile.ps1` and aims for behavioral parity with the POSIX side — same prompt shape (`user@host cwd(branch) >`), same aliases (`ll`/`l`/`gs`/`..`/`...`/`extract`/`reload`, plus `z` for frecency jumps while `cd` stays the deterministic builtin), same git-branch coloring rules (red dirty / pink main|master / green other). When changing prompt/alias semantics, update both sides.

`shellrc` should stick to syntax that works in both shells:
- Use `[ ... ]` (POSIX test), not `[[ ... ]]` (bash/zsh extension).
- Use `printf '%q '` for shell-quoting args, not `${(q)@}` (zsh-only).
- Use `command -v` (or a subshell `unset -f` trick when a function shadows the binary you're looking for) instead of `whence` (zsh-only) or `type -P` (bash-only).
- `local` is acceptable — both shells support it, and the file already uses it.

When in doubt, test the change in both `bash` and `zsh` before committing.

## Migration system

Breaking changes between repo versions are handled by numbered scripts in `migrations/`. The system works as follows:

- Per-machine state lives in `.state/` (gitignored) at the repo root: `.state/migrated` (last-applied migration number) and `.state/decisions` (stored `[N]` answers for install.sh prompts).
- `git-hooks/post-merge` runs automatically after `git pull`, executing any migrations newer than `.state/migrated`.
- `install.sh` seeds `.state/migrated` to `0` on first run, then runs all pending migrations.
- The post-merge hook exits early if no tracker exists, so cloning without running install.sh won't trigger migrations.
- Both `install.sh` and `post-merge` will relocate legacy `~/.dotfiles-{migrated,decisions}` into `.state/` if found, so existing machines upgrade transparently.
- Each migration script should be idempotent — check state before acting.
- When a change to `install.sh` adds **dotfiles infrastructure** (a new symlink, wrapper, or seed file that every machine needs), pair it with a migration that backfills the same step on existing machines. The migration should source `lib/helpers.sh` and call the same helper (`link`, `link_shell`, `install_wrapper`, …) install.sh uses, so the two paths can't drift. Optional tools that the user opts into via prompt (rust, go, atuin, …) don't get migrations — those stay install-time-only. See `006-statusline-symlink.sh` for the canonical pattern.
- Naming convention: `NNN-description.sh` (e.g., `001-claude-global-rename.sh`). New migration files must have the executable bit set (`chmod +x`). `post-merge` invokes them via `bash "$script"` so a missing bit won't break the run, but the convention is consistently exec-bit-on across the directory and a missing bit blocks direct invocation (`./migrations/NNN-foo.sh`) when testing.
- Migrations are bash scripts (POSIX). On Windows, `install.ps1` seeds `.state/migrated` to the highest existing migration number so historical bash migrations don't run when `git pull` triggers `post-merge` via Git Bash. New migrations added later still run on Windows via Git Bash, so they should be written defensively (e.g., guard tmux/keychain steps with `command -v` checks) so they no-op cleanly on Windows.
