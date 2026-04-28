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
# Called by install.sh, hooks/post-merge, the in-session
# remerge-on-settings-edit.sh PostToolUse hook, and the
# session-start-drift-check.sh SessionStart hook. The destination is
# intentionally a regular file (not a symlink) — Claude Code has a known bug
# where symlinked settings.json triggers permission failures
# (anthropics/claude-code#3575). Agent edits to dest are blocked by the
# protect-settings.sh PreToolUse hook, but Claude Code's own settings
# writers (/plugin, /config, /permissions, the settings UI) bypass that and
# write directly to dest, creating drift the rest of the system has to
# reconcile.
#
# State machine (drives whether we write dest):
#
#   1. dest doesn't exist                  → write projected, init snapshot.
#   2. projected == dest                   → already correct; sync snapshot,
#                                            no-op on dest.
#   3. snapshot doesn't exist              → no baseline to compare; treat as
#                                            first run, write projected.
#   4. dest == snapshot, projected ≠ dest  → safe propagation of an
#                                            intentional base/overlay edit.
#                                            Write projected, update snapshot.
#   5. dest ≠ snapshot, projected ≠ dest   → drift in dest from out-of-band
#                                            writes (/plugin, /config, settings
#                                            UI). Three sub-cases, tried in
#                                            order:
#                                            5a. Cosmetic only (jq -S equal
#                                                between dest and projected):
#                                                snapshot syncs, no overlay
#                                                change, silent.
#                                            5b. Auto-reconcile candidate
#                                                (`subtract(base, dest)` plus
#                                                a verify re-merge) reproduces
#                                                dest exactly: write that
#                                                candidate to overlay, refresh
#                                                dest/snapshot, emit
#                                                RECONCILED line for visibility.
#                                            5c. Otherwise (removals from
#                                                base, base/overlay conflicts
#                                                overlay can't shadow): emit
#                                                DRIFT line and exit 3.
#                                                --force overrides 5c by
#                                                logging the diff and
#                                                clobbering.
#
# Used by:
# - install.sh, hooks/post-merge, migrations/003: pass --force (unattended,
#   need forward progress; auto-reconcile still runs first, --force only
#   matters for case 5c).
# - PostToolUse remerge hook, SessionStart drift-check hook: no flag.
#   Auto-reconcile handles common cases silently or with a RECONCILED
#   notice; case 5c surfaces via additionalContext for agent reconciliation.
#
# Exit codes:
#   0 — projected merge applied, or no-op, or auto-reconciled
#   1 — error (jq missing, base missing, jq merge failed)
#   3 — drift detected, refused to clobber (case 5c, default behavior)

set -e

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
fi

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
BASE="${BASE:-$DOTFILES_ROOT/claude-global/settings.json}"
OVERLAY="${OVERLAY:-$HOME/.claude/settings.local.json}"
DEST="${DEST:-$HOME/.claude/settings.json}"
STATE_DIR="${STATE_DIR:-$DOTFILES_ROOT/.state}"
SNAPSHOT="${SNAPSHOT:-$STATE_DIR/claude-settings-last-merge.json}"
DRIFT_LOG="${DRIFT_LOG:-$STATE_DIR/claude-settings-drift.log}"
RECONCILE_LOG="${RECONCILE_LOG:-$STATE_DIR/claude-settings-reconcile.log}"
LOG_MAX_BYTES=1048576

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

# Compute the projected merge into a tmp file. This is what dest *should*
# contain. We compare against the actual dest below to decide what to do.
tmp=$(mktemp "${TMPDIR:-/tmp}/claude-settings.XXXXXX")
if ! jq -s '
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
  rm -f "$tmp"
  echo "merge-settings.sh: jq merge failed; $DEST unchanged" >&2
  exit 1
fi

write_dest_from_tmp() {
  mv "$tmp" "$DEST"
  cp "$DEST" "$SNAPSHOT" 2>/dev/null || true
  chmod 600 "$SNAPSHOT" 2>/dev/null || true
}

sync_snapshot_to_dest() {
  cp "$DEST" "$SNAPSHOT" 2>/dev/null || true
  chmod 600 "$SNAPSHOT" 2>/dev/null || true
  rm -f "$tmp"
}

append_log_entry() {
  _log="$1"
  _header="$2"
  _diff="$3"
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -f "$_log" ]; then
    _size=$(wc -c < "$_log" 2>/dev/null | tr -d ' ')
    if [ -n "$_size" ] && [ "$_size" -gt "$LOG_MAX_BYTES" ]; then
      mv "$_log" "${_log}.1"
    fi
  fi
  {
    printf '=== %s at %s ===\n' "$_header" "$_ts"
    printf '%s\n\n' "$_diff"
  } >> "$_log"
  chmod 600 "$_log" 2>/dev/null || true
}

# Case 1: dest doesn't exist. Initialize from projected.
if [ ! -f "$DEST" ]; then
  write_dest_from_tmp
  exit 0
