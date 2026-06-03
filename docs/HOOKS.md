---
tracks:
  - claude-global/settings.json
  - claude-global/merge-settings.sh
  - claude-global/hooks/remerge-on-settings-edit.sh
  - claude-global/hooks/session-start-drift-check.sh
  - claude-global/hooks/session-start-tmux-rename.sh
  - claude-global/hooks/user-prompt-terminal-size.sh
  - claude-global/hooks/term-fit-budget.sh
  - claude-global/hooks/stop-terminal-size.py
  - claude-global/hooks/user-prompt-git-remote.sh
  - claude-global/hooks/docs-refs.py
  - claude-global/hooks/docs-refs-notify.py
  - shellrc
  - ~/.claude/settings.json
  - ~/.claude/settings.local.json
---

# Claude Code hooks

Claude Code hooks are declared in `claude-global/settings.json` (the canonical base) and merged into `~/.claude/settings.json` by `claude-global/merge-settings.sh`. The merge script is non-destructive by default: clean cases propagate (no-ops, first-run writes, intentional base/overlay edits, cosmetic-only drift), out-of-band drift from Claude Code's own writers (`/plugin`, `/config`, `/permissions`, settings UI) is **auto-reconciled into the overlay** when expressible (additions, scalar overrides — verified by re-merging the candidate and comparing to dest), and only the residual case where overlay can't express the drift (typically a removal from a base array) exits 3 with a `DRIFT:` line on stderr. Four triggers re-run it: `install.sh` passes `--force` because the user explicitly invoked it (auto-reconcile still runs first; `--force` only matters for the residual case); `hooks/post-merge` (after `git pull`) runs without `--force` so a base update propagates cleanly via case 4 and any irreconcilable dest drift is surfaced to the next session instead of clobbered (would otherwise silently lose the user's `/plugin`, `/config`, `/permissions` changes between pulls); the in-session `claude-global/hooks/remerge-on-settings-edit.sh` (PostToolUse on agent base/overlay edits) and `claude-global/hooks/session-start-drift-check.sh` (SessionStart) also run without `--force`. All three non-forcing triggers surface `RECONCILED:` and `DRIFT:` notices via `additionalContext`, with the key-sorted JSON diff (snapshot → dest, key-sorted via `jq -S` so cosmetic reordering by Claude Code's writer doesn't appear as noise) inlined so the agent has the change in hand — the former so the user can catch accidental promotions (audit trail in `.state/claude-settings-reconcile.log`), the latter so the agent reconciles with the user. Per-machine hook overrides go in `~/.claude/settings.local.json` — object arrays concat under the merge rules, so an overlay can add hooks without replacing the base list. See CLAUDE.md *Local override pattern* → "Claude Code settings (special case)" for the full state machine.

## Resume-hint plumbing

The `claude()` wrapper in `shellrc` prints a resume hint (`claude --resume <sid>`) after a non-tmux-launched session exits. It pulls the session ID from a hook that writes Claude Code's stdin payload into the path in `$CLAUDE_EXIT_FILE` (exported into the tmux environment by the wrapper itself):

```json
"SessionStart": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "sh -c 'test -n \"$CLAUDE_EXIT_FILE\" && cat > \"$CLAUDE_EXIT_FILE\"'"
      }
    ]
  }
]
```

`SessionStart`, not `SessionEnd` — the latter empirically missed the `--resume` case, while `SessionStart` fires reliably for `claude -c`, `--resume`, `/clear`, and compact. The hook overwrites the file on each fire, so the captured session ID is always the most recent one (post-`/clear` or post-compact, if applicable).

A sibling `SessionStart` hook (`claude-global/hooks/session-start-tmux-rename.sh`) reuses the same `CLAUDE_EXIT_FILE`-set signal to detect wrapper-launched tmux and renames the session from its placeholder `claude-$$` (shell PID) to `claude-<first 8 chars of session_id>`, so the real Claude id surfaces in tmux's session list and `choose-tree` picker. It re-fires on `/clear`, `/compact`, and `--resume` so the title always tracks the currently resumable id. Rename failures (8-char prefix collision with another wrapper session) are swallowed and the placeholder name stays.

Because the hooks live in the committed base, fresh machines pick them up automatically the first time `merge-settings.sh` runs — no manual reproduction step.

## Terminal-fit hint

A `UserPromptSubmit` hook (`claude-global/hooks/user-prompt-terminal-size.sh`) measures the current terminal via tmux and emits a recommended line/word budget for the assistant's end-of-turn message, so the final user-facing reply fits the visible window without scrolling. `UserPromptSubmit` stdout is injected into the turn's context, so the echoed text becomes guidance the model sees.

It measures the pane Claude renders into — `tmux display-message -p -t "$TMUX_PANE" '#{pane_width} #{pane_height}'` — rather than the client, since the pane is the area Claude actually paints. The measurement and budget math live in a shared helper, `claude-global/hooks/term-fit-budget.sh`, which prints `cols rows avail_lines max_words usable_cols` on one line (nothing when unmeasurable). Both this pre-turn hint and the post-turn check (below) source their numbers from it, so the budget the agent is *told* and the budget it's *checked against* can't drift.

**Rendered lines is the governing constraint, words are secondary.** `avail_lines = rows − CLAUDE_TERM_FIT_RESERVED_ROWS` (default 10). The reserved count covers the TUI chrome — input box (3 rows: two borders + the input line), status line, mode hint, the `✻ Crunched for Xs` completion stat line, and surrounding blanks — measured empirically with `tmux capture-pane -p` (the fixed bottom chrome is 5 rows; the input box grows by a row per wrapped line of the user's typed prompt, which the static reserve can't predict, hence a couple rows of margin). The hint states `avail_lines` as a *rendered*-line limit, explicitly counting the blank lines markdown inserts between paragraphs and list items — a reply can sit at its word budget yet overflow because airy formatting spends rows on whitespace.

The word figure is a softer sanity check: `avail_lines × ((cols − CLAUDE_TERM_FIT_GUTTER_COLS) / CLAUDE_TERM_FIT_CHARS_PER_WORD) × CLAUDE_TERM_FIT_FILL_PCT / 100`. Defaults: gutter 2 (the TUI's left content indent), 6 chars per word incl. trailing space, fill 55% (the fraction of a line real markdown fills after blanks/short lines — the original full-packing assumption over-permitted, e.g. a 510-word reply rendering to ~50 rows against a 35-line budget). All tunables are read from the environment, so a machine with different chrome can override via shell or settings `env` without forking the script.

**Verbosity (full once, compact after).** The first prompt of a session emits a full message explaining what the hint is and how to read the compact form; every prompt after emits a self-describing one-liner (`term-fit: 87x45 -> final reply <=35 rendered lines (~269 words); …`), kept self-describing so it still reads correctly if context compaction drops the preamble. "First" is tracked per session via a marker file `${TMPDIR:-/tmp}/claude-term-fit-<session_id>.seen` — same `$TMPDIR`/session-id pattern as the docs-refs notifier. `session_id` is parsed from the stdin payload without jq; if it can't be parsed the hook falls back to the compact form rather than re-explaining every turn.

Guards: no-op (exit 0, no output) when `$TMUX` is unset or `tmux` is absent — outside tmux there's no reliable size to report — and also if tmux returns non-numeric dimensions. The budget is framed as a soft target for the final reply only (not tool output or intermediate steps), explicitly overridable when the task needs more.

**Post-turn check (the read-only warning).** The hint above is advisory — the model can still overshoot. `claude-global/hooks/stop-terminal-size.py` is the `Stop` counterpart: when the turn ends it reads the transcript, finds the turn's final reply, estimates its rendered line count (each source line costs ≥1 row; long lines add a row per soft wrap at `usable_cols`; blank lines count, mirroring the "rendered lines" notion), and compares against `avail_lines` from the same helper.

Getting "the final reply" is subtler than it looks because of a **flush race**: a `Stop` hook can fire before the turn's last assistant message is written to the transcript, so the last entry at that instant is still the *pre-tool-call* text (which carries a `tool_use` block) — naively reading "the last text block" measures the wrong, earlier message (observed: a 41-line reply read as 1 line). `final_reply_text()` defends against this by polling (up to 2s, 50ms steps) until the last assistant entry is text-bearing **and** free of `tool_use` — i.e. a terminal reply — then measuring that. Turns that legitimately end on a tool call never satisfy the gate and fall through to "no reply to measure" at timeout, which is correct (nothing user-facing to warn about). See `~/.docs/claude/hooks.md` for the general lesson.

The warning is deliberately **read-only**, which dictates a two-hook handoff rather than acting at `Stop` time. A `Stop` hook can only reach the model via `{"decision":"block",…}`, and blocking *forces a revision that appends more text below the already-painted reply* — it can't retract what's on screen, so for a "fits the window" goal a block can make the turn longer, not shorter. To stay non-coercive, the Stop hook instead writes a marker file `${TMPDIR:-/tmp}/claude-term-fit-overflow-<session_id>.warn` containing `used avail cols rows` (and emits nothing). The **next** `UserPromptSubmit` (in `user-prompt-terminal-size.sh`, before the budget bail so it shows even if that turn can't measure) reads the marker, prints a one-line heads-up — `term-fit warning: your previous reply ran ~79 rendered lines vs the 30-line budget (158x40) — over by ~49. … ignore this if that turn genuinely warranted the length` — and deletes it (consume-once). Because `UserPromptSubmit` stdout is injected as plain turn context, the agent simply *sees* the warning and may freely ignore it for a justified one-off; nothing is forced, and no extra text is appended to the offending turn.

When the reply fits, the Stop hook instead removes any stale marker (so an old overflow doesn't warn after a later good turn). It no-ops entirely when not in tmux (helper prints nothing), when the transcript can't be read, or when there's no `session_id` to key the marker on. Tradeoff of the deferral: the warning lands at the start of the *next* turn, and a session's very last reply goes unwarned (no next turn to carry it).

## Git remote-status hint

A `UserPromptSubmit` hook (`claude-global/hooks/user-prompt-git-remote.sh`) keeps the session's repo aware of remote state, so the assistant doesn't assume the local branch (or `main`) is current when it has fallen behind `origin`. Each turn it (a) fires a throttled `git fetch` for the repo the session's `cwd` lives in, and (b) reads the now-cached remote-tracking refs and, **only when behind/diverged**, injects a one-line summary (`git: local main is 5 commits behind origin/main …`) into the turn's context. `git fetch` only updates remote-tracking refs — never the working tree, index, or current branch — so it's safe to run against any repo unprompted. This is the agent-facing half of the design; the shell prompt and statusline are intentionally left untouched for now.

**Throttle.** The fetch runs at most once per `CLAUDE_GIT_FETCH_TTL_MIN` minutes (default 5), gated by the mtime of a stamp file in the repo's *common* git dir (`<common>/.last-autofetch`). The stamp is `touch`ed **before** the fetch so a slow/flaky network can't make every turn re-fetch (a failed fetch still costs only one attempt per interval), and so sibling worktrees of the same repo share one gate — their remote-tracking refs are shared, so a single fetch serves them all. Staleness is tested with `find "$stamp" -mmin +N`, which both BSD (macOS) and GNU `find` support.

**Timing.** On the turn the throttle opens, the fetch runs **inline** under a short cap (`CLAUDE_GIT_FETCH_TIMEOUT`, default 3s, via the same `timeout`→`gtimeout`→`perl alarm` chain as shellrc's `_with_timeout`, inlined since the hook doesn't source shellrc) so the reported numbers are fresh from the first message. Every other turn reads cached refs with no network and near-zero latency.

**Worktrees.** `cwd` may be a linked worktree, where `.git` is a file, not a directory. The repo is resolved via `git -C "$cwd"` and the stamp via `--git-common-dir` (made absolute), so both the throttle and the report work from the main checkout or any worktree. `main` vs `origin/main` is readable from a worktree on a feature branch because those refs are shared — which is exactly the "on a feature branch, assumed main was current" blind spot this addresses.

**What it reports.** Current branch vs its upstream (`rev-list --left-right --count HEAD...@{u}`): `N behind`, or `N ahead, M behind` when diverged; ahead-only is silent. Separately, `<default> vs origin/<default>` (default branch from `origin/HEAD`, falling back to `main` then `master`) is reported **only when not already on the default branch** — otherwise the upstream check already covered it. Guards → silent no-op (exit 0): git unavailable, `cwd` missing/not a work tree, detached HEAD or no upstream (for the branch clause), and up-to-date.

## Docs-refs notifier

A `PostToolUse` hook on `Edit|Write|MultiEdit` (`claude-global/hooks/docs-refs-notify.py`) emits up to two diagnostics as a single `hookSpecificOutput.additionalContext` message:

1. **Stale docs** — other markdown docs whose `tracks:` block names the touched file (or a directory containing it) and whose mtime is older than the file's. The agent decides whether the change actually warrants a doc edit; most won't, and the cheap-glance / expensive-delegate split keeps cost down vs. running a Haiku on every edit.
2. **Missing `tracks:`** — if the touched file is itself a markdown doc inside a scan dir but has no `tracks:` frontmatter, point at `docs/HOOKS.md` and ask the agent to add one. Without it the doc opts out of stale-detection silently, which is the failure mode that motivated the explicit-only design.

**Reference declaration** (`claude-global/hooks/docs-refs.py`): each doc declares the files and directories it covers via a YAML frontmatter `tracks:` block. Inline (`tracks: [a, b]`) and block (`tracks:\n  - a\n  - b`) forms are both accepted. An earlier version also auto-extracted backtick-quoted tokens from the body, but generic terms like `` `docs/` `` resolved to existing directories and matched every sibling file, so that was removed in favor of explicit declaration.

Resolution attempts per entry, in order: absolute (after `~`-expansion), then relative to the doc's parent directory, then — if the doc lives under a `docs/` subtree — relative to that `docs/`'s parent (the natural project root). Entries that don't resolve to an existing path are dropped silently but will start matching as soon as the path exists, which is useful for declaring intent before a file is created.

**Default scan dirs:** `$PWD/docs` and `~/.docs`, each only if it exists. The hook runs the scanner with the agent's reported `cwd`, so `$PWD/docs` follows whichever repo Claude is operating in. Override per call by passing `--dir` to `docs-refs.py` directly.

**Filters before notifying:**

- *mtime gate* (stale-docs only): skip docs whose mtime is `>=` the touched file's mtime. The doc is at least as fresh as the change, so it's not stale by definition.
- *session dedupe*: keep a state file at `${TMPDIR}/claude-docs-refs-<session_id>.notified`. Stale-doc keys are `<doc>|<file>|<doc_mtime>` — repeated edits to the same file don't re-nag *unless* the doc's mtime has advanced (i.e., the agent updated the doc, then changed the file again — in which case re-notify is correct). Missing-`tracks:` keys are `notracks|<doc>` — one nag per doc per session, regardless of subsequent edits or whether the agent eventually adds the block.

**Limitations:**

- Only fires on `Edit|Write|MultiEdit`. File mutations via `Bash` (`mv`, `sed -i`, code generators, etc.) are not currently observed.
- Directory references match any file under them, but symlink traversal beyond `Path.resolve()` is not specially handled.
- A doc that forgets its `tracks:` block won't be flagged for any change, which is a sharper edge than the old auto-discover behavior — the tradeoff is no false positives.
