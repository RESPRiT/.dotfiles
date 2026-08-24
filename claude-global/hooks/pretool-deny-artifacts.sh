#!/bin/sh
# PreToolUse guard (matcher: Artifact): deny publishing Claude Artifacts.
#
# Policy (claude-global/CLAUDE.md): deliverables that want a rendered page are
# written as plain HTML files under /tmp/ and handed to the user by path, never
# published to claude.ai. This hook is the hard enforcement behind that rule —
# the harness guidance the agent sees pushes toward publishing finished work,
# so a prose rule alone loses in long sessions.
#
# Denies `publish`, which is also the tool's default when `action` is omitted,
# for new artifacts and redeploys alike. Every other action (list, read,
# comments, reply, resolve, watch, status, assets) is read-only or acts on an
# artifact that already exists, and passes through. If the action can't be
# parsed (jq missing/failing), the call is denied: unknown defaults to the
# publish path, so failing closed is the safe direction for a prohibition.
#
# Reads the tool input as JSON on stdin; exit 2 blocks the call and feeds
# stderr back to the agent.

input=$(cat)
action=$(printf '%s' "$input" | jq -r '.tool_input.action // "publish"' 2>/dev/null)

case "$action" in
  publish|"")
    cat >&2 <<MSG
BLOCKED: Claude Artifacts are disabled by user policy (claude-global/CLAUDE.md).
Do not retry, and do not look for another way to publish. Deliver the page as a
plain HTML file instead: write it to /tmp/<descriptive-name>.html and give the
user that path.
MSG
    exit 2
    ;;
esac
exit 0
