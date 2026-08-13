#!/bin/sh
# PreToolUse(Bash | GitHub MCP) — injects Harrison's PR protocol as
# additionalContext when the session touches PRs. Reminder-only, never blocks.
#
# Tiers:
#   digest  — first PR-shaped call of the session (any tier): full protocol,
#             deduped via a per-session sentinel in $TMPDIR.
#   comment — every comment-posting call: compact comment rules appended.
#   body    — every PR create / body edit: compact body-structure rules appended.
#
# Wired via the PreToolUse "Bash" and "mcp__plugin_github_github__.*" matchers
# in claude-global/settings.json.

input=$(cat)
session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

tier=""
case "$tool" in
  Bash)
    [ -n "$cmd" ] || exit 0
    case "$cmd" in
      *"gh pr create"*) tier=body ;;
      *"gh pr edit"*)
        case "$cmd" in
          *--body*) tier=body ;;
          *) tier=read ;;
        esac
        ;;
      *"gh pr comment"*|*"gh pr review"*) tier=comment ;;
      *"gh api"*comments*)
        case "$cmd" in
          *POST*|*PATCH*|*" -f "*|*" -F "*|*--field*|*--raw-field*) tier=comment ;;
          *) tier=read ;;
        esac
        ;;
      *"gh pr "*) tier=read ;;
      *"gh api"*pulls*|*"gh api"*issues*) tier=read ;;
      *) exit 0 ;;
    esac
    ;;
  mcp__plugin_github_github__create_pull_request|mcp__plugin_github_github__update_pull_request)
    tier=body ;;
  mcp__plugin_github_github__add_issue_comment|mcp__plugin_github_github__add_reply_to_pull_request_comment|mcp__plugin_github_github__add_comment_to_pending_review|mcp__plugin_github_github__pull_request_review_write)
    tier=comment ;;
  mcp__plugin_github_github__pull_request_read|mcp__plugin_github_github__list_pull_requests|mcp__plugin_github_github__search_pull_requests|mcp__plugin_github_github__update_pull_request_branch)
    tier=read ;;
  *) exit 0 ;;
esac

msg=""

# Full digest, once per session (sentinel-deduped), on any PR-shaped call.
sentinel="${TMPDIR:-/tmp}/claude-pr-protocol-${session}"
if [ ! -f "$sentinel" ]; then
  : > "$sentinel" 2>/dev/null || true
  msg="PR protocol (Harrison's standing rules; apply to ALL PR interaction this session):
- Markers in Harrison's PR comments: '//!' = task (do it, reply in-thread with a summary of what was done); '//?' = question (reply in-thread with the answer); '//>' = shell conversation (do NOT reply yet — at the end of your next turn, initiate the discussion in chat with the comment's context; reply with a summary only after Harrison says it is settled).
- Wrap every comment body you post: first line '/// CLAUDE ///', last line '///////////////'.
- Reply-only: never post a new top-level PR comment. Reply in-thread via gh api repos/{o}/{r}/pulls/{n}/comments/{id}/replies. A marker in a conversation-tab comment gets a quote-reply. Anything else top-level requires Harrison explicitly asking.
- PR bodies: read .github/agent_pull_request_guidelines.md (if present) before touching title or body. ALL generated content — including the 'Generated with Claude Code' attribution — goes INSIDE the single agent <details> block. Preserve Harrison's prose byte-for-byte; checklist stays outside the block, unchecked.
- Full protocol memory: ~/.claude/projects/-Users-harrison-numeric-io-fdp/memory/feedback_pr_comment_protocol.md"
fi

case "$tier" in
  comment)
    extra="PR comment rules: wrap the body in '/// CLAUDE ///' … '///////////////'. Reply in-thread only — never a new top-level comment. '//!'/'//?' markers get in-thread replies; '//>' means discuss in the shell first and reply only once settled."
    ;;
  body)
    extra="PR body rules: read .github/agent_pull_request_guidelines.md (if present) first. Title stays 'TITLE_ME: <branch>'. Fetch the current body and preserve Harrison's prose byte-for-byte. ALL generated content — including the 'Generated with Claude Code' attribution — goes inside the single agent <details> block; checklist unchecked, outside the block."
    ;;
  *)
    extra=""
    ;;
esac

if [ -n "$msg" ] && [ -n "$extra" ]; then
  msg="$msg

$extra"
elif [ -n "$extra" ]; then
  msg="$extra"
fi

[ -n "$msg" ] || exit 0

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
exit 0