fi

# Case 2: dest already matches projected. Nothing to write; ensure snapshot
# tracks dest so future drift detection has the right baseline.
if cmp -s "$tmp" "$DEST"; then
  sync_snapshot_to_dest
  exit 0
fi

# Case 3: no snapshot yet (first run on a machine that already had a dest).
# We can't tell drift from baseline, so accept projected as truth.
if [ ! -f "$SNAPSHOT" ]; then
  write_dest_from_tmp
  exit 0
fi

# Case 4: dest matches snapshot — no out-of-band edits since last merge.
# This is a clean propagation of an intentional base/overlay change.
if cmp -s "$DEST" "$SNAPSHOT"; then
  write_dest_from_tmp
  exit 0
fi

# Case 5: dest ≠ snapshot AND projected ≠ dest → real drift.
drift_diff=$(diff -u "$SNAPSHOT" "$DEST" 2>/dev/null || true)
_changed=$(printf '%s\n' "$drift_diff" | grep -cE '^[-+][^-+]' || true)

# Case 5a: cosmetic-only drift (key reordering by Claude Code's writer with
# no semantic change). After deep-sorting keys, dest equals projected.
# Sync snapshot, no overlay change, no notice — pure cleanup.
dest_sorted=$(jq -S . "$DEST" 2>/dev/null || true)
proj_sorted=$(jq -S . "$tmp" 2>/dev/null || true)
if [ -n "$dest_sorted" ] && [ "$dest_sorted" = "$proj_sorted" ]; then
  sync_snapshot_to_dest
  exit 0
fi

# Case 5b: try auto-reconcile. Compute candidate_overlay = subtract(base,
# dest), the minimal overlay that — when merged with base — reproduces
# dest's content. Then re-merge to verify; only commit if the candidate
# survives the verify step (i.e., no removals or base conflicts that
# overlay can't express).
candidate_overlay=$(mktemp "${TMPDIR:-/tmp}/claude-overlay.XXXXXX")
candidate_proj=$(mktemp "${TMPDIR:-/tmp}/claude-projected.XXXXXX")

if jq -n --slurpfile base_arr "$BASE" --slurpfile dest_arr "$DEST" '
  def subtract($base; $dest):
    if ($dest|type) == "object" and ($base|type) == "object" then
      (reduce ($dest | keys_unsorted[]) as $k ({};
        if ($base|has($k)) then
          (subtract($base[$k]; $dest[$k])) as $sub
          | if $sub == null then . else .[$k] = $sub end
        else
          .[$k] = $dest[$k]
        end))
      | if . == {} then null else . end
    elif ($dest|type) == "array" and ($base|type) == "array" then
      (($dest - $base)) as $extras
      | if ($extras|length) == 0 then null else $extras end
    else
      if $dest == $base then null else $dest end
    end;
  (subtract($base_arr[0]; $dest_arr[0]) // {})
' > "$candidate_overlay" 2>/dev/null \
&& jq -s '
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
' "$BASE" "$candidate_overlay" > "$candidate_proj" 2>/dev/null; then
  cand_sorted=$(jq -S . "$candidate_proj" 2>/dev/null || true)
  if [ -n "$cand_sorted" ] && [ "$dest_sorted" = "$cand_sorted" ]; then
    # Verify passed — apply the auto-reconcile, and log the diff so a
    # mistaken reconcile (accidental /plugin install, misclick) is auditable
    # and reversible.
    append_log_entry "$RECONCILE_LOG" "auto-reconciled to overlay" "$drift_diff"
    mv "$candidate_overlay" "$OVERLAY"
    mv "$candidate_proj" "$DEST"
    cp "$DEST" "$SNAPSHOT" 2>/dev/null || true
    chmod 600 "$SNAPSHOT" "$OVERLAY" 2>/dev/null || true
    rm -f "$tmp"
    echo "merge-settings.sh: RECONCILED: promoted ${_changed} drifted lines to $OVERLAY; entry appended to $RECONCILE_LOG (review and move to base if cross-machine, or revert via the log)" >&2
    exit 0
  fi
fi
rm -f "$candidate_overlay" "$candidate_proj"

# Case 5c: auto-reconcile failed — drift includes removals from base or
# conflicts overlay can't shadow.
if [ "$FORCE" -eq 1 ]; then
  append_log_entry "$DRIFT_LOG" "drift clobbered" "$drift_diff"
  echo "merge-settings.sh: DRIFT: clobbered ${_changed} changed lines in $DEST; diff appended to $DRIFT_LOG" >&2
  write_dest_from_tmp
  exit 0
fi

echo "merge-settings.sh: DRIFT: detected ${_changed} changed lines in $DEST that overlay can't express (likely removal from base). Edit base to reconcile, or pass --force to clobber." >&2
rm -f "$tmp"
exit 3
