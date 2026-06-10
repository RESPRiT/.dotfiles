#!/bin/sh
# SessionStart hook: record the wall-clock time the session started.
#
# SessionStart fires on startup but also on resume/clear/compact, so the
# stamp is write-once: if the session already has a file, leave it alone —
# the displayed time stays the *original* start, not the latest resume.
# The statusline (statusline-command.sh) reads it to render a session-start
# [HH:MM TZ] segment. See docs/HOOKS.md.
#
# File format: "<epoch> <HH:MM:SS> <TZ>" — epoch kept for symmetry with
# last-stop and future staleness logic.

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session_id" ] || exit 0

dir="$HOME/.claude/session-start"
mkdir -p "$dir"
file="$dir/$session_id"
[ -f "$file" ] || printf '%s %s %s\n' "$(date +%s)" "$(date +%H:%M:%S)" "$(date +%Z)" > "$file"

# Prune entries from long-dead sessions.
find "$dir" -type f -mtime +7 -delete 2>/dev/null

exit 0
