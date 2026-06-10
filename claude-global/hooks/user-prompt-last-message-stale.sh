#!/bin/sh
# UserPromptSubmit companion to stop-last-message-time.sh: stamp the time
# of the latest prompt to ~/.claude/last-stop/<session_id>.prompt. The
# statusline dims the last-message [HH:MM] while prompt-epoch >= stop-epoch
# (a turn is in flight), and the next Stop's fresher epoch lights it back up.
# No deletion handshake needed — the epoch comparison self-resolves.

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session_id" ] || exit 0

dir="$HOME/.claude/last-stop"
mkdir -p "$dir"
date +%s > "$dir/$session_id.prompt"

exit 0
