#!/bin/sh
# Stop hook: record the wall-clock time of the session's most recent Stop.
#
# Fires on every Stop event. When some other Stop hook blocks the stop and
# demands continued work, this file is simply overwritten by the next Stop,
# so it converges to the time of the last message the user actually sees.
# The statusline (statusline-command.local.sh) reads it to display a
# "last message at HH:MM:SS" segment after the session id.
#
# File format: "<epoch> <HH:MM:SS> <TZ>" — epoch kept for staleness logic.

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session_id" ] || exit 0

dir="$HOME/.claude/last-stop"
mkdir -p "$dir"
printf '%s %s %s\n' "$(date +%s)" "$(date +%H:%M:%S)" "$(date +%Z)" > "$dir/$session_id"

# Prune entries from long-dead sessions.
find "$dir" -type f -mtime +7 -delete 2>/dev/null

exit 0
