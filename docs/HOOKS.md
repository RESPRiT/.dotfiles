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

A `PostToolUse` hook on `Edit|Write|MultiEdit` (`claude-global/hooks/docs-refs-notify.py`) checks whether the file the agent just touched is referenced by any tracked markdown doc. If so, it emits `hookSpecificOutput.additionalContext` listing the affected docs and suggesting a delegation to a haiku subagent for the "what specifically needs updating" pass. The agent decides whether the change actually warrants a doc edit — most won't, and the cheap-glance/expensive-delegate split keeps cost down vs. running a Haiku on every edit.

**Reference extraction** (`claude-global/hooks/docs-refs.py`): scans `.md` files in the configured directories for two kinds of refs:

1. Backtick-quoted tokens in the body that resolve to an existing file or directory. The "must exist" filter eliminates the noise from command examples, env vars, and code snippets that share backticks with real path references.
2. YAML frontmatter `tracks:` (inline `[a, b]` or block list form). Same resolution rules; entries that don't resolve yet are dropped but will start matching as soon as the path exists, which makes it useful for declaring intent before a file is created.

Resolution attempts in order: absolute (after `~`-expansion), then relative to the doc's parent directory, then — if the doc lives under a `docs/` subtree — relative to that `docs/`'s parent (the natural project root).

**Default scan dirs:** `$PWD/docs` and `~/.docs`, each only if it exists. The hook runs the scanner with the agent's reported `cwd`, so `$PWD/docs` follows whichever repo Claude is operating in. Override per call by passing `--dir` to `docs-refs.py` directly.

**Filters before notifying:**

- *mtime gate*: skip docs whose mtime is `>=` the touched file's mtime. The doc is at least as fresh as the change, so it's not stale by definition.
- *session dedupe*: keep a state file at `${TMPDIR}/claude-docs-refs-<session_id>.notified` containing `<doc>|<file>|<doc_mtime>` keys. Repeated edits to the same file within one session don't re-nag *unless* the doc's mtime has advanced (i.e., the agent updated the doc, then changed the file again — in which case re-notify is correct).

**Limitations:**

- Only fires on `Edit|Write|MultiEdit`. File mutations via `Bash` (`mv`, `sed -i`, code generators, etc.) are not currently observed.
- Directory references match any file under them, but symlink traversal beyond `Path.resolve()` is not specially handled.
- Backtick-extraction can miss multi-token paths (e.g. `` `path with spaces.txt` `` resolves; `` `path` ` with spaces.txt` `` does not).
