#!/bin/sh
# PreToolUse(Bash) reminder: before an agent authors a PR body via `gh pr create`
# or `gh pr edit --body…`, nudge it to (1) read & preserve Harrison's existing
# description — the PR space is shared, don't clobber his writing — and (2) wrap
# its own contributed prose in a <details><summary>Word of Claude</summary>
# block. Reminder-only: emits additionalContext, never blocks the command.
#
# Wired via the PreToolUse "Bash" matcher in claude-global/settings.json.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -n "$cmd" ] || exit 0

# Fire only when a PR body is actually being written: every `gh pr create`, but
# `gh pr edit` only when it carries --body/--body-file (skip label/reviewer edits).
case "$cmd" in
  *"gh pr create"*) fire=1 ;;
  *"gh pr edit"*)
    case "$cmd" in
      *--body*) fire=1 ;;
      *) fire=0 ;;
    esac
    ;;
  *) fire=0 ;;
esac

[ "$fire" = "1" ] || exit 0

msg="PR body reminder: (1) Read the current PR description first and preserve Harrison's prose — you share this space, do not clobber his writing. (2) Wrap your own contributed description in a <details><summary>Word of Claude</summary> … </details> block."

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
exit 0
