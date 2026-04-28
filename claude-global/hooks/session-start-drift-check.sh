#!/bin/sh
# SessionStart: invoke merge-settings.sh in default (non-clobbering) mode.
#
# Default behavior of merge-settings.sh propagates clean cases (dest
# already correct; agent-driven base/overlay edits) but refuses to clobber
# real drift (out-of-band writes to dest from /plugin, /config,
# /permissions, settings UI between sessions). On drift it exits 3 with a
# DRIFT line on stderr; we surface that via additionalContext so the new
# session's agent can reconcile with the user before any clobber happens —
# the just-changed setting (e.g., a freshly installed plugin) keeps
# working through the reconciliation.
#
# Wired up via the SessionStart matcher in claude-global/settings.json.

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

merge_err=$(DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}" \
  bash "$HOME/.dotfiles/claude-global/merge-settings.sh" 2>&1 >/dev/null) || true

notice_line=$(printf '%s\n' "$merge_err" | grep -E '^merge-settings\.sh: (DRIFT|RECONCILED):' | head -1)
[ -z "$notice_line" ] && exit 0

case "$notice_line" in
  *RECONCILED:*)
    msg="[claude-settings] $notice_line. Out-of-band drift in ~/.claude/settings.json (likely /plugin, /config, /permissions, or settings UI between sessions) was auto-promoted to the overlay so the change keeps working. Mention this to the user briefly so accidental promotions can be caught — the audit entry is in ~/.dotfiles/.state/claude-settings-reconcile.log. If the change should apply across machines, move it from overlay to ~/.dotfiles/claude-global/settings.json (base)."
    ;;
  *DRIFT:*)
    msg="[claude-settings] $notice_line. Auto-reconcile couldn't express the drift in overlay (overlay can only add/override, not remove base entries). Read the diff with: diff -u ~/.dotfiles/.state/claude-settings-last-merge.json ~/.claude/settings.json. Then ask the user whether to (a) edit base (committed dotfiles, confirm before editing) to match the desired state, or (b) DISCARD by running 'bash ~/.dotfiles/claude-global/merge-settings.sh --force' to clobber and log."
    ;;
esac

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0
