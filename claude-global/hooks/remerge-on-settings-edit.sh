#!/bin/sh
# PostToolUse: when an agent edits either the canonical base
# (~/.dotfiles/claude-global/settings.json) or the machine-local overlay
# (~/.claude/settings.local.json), re-run merge-settings.sh so the change
# reaches ~/.claude/settings.json (the file Claude actually reads). Per
# the Claude Code docs, hook configs hot-reload mid-session — so an edit
# to either input takes effect without restarting. Other settings (model,
# permissions, etc.) still need a Claude restart, but the merged file is
# at least up-to-date for the next launch.
#
# merge-settings.sh runs in default (non-clobbering) mode: it propagates
# the agent's edit when dest is clean, and refuses to merge if there's
# real drift in dest (out-of-band writes via /plugin, /config, settings
# UI). In the drift case it exits 3 with a DRIFT line on stderr; we
# surface that via additionalContext so the agent reconciles with the
# user before any clobber.
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

      notice_line=$(printf '%s\n' "$merge_err" | grep -E '^merge-settings\.sh: (DRIFT|RECONCILED):' | head -1)
      if [ -n "$notice_line" ]; then
        case "$notice_line" in
          *RECONCILED:*)
            msg="[claude-settings] $notice_line. Pre-existing drift was auto-promoted to overlay during the remerge of your base/overlay edit. Mention this briefly to the user so accidental promotions can be caught; audit entry is in ~/.dotfiles/.state/claude-settings-reconcile.log."
            ;;
          *DRIFT:*)
            msg="[claude-settings] $notice_line. Your edit to base/overlay did NOT propagate to ~/.claude/settings.json because dest has drift the overlay can't express (likely a base removal). Read the diff with: diff -u ~/.dotfiles/.state/claude-settings-last-merge.json ~/.claude/settings.json. Reconcile with the user: (a) edit base to match the desired state, or (b) DISCARD — run 'bash ~/.dotfiles/claude-global/merge-settings.sh --force' to clobber and log."
            ;;
        esac
        jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
      fi
    fi
    ;;
esac
exit 0
