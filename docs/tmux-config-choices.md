---
topic: tmux config choices
created: 2026-04-08
columns: [Status Quo, Proposed Change, Reasoning, Decision]
---

# tmux config choices

Decision doc for what to add to `~/.dotfiles/tmux.conf`. The current file only sets up true color and the local-override `if-shell` line — every item below is a proposed addition or change on top of that.

**Status:** RESOLVED on 2026-04-08. All 27 items walked, decisions applied to `tmux.conf` and `install.sh`.

## Prefix and core ergonomics

Foundational behavior: prefix key, mouse, scrollback, indices, timing.

### #1 Prefix key

**Status Quo:** Default `C-b`. Awkward two-finger reach; conflicts with vim's page-up.

**Proposed Change:** Rebind to `C-a` (`set -g prefix C-a`, `unbind C-b`, `bind C-a send-prefix`).

**Reasoning:** Most common alternative; one-finger from home row. Tradeoff: clobbers readline `beginning-of-line`. Alternative `C-Space` avoids the readline conflict but is two-finger. Pick one.

**Decision:** SKIPPED — keep default `C-b`.

### #2 Mouse support

**Status Quo:** Mouse off by default — can't click panes, scroll, or drag-resize.

**Proposed Change:** `set -g mouse on`.

**Reasoning:** Modern default. Click to focus pane/window, scroll to enter copy mode and navigate, drag pane borders to resize. No real downside.

**Decision:** APPLIED.

### #3 Scrollback history

**Status Quo:** `history-limit` defaults to 2000 lines per pane.

**Proposed Change:** `set -g history-limit 50000`.

**Reasoning:** 2k is too small for inspecting build/log output. 50k is generous but cheap (a few MB per pane at most).

**Decision:** APPLIED.

### #4 Window/pane index base

**Status Quo:** Windows and panes start at `0`.

**Proposed Change:** `set -g base-index 1` and `setw -g pane-base-index 1`.

**Reasoning:** The `0` key is far from `1` on the keyboard. Starting at 1 means `<prefix> 1` jumps to the first window without a pinky stretch.

**Decision:** APPLIED.

### #5 Renumber on close

**Status Quo:** When a window closes, the remaining windows keep their original numbers, leaving gaps (e.g., 1, 2, 4, 5).

**Proposed Change:** `set -g renumber-windows on`.

**Reasoning:** Keeps window numbers contiguous so `<prefix> N` always lines up with visual position.

**Decision:** APPLIED.

### #6 Escape time

**Status Quo:** `escape-time` defaults to 500ms — tmux waits half a second after `<Esc>` to see if it's part of a function-key sequence.

**Proposed Change:** `set -sg escape-time 0` (or 10ms for safety on slow links).

**Reasoning:** The default 500ms makes vim's `<Esc>` feel laggy. Modern terminals don't need the wait.

**Decision:** APPLIED as `set -sg escape-time 10`. Discussed: 10ms gives a small safety buffer over 0 with no perceptible latency cost. Sufficient for vim-style use; insufficient for emacs Esc-prefix meta-keying (not a workflow we use).

### #7 Focus events

**Status Quo:** Off — vim/nvim inside tmux can't detect when their pane gains/loses focus.

**Proposed Change:** `set -g focus-events on`.

**Reasoning:** Lets vim's `:checktime` / autoread fire when you switch back to its pane. Harmless if unused.

**Decision:** APPLIED.

## Reload and key bindings

Bindings that improve iteration speed and muscle memory.

### #8 Reload binding

**Status Quo:** No reload binding — must run `tmux source-file ~/.tmux.conf` from a shell.

**Proposed Change:** `bind r source-file ~/.tmux.conf \; display "Reloaded"`.

**Reasoning:** `<prefix> r` reloads the config and flashes confirmation. Essential while iterating on this very file.

**Decision:** APPLIED.

### #9 Split bindings

**Status Quo:** Default splits are `%` (vertical) and `"` (horizontal). Unmemorable; new panes start in `$HOME`, not the current pane's directory.

