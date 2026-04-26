#!/bin/sh
# PostToolUse: when an agent edits either the canonical base
# (~/.dotfiles/claude-global/settings.json) or the machine-local overlay
# (~/.claude/settings.local.json), re-run the jq merge so the change reaches
# ~/.claude/settings.json (the file Claude actually reads). Per the Claude
# Code docs, hook configs hot-reload mid-session — so an edit to either
# input takes effect without restarting. Other settings (model, permissions,
# etc.) still need a Claude restart, but the merged file is at least
# up-to-date for the next launch.
#
# If merge-settings.sh reports drift (out-of-band edits to dest, e.g. via
# /config or the settings UI), surface a one-line additionalContext message
# so the in-session agent — and the user, via the agent's reaction — knows
# the edit was clobbered and where to find the diff for promotion.
#
# Wired up via the PostToolUse Edit|Write|MultiEdit matcher in
# claude-global/settings.json.

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

case "$file_path" in
  "$HOME/.claude/settings.local.json"|"~/.claude/settings.local.json"|"$HOME/.dotfiles/claude-global/settings.json"|"~/.dotfiles/claude-global/settings.json")
    if command -v jq >/dev/null 2>&1; then
      merge_err=$(DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}" \
        bash "$HOME/.dotfiles/claude-global/merge-settings.sh" 2>&1 >/dev/null) || true

      drift_line=$(printf '%s\n' "$merge_err" | grep -E '^merge-settings\.sh: DRIFT:' | head -1)
      if [ -n "$drift_line" ]; then
        msg="[claude-settings] $drift_line. ~/.claude/settings.json is jq-merged from ~/.dotfiles/claude-global/settings.json (base) + ~/.claude/settings.local.json (overlay) — direct edits get clobbered each merge. Read the drift log and promote intentional edits to base or overlay; discard the rest."
        jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
      fi
    fi
    ;;
esac
exit 0
