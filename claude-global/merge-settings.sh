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
# Called by install.sh and hooks/post-merge. The destination is intentionally
# a regular file (not a symlink) — Claude Code has a known bug where symlinked
# settings.json triggers permission failures (anthropics/claude-code#3575).
# Direct edits are blocked by the protect-settings.sh PreToolUse hook.

set -e

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
BASE="${BASE:-$DOTFILES_ROOT/claude-global/settings.json}"
OVERLAY="${OVERLAY:-$HOME/.claude/settings.local.json}"
DEST="${DEST:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "merge-settings.sh: jq not found; cannot merge claude settings" >&2
  exit 1
fi

if [ ! -f "$BASE" ]; then
  echo "merge-settings.sh: base file missing: $BASE" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")" "$(dirname "$OVERLAY")"
[ ! -f "$OVERLAY" ] && echo '{}' > "$OVERLAY"

# Skip if dest is newer than both inputs (exit 2 = up to date).
if [ -f "$DEST" ] && [ "$DEST" -nt "$BASE" ] && [ "$DEST" -nt "$OVERLAY" ]; then
  exit 2
fi

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
  mv "$tmp" "$DEST"
else
  rm -f "$tmp"
  echo "merge-settings.sh: jq merge failed; $DEST unchanged" >&2
  exit 1
fi
