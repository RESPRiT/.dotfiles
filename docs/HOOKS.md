# Claude Code hooks

Claude Code hooks are registered in `~/.claude/settings.json`. That file is **not** managed by this dotfiles repo — it's a real file per machine, not a symlink. See CLAUDE.md "Known gap" note under *Local override pattern*.

This doc captures the hook-related conventions and any pieces that need to be reproduced by hand on a new machine until the settings-file format supports layering.

## Resume-hint plumbing (machine-local)

The `claude()` wrapper in `shellrc` prints a resume hint (`claude --resume <sid>`) after a non-tmux-launched claude session exits. It gets the session ID from a `SessionEnd` hook that writes the JSON payload Claude Code sends on stdin into the path in `$CLAUDE_EXIT_FILE` (exported into the tmux environment by the wrapper itself).

Because the primary `SessionEnd` hook dispatches to `~/.metacog/hooks/dispatch.sh`, which is currently short-circuited by a `exit 0` GAMMA gate (and historically never wrote to `$CLAUDE_EXIT_FILE` anyway), the wrapper cannot rely on that handler. The workaround is a second `SessionEnd` entry in `~/.claude/settings.json` that does nothing but capture stdin:

```json
"SessionEnd": [
  { "hooks": [ { "type": "command", "command": "~/.metacog/hooks/dispatch.sh SessionEnd" } ] },
  { "hooks": [ { "type": "command", "command": "[ -n \"$CLAUDE_EXIT_FILE\" ] && cat > \"$CLAUDE_EXIT_FILE\"" } ] }
]
```

### Reproducing on a new machine

Since `~/.claude/settings.json` is not symlinked from this repo, a fresh machine will not have the capture hook. To restore resume-hint output:

1. Open `~/.claude/settings.json`.
2. Find the `SessionEnd` array under `hooks`.
3. Append the capture entry shown above (the one that `cat`s stdin into `$CLAUDE_EXIT_FILE`).

### When this can go away

Two paths out:

- Claude Code gains layered settings (a `settings.local.json`-style include merged into `settings.json`). At that point this hook can be committed to `claude-global/` and symlinked like the other settings files.
- The metacog dispatcher's `SessionEnd` handler starts writing to `$CLAUDE_EXIT_FILE` directly (once the GAMMA gate at `dispatch.sh:18` is lifted). Then the second entry becomes redundant.
