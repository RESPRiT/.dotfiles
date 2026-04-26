#!/bin/sh
# Generates ~/.claude/settings.json by deep-merging the canonical base
# (claude-global/settings.json) with the machine-local overlay
# (~/.claude/settings.local.json) via jq.
#
# Merge rules:
# - Objects: deep merge (right wins on key collisions).
# - Arrays of strings: concat + unique (e.g., permissions.allow).
# - Arrays of objects: concat (e.g., hooks; preserves firing order).
# - Scalars: right wins.
#
# Called by install.sh, hooks/post-merge, and the in-session
# remerge-on-settings-edit.sh hook. The destination is intentionally a
# regular file (not a symlink) — Claude Code has a known bug where symlinked
# settings.json triggers permission failures (anthropics/claude-code#3575).
# Agent edits to dest are blocked by the protect-settings.sh PreToolUse
# hook, but Claude Code's own settings writers (/config, /permissions, the
# settings UI) bypass that and write directly to dest. We clobber such
# drift on every merge, but log a unified diff to .state/ first so the
# user can recover or promote intentional edits to base/overlay.

set -e

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
BASE="${BASE:-$DOTFILES_ROOT/claude-global/settings.json}"
OVERLAY="${OVERLAY:-$HOME/.claude/settings.local.json}"
DEST="${DEST:-$HOME/.claude/settings.json}"
STATE_DIR="${STATE_DIR:-$DOTFILES_ROOT/.state}"
SNAPSHOT="${SNAPSHOT:-$STATE_DIR/claude-settings-last-merge.json}"
DRIFT_LOG="${DRIFT_LOG:-$STATE_DIR/claude-settings-drift.log}"
DRIFT_LOG_MAX_BYTES=1048576

if ! command -v jq >/dev/null 2>&1; then
  echo "merge-settings.sh: jq not found; cannot merge claude settings" >&2
  exit 1
fi

if [ ! -f "$BASE" ]; then
  echo "merge-settings.sh: base file missing: $BASE" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")" "$(dirname "$OVERLAY")" "$STATE_DIR"
[ ! -f "$OVERLAY" ] && echo '{}' > "$OVERLAY"

# Drift detection: if DEST exists and differs from the snapshot of the last
# merge output, something edited DEST out-of-band (e.g. /config or the
# Claude settings UI). Capture the diff before clobbering. No snapshot yet
# means this is a first run and we can't tell drift from baseline — accept
# DEST as-is and let the snapshot get written below.
drift_detected=0
drift_diff=""
if [ -f "$DEST" ] && [ -f "$SNAPSHOT" ] && ! cmp -s "$DEST" "$SNAPSHOT"; then
  drift_detected=1
  drift_diff=$(diff -u "$SNAPSHOT" "$DEST" 2>/dev/null || true)
fi

# Skip the merge if dest is newer than both inputs AND no drift to clobber.
if [ "$drift_detected" -eq 0 ] && [ -f "$DEST" ] \
    && [ "$DEST" -nt "$BASE" ] && [ "$DEST" -nt "$OVERLAY" ]; then
  exit 2
fi

log_drift_entry() {
  _diff="$1"
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Rotate when the log would otherwise grow past 1MB. Single generation —
  # older history rolls off.
  if [ -f "$DRIFT_LOG" ]; then
    _size=$(wc -c < "$DRIFT_LOG" 2>/dev/null | tr -d ' ')
    if [ -n "$_size" ] && [ "$_size" -gt "$DRIFT_LOG_MAX_BYTES" ]; then
      mv "$DRIFT_LOG" "${DRIFT_LOG}.1"
    fi
  fi
  {
    printf '=== drift clobbered at %s ===\n' "$_ts"
    printf '%s\n\n' "$_diff"
  } >> "$DRIFT_LOG"
  chmod 600 "$DRIFT_LOG" 2>/dev/null || true
}

tmp=$(mktemp "${TMPDIR:-/tmp}/claude-settings.XXXXXX")
if jq -s '
  def deepmerge($a; $b):
    if ($a|type) == "object" and ($b|type) == "object" then
      reduce ($a + $b | keys_unsorted[]) as $k ({};
        .[$k] = (
          if ($a|has($k)) and ($b|has($k)) then deepmerge($a[$k]; $b[$k])
          elif ($a|has($k)) then $a[$k]
          else $b[$k] end))
    elif ($a|type) == "array" and ($b|type) == "array" then
      if (($a + $b) | all(type == "string")) then (($a + $b) | unique)
      else ($a + $b) end
    else $b end;
  deepmerge(.[0]; .[1])
' "$BASE" "$OVERLAY" > "$tmp"; then
  if [ "$drift_detected" -eq 1 ]; then
    log_drift_entry "$drift_diff"
    _changed=$(printf '%s\n' "$drift_diff" | grep -cE '^[-+][^-+]' || true)
    echo "merge-settings.sh: DRIFT: clobbered ${_changed} changed lines in $DEST; diff appended to $DRIFT_LOG" >&2
  fi
  mv "$tmp" "$DEST"
  cp "$DEST" "$SNAPSHOT" 2>/dev/null || true
  chmod 600 "$SNAPSHOT" 2>/dev/null || true
else
  rm -f "$tmp"
  echo "merge-settings.sh: jq merge failed; $DEST unchanged" >&2
  exit 1
fi
