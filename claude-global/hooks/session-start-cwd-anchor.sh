#!/bin/sh
# SessionStart: record this session's launch directory -- the "homebase" anchor
# -- so user-prompt-cwd-report.sh can tell, each turn, whether the working
# directory has since moved. Keyed by session_id under ~/.claude/cwd-anchor/,
# mirroring the per-session file pattern used by last-stop/<sid>.
#
# No-ops cleanly without jq or a parseable payload. Wired via the SessionStart
# matcher in claude-global/settings.json.

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || exit 0

dir="$HOME/.claude/cwd-anchor"
mkdir -p "$dir" 2>/dev/null || true
printf '%s\n' "$cwd" > "$dir/$sid" 2>/dev/null || true
exit 0