**Proposed Change:** `bind \| split-window -h -c "#{pane_current_path}"` and `bind - split-window -v -c "#{pane_current_path}"`. Replace the defaults (don't keep both).

**Reasoning:** `|` and `-` visually mirror the resulting split. Inheriting cwd is what you almost always want — splitting a pane to run a related command in the same project.

**Decision:** APPLIED. Default `%` and `"` bindings unbound.

### #10 New window cwd inheritance

**Status Quo:** `<prefix> c` opens a new window in `$HOME`.

**Proposed Change:** `bind c new-window -c "#{pane_current_path}"`.

**Reasoning:** Same logic as #9 — new windows almost always belong in the same project as the current one.

**Decision:** APPLIED.

### #11 Vim-style pane navigation

**Status Quo:** Default pane navigation is `<prefix>` then arrow keys.

**Proposed Change:** `bind h select-pane -L`, `bind j select-pane -D`, `bind k select-pane -U`, `bind l select-pane -R`.

**Reasoning:** You have a vimrc — h/j/k/l muscle memory should carry over. Arrow keys still work; this just adds the vim bindings.

**Decision:** SKIPPED — keep arrow-key navigation.

### #12 Pane resize bindings

**Status Quo:** Resize requires `<prefix> :resize-pane -L 5` or click-drag.

**Proposed Change:** `bind -r H resize-pane -L 5` and the same for J/K/L. The `-r` flag makes them repeatable without re-pressing prefix.

**Reasoning:** Convenient when fine-tuning a layout. Capital letters avoid clashing with the lowercase navigation in #11.

**Decision:** SKIPPED — tmux's default `<prefix> Ctrl-arrow` / `<prefix> Alt-arrow` plus mouse-drag border (#2) cover the use case. Resize is rare enough that an extra dedicated binding isn't worth muscle-memory cost.

## Copy mode and clipboard

How selection, yank, and clipboard integration work.

### #13 vi keys in copy mode

**Status Quo:** `mode-keys` defaults to `emacs` — copy mode uses emacs movement.

**Proposed Change:** `setw -g mode-keys vi`.

**Reasoning:** Vim muscle memory in copy mode (h/j/k/l, w/b, /, n, G, gg). Required for #14 and #15 to feel natural.

**Decision:** APPLIED.

### #14 Visual selection binding

**Status Quo:** Selection in copy mode starts with `Space` (after #13).

**Proposed Change:** `bind -T copy-mode-vi v send -X begin-selection`.

**Reasoning:** Matches vim's `v` for visual mode. Pure muscle memory.

**Decision:** APPLIED. tmux-yank does not bind `v`, so no conflict.

### #15 Yank to system clipboard

**Status Quo:** Default `y` in copy-mode-vi yanks to tmux's internal buffer only — not the OS clipboard.

**Proposed Change:** `bind -T copy-mode-vi y send -X copy-pipe-and-cancel "pbcopy"`.

**Reasoning:** Lets you yank in tmux and paste with Cmd+V anywhere on macOS. Hard-codes `pbcopy` — see #16 for the cross-platform variant.

**Decision:** APPLIED via tmux-yank plugin + `set -g set-clipboard on`. Plugin handles `y`/`Y`/mouse-drag yank, OS detection (mac/Linux X11/Wayland), and OSC 52 fallback over SSH. `set-clipboard on` ensures tmux's built-in copy paths also emit OSC 52.

### #16 Cross-platform clipboard

**Status Quo:** Item #15 hard-codes `pbcopy`, which fails on Linux.

**Proposed Change:** Detect OS via `if-shell` and bind to `pbcopy` on macOS, `xclip -selection clipboard -i` or `wl-copy` on Linux.

**Reasoning:** Matches the cross-platform spirit of `install.sh`. Adds ~5 lines of conditional config. Skip if you only ever tmux on macOS.

**Decision:** SUBSUMED by #15 — tmux-yank's auto-detection replaces the hand-rolled `if-shell` block.

## Status bar

Visual layout and styling of the bottom (or top) bar.

### #17 Status bar position

**Status Quo:** Default `bottom`.

**Proposed Change:** Keep `bottom` (`set -g status-position bottom`).

**Reasoning:** Bottom is conventional and matches vim's status line. Top is occasionally argued for (closer to terminal title) but rarely worth the muscle-memory cost.

**Decision:** APPLIED.

### #18 Status bar content

**Status Quo:** Default shows session name on the left, window list center, time/date on the right.

**Proposed Change:** Left: `[#S]` (session name). Center: window list. Right: `#h %H:%M` (hostname + time).

**Reasoning:** Minimal but useful. Hostname on the right disambiguates SSH sessions at a glance. Could add battery/load/git but those need scripts or plugins — out of scope for a pure-config setup.

**Decision:** APPLIED with date kept (Option 2 + ISO date). Right side: `#h %H:%M %Y-%m-%d`. ISO date format chosen for developer convention.

### #19 Status bar colors

**Status Quo:** Default green status bar — doesn't match the rest of the visual identity.

**Proposed Change:** Background using `colour117` (the same light blue as the local prompt in `zshrc:29`), with `colour114` (light green) when inside SSH (mirrors `zshrc:26-30`).

**Reasoning:** Visual consistency with the shell prompt. Same SSH cue means you know you're remote whether you look at the prompt or the status bar.

**Decision:** APPLIED via `if-shell '[ -n "$SSH_CONNECTION" ]'` brace block setting both `status-style` and `pane-active-border-style`.

### #20 Pane border colors

**Status Quo:** Default gray borders for all panes — hard to tell which is active.

**Proposed Change:** `set -g pane-border-style fg=colour240` (dim) and `set -g pane-active-border-style fg=colour117` (light blue, matching the prompt).

**Reasoning:** Active pane stands out at a glance. Pairs visually with #19.

**Decision:** APPLIED. Active border uses the same SSH-conditional color as the status bar (#19).

## Plugins

Whether to introduce TPM and any plugins.

### #21 Use TPM (tmux plugin manager)

**Status Quo:** No plugin manager. Repo is plugin-free except for vim-colors-solarized in `install.sh:96`.

**Proposed Change:** Skip TPM. Keep tmux.conf hand-rolled.

**Reasoning:** The repo's style is minimal, single-file configs. Plugins add an install step, a network dep, and a layer of indirection. Revisit only if a specific plugin proves essential.

**Decision:** OVERRIDDEN — installed. `install.sh` clones TPM to `~/.tmux/plugins/tpm` and runs `install_plugins` idempotently.

### #22 tmux-resurrect

**Status Quo:** No session persistence — tmux state is lost on reboot.

**Proposed Change:** Skip unless you actively want session restore.

**Reasoning:** Requires TPM (see #21). Most useful for people who keep long-lived sessions across reboots; less useful if you spin up fresh tmux per project.

**Decision:** OVERRIDDEN — installed via TPM (`set -g @plugin 'tmux-plugins/tmux-resurrect'`).

### #23 tmux-yank

**Status Quo:** No plugin-based clipboard integration.

**Proposed Change:** Skip — items #15/#16 cover clipboard yank without a plugin.

**Reasoning:** Hand-rolled bindings are simpler and don't require TPM.

**Decision:** OVERRIDDEN — installed via TPM. Resolved via #15: tmux-yank handles macOS/Linux/Wayland auto-detection and OSC 52 SSH fallback.

## Cross-platform and SSH

Portability concerns and remote-session affordances.

### #24 Linux support

**Status Quo:** Repo's shell rcs work on both macOS and Linux.

**Proposed Change:** Tmux config should match — guard platform-specific bits (e.g., `pbcopy` in #15) with `if-shell` so the same file works on both.

**Reasoning:** Consistency with the rest of the dotfiles. Cost is small (a few `if-shell` blocks). Skip if you genuinely never use Linux.

**Decision:** APPLIED — mostly handled automatically by tmux-yank. The remaining `if-shell` SSH detection (#19) works identically on both platforms.

### #25 SSH visual cue

**Status Quo:** No visual difference between local and SSH tmux sessions.

**Proposed Change:** When tmux starts inside an SSH session, color the status bar with the SSH color (`colour114`) instead of the local color (`colour117`).

**Reasoning:** Mirrors `zshrc:26-30` so the visual cue is consistent across shell prompt and tmux status bar. Subtle but useful for spotting "wait, this is the prod box" before running something destructive.

**Decision:** SUBSUMED by #19. Whole-bar color change already provides the SSH cue; no separate marker needed.

## File organization

How the config is laid out on disk.

### #26 Single file vs directory

**Status Quo:** `tmux.conf` is a single file at the repo root.

**Proposed Change:** Stay single-file. Revisit splitting into `tmux/` only if it grows past ~150 lines.

**Reasoning:** Matches the repo's other configs (zshrc, bashrc, vimrc are all single files). Splitting prematurely adds friction without benefit.

**Decision:** APPLIED — tmux.conf remains a single file at the repo root.

### #27 Comment section headers

**Status Quo:** Current file has minimal comments.

**Proposed Change:** Group new bindings under comment headers like `# --- Prefix ---`, `# --- Splits ---`, etc.

**Reasoning:** Makes the file scannable as it grows. Cheap to add now, painful to retrofit later.

**Decision:** APPLIED — sections grouped as `# --- Core options ---`, `# --- Key bindings ---`, `# --- Copy mode ---`, `# --- Status bar ---`, `# --- Plugins (managed by TPM) ---`, `# --- Local override ---`.
