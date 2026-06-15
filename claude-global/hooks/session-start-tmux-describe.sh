#!/bin/sh
# SessionStart: tell the agent which tmux session it's running in, so it can
# refer to the session by name -- e.g. suggest `tmux attach -t <name>` to the
# user, or drive other panes/windows of the same session.
#
# Naming: when the claude() shellrc wrapper launched us, the wrapping tmux
# session is renamed to claude-<sid8> by session-start-tmux-rename.sh. That
# rename and this hook both fire on SessionStart and may run concurrently, so
# rather than read the possibly-not-yet-renamed live name we derive the same
# canonical claude-<sid8> from the session id -- guaranteed to match the final
# name (keep the derivation in sync with session-start-tmux-rename.sh). When
# we're inside the user's *own* tmux session (CLAUDE_EXIT_FILE unset, the
# rename hook no-ops), the name is whatever they chose, so we report it live.
#
# No-ops cleanly outside tmux or without jq. Wired up via the SessionStart
# matcher in claude-global/settings.json.

[ -n "$TMUX" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

if [ -n "$CLAUDE_EXIT_FILE" ] && [ -n "$sid" ]; then
  # Mirrors session-start-tmux-rename.sh: claude- + first 8 chars of the sid.
  name="claude-$(printf '%.8s' "$sid")"
else
  name=$(tmux display-message -p '#S' 2>/dev/null)
fi
[ -n "$name" ] || exit 0

msg="This Claude session is running inside tmux session \"$name\"."

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0
