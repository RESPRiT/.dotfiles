#!/bin/sh
# UserPromptSubmit: if the working directory has moved away from this session's
# launch "homebase" (recorded by session-start-cwd-anchor.sh), report the
# current cwd each turn; silent while still at the homebase.
#
# Why: the session-start "Primary working directory" line is the agent's only
# cwd anchor, and it goes stale the moment a deliberate `cd` moves the homebase
# (entering a worktree, switching repos). Worse, a `cd` into a subdirectory of
# the launch tree persists with NO native notice (only escaping the tree prints
# "Shell cwd was reset"). This is the BACKSTOP to pretool-cd-guard.sh's
# prevention: whatever drift slips past the guard (a `cd` via eval/bash -c, a
# loop body) still surfaces here so relative paths are never resolved blind.
#
# Anchor is per-session at ~/.claude/cwd-anchor/<session_id>. If it's missing
# (a session that predates the anchor hook), we seed it from the current cwd and
# stay silent rather than guess.
#
# stdout from a UserPromptSubmit hook is injected into the model's context, so
# the line below becomes guidance the assistant sees.

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0
[ -n "$sid" ] || exit 0

dir="$HOME/.claude/cwd-anchor"
f="$dir/$sid"
if [ ! -f "$f" ]; then
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$cwd" > "$f" 2>/dev/null || true
  exit 0
fi

anchor=$(cat "$f" 2>/dev/null)
[ -n "$anchor" ] || exit 0
[ "$cwd" != "$anchor" ] || exit 0

printf 'cwd: working directory is now %s (moved from this session launch dir %s). Relative paths resolve here, not the launch dir; prefer absolute paths. Expected if you deliberately changed workspace (a worktree or another repo); otherwise treat as drift to correct.\n' "$cwd" "$anchor"
exit 0
