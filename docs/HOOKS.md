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
