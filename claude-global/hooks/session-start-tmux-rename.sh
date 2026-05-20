#!/bin/sh
# SessionStart: rename the wrapping tmux session to claude-<sid8> so the
# Claude session id shows up in tmux's session list and choose-tree picker.
#
# Only fires when the shellrc claude() wrapper launched tmux (signaled by
# CLAUDE_EXIT_FILE being set on the tmux session env). When the user runs
# claude inside their own tmux session, CLAUDE_EXIT_FILE is unset and we
# no-op so manually-named sessions are left alone.
#
# Re-runs on /clear, /compact, and --resume since each fires SessionStart
# with a new session_id; the title tracks the currently resumable id.

[ -n "$CLAUDE_EXIT_FILE" ] || exit 0
[ -n "$TMUX" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Each SessionStart hook gets an independent copy of the JSON payload on
# stdin. Parse session_id without jq for portability.
sid=$(grep -o '"session_id":"[^"]*"' | head -1 | sed 's/.*://;s/"//g')
[ -n "$sid" ] || exit 0

short=$(printf '%.8s' "$sid")
# rename-session fails with "duplicate session" if another wrapper already
# claimed this 8-char prefix; swallow and keep the existing claude-$$ name.
tmux rename-session "claude-$short" 2>/dev/null || true
