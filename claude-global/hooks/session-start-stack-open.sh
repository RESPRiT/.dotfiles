#!/bin/sh
# SessionStart: open the stack TUI pane when the starting session already
# has topics on any of its stacks, so a resumed session comes back with
# its panel while a fresh one stays uncluttered.
#
# The policy lives entirely here — stack just exposes the primitives:
# `stack depth --total` (bare topic count across the session's stacks)
# and `stack tui open` (idempotent spawn). Fires on source=startup and
# source=resume only. /clear rolls a new session id (empty stacks —
# nothing to show), and /compact keeps the session with its panel as-is;
# if the user dismissed the panel, a compaction shouldn't bring it back.
# The session id is passed explicitly from the payload so an empty new
# session never falls back to some other session's stack.
#
# No-ops outside tmux, or on a machine without the stack binary
# (override the lookup with STACK_BIN).

[ -n "$TMUX" ] || exit 0
bin="${STACK_BIN:-stack}"
command -v "$bin" >/dev/null 2>&1 || exit 0

# Each SessionStart hook gets its own copy of the JSON payload on stdin.
# Parse without jq for portability; tolerate whitespace around the colon.
input=$(cat)
sid=$(printf '%s' "$input" | grep -o '"session_id" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
source=$(printf '%s' "$input" | grep -o '"source" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
[ -n "$sid" ] || exit 0
case "$source" in
  startup|resume) ;;
  *) exit 0 ;;
esac

depth=$("$bin" depth --session "$sid" --total 2>/dev/null) || exit 0
[ "$depth" -gt 0 ] 2>/dev/null || exit 0

# A SessionStart hook's stdout is injected into the conversation; the
# panel is a side effect, so keep it silent.
"$bin" tui open --session "$sid" >/dev/null 2>&1 || true
