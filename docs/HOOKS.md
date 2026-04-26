---
tracks:
  - claude-global/settings.json
  - claude-global/merge-settings.sh
  - claude-global/hooks/docs-refs.py
  - claude-global/hooks/docs-refs-notify.py
  - shellrc
  - ~/.claude/settings.json
  - ~/.claude/settings.local.json
---

# Claude Code hooks

Claude Code hooks are declared in `claude-global/settings.json` (the canonical base) and merged into `~/.claude/settings.json` at install/post-merge time by `claude-global/merge-settings.sh`. Per-machine hook overrides go in `~/.claude/settings.local.json` — object arrays concat under the merge rules, so an overlay can add hooks without replacing the base list. See CLAUDE.md *Local override pattern* → "Claude Code settings (special case)" for the full merge semantics.

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

Because the hook lives in the committed base, fresh machines pick it up automatically the first time `merge-settings.sh` runs — no manual reproduction step.

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
