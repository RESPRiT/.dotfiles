#!/usr/bin/env bash
# Migration: switch Claude Code settings.json from "single hand-edited file" to
# "base + overlay merged by jq" (see claude-global/merge-settings.sh and
# CLAUDE.md). Pre-existing ~/.claude/settings.json may have machine-specific
# bits (model, plugins, hooks for tools that may not exist elsewhere) that the
# user should triage into the new layout.
#
# Idempotent: runs once per machine, then no-ops on re-run.

set -euo pipefail

DOTFILES="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
SETTINGS="$HOME/.claude/settings.json"
OVERLAY="$HOME/.claude/settings.local.json"
MARKER="$DOTFILES/.state/003-claude-settings-merge.done"

if [ -f "$MARKER" ]; then
  exit 0
fi

mkdir -p "$HOME/.claude" "$DOTFILES/.state"

# 1. If a real (non-symlinked) settings.json exists and isn't already what
#    install.sh would generate, back it up so the user can triage.
if [ -f "$SETTINGS" ] && [ ! -L "$SETTINGS" ]; then
  backup="$SETTINGS.pre-merge.$(date +%Y%m%d-%H%M%S).bak"
  cp "$SETTINGS" "$backup"
  echo "[003] Backed up existing $SETTINGS -> $backup"
  echo "[003] Review the backup and move per-machine bits into $OVERLAY."
fi

# 2. If settings.json is a stale symlink to dotfiles (from the old install.sh
#    layout), break it so the merge can write a real file.
if [ -L "$SETTINGS" ]; then
  rm -f "$SETTINGS"
  echo "[003] Removed stale symlink at $SETTINGS"
fi

# 3. If the overlay is the inert artifact (small, no meaningful content), reset
#    it to an empty object so it's a clean overlay starting point.
if [ -f "$OVERLAY" ] && [ ! -L "$OVERLAY" ]; then
  size=$(wc -c < "$OVERLAY" | tr -d ' ')
  if [ "$size" -lt 100 ]; then
    cp "$OVERLAY" "$OVERLAY.pre-merge.bak" 2>/dev/null || true
    echo '{}' > "$OVERLAY"
    echo "[003] Reset $OVERLAY (was $size bytes; backup at $OVERLAY.pre-merge.bak)"
  fi
elif [ -L "$OVERLAY" ]; then
  # Old install.sh symlinked claude-global/settings.local.json -> ~/.claude/settings.local.json.
  # That file is being deleted; break the symlink and seed a fresh overlay.
  rm -f "$OVERLAY"
  echo '{}' > "$OVERLAY"
  echo "[003] Replaced stale symlink at $OVERLAY with empty overlay"
fi

# 4. Run the merge so settings.json reflects base + overlay immediately.
if command -v jq >/dev/null 2>&1; then
  DOTFILES_ROOT="$DOTFILES" bash "$DOTFILES/claude-global/merge-settings.sh"
  echo "[003] Generated $SETTINGS from base + overlay"
else
  echo "[003] jq not installed; skipping merge — re-run install.sh to install jq and merge"
fi

touch "$MARKER"
