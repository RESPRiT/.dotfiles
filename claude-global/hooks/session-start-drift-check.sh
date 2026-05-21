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
  *RECONCILED:*) kind="RECONCILED" ;;
  *DRIFT:*) kind="DRIFT" ;;
esac

# Extract the key-sorted diff body framed by sentinels in merge-settings.sh.
diff_body=$(printf '%s\n' "$merge_err" | awk -v k="$kind" '
  $0 == ">>>" k "_DIFF_BEGIN<<<" { cap=1; next }
  $0 == ">>>" k "_DIFF_END<<<" { cap=0 }
  cap
')

case "$kind" in
  RECONCILED)
    msg="[claude-settings] $notice_line. Out-of-band drift in ~/.claude/settings.json (likely /plugin, /config, /permissions, or settings UI between sessions) was auto-promoted to the overlay so the change keeps working. Mention this to the user briefly (with the diff below) so accidental promotions can be caught — the audit entry is in ~/.dotfiles/.state/claude-settings-reconcile.log. If the change should apply across machines, move it from overlay to ~/.dotfiles/claude-global/settings.json (base)."
    ;;
  DRIFT)
    msg="[claude-settings] $notice_line. Auto-reconcile couldn't express the drift in overlay (overlay can only add/override, not remove base entries). Ask the user whether to (a) edit base (committed dotfiles, confirm before editing) to match the desired state, or (b) DISCARD by running 'bash ~/.dotfiles/claude-global/merge-settings.sh --force' to clobber and log."
    ;;
esac

if [ -n "$diff_body" ]; then
  msg="$msg

Diff (key-sorted JSON; snapshot → dest):
$diff_body"
fi

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0
