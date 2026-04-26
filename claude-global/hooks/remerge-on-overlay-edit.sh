#!/bin/sh
# PostToolUse: when an agent edits ~/.claude/settings.local.json (the overlay),
# re-run the jq merge so the change reaches ~/.claude/settings.json (the file
# Claude actually reads). Per the Claude Code docs, hook configs hot-reload
# mid-session — so an overlay-edited hook takes effect without restarting.
# Other settings (model, permissions, etc.) still need a Claude restart, but
# the merged file is at least up-to-date for the next launch.
#
# Wired up via the PostToolUse Edit|Write|MultiEdit matcher in
# claude-global/settings.json.

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

case "$file_path" in
  "$HOME/.claude/settings.local.json"|"~/.claude/settings.local.json")
    if command -v jq >/dev/null 2>&1; then
      DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}" \
        bash "$HOME/.dotfiles/claude-global/merge-settings.sh" 2>/dev/null || true
    fi
    ;;
esac
exit 0
