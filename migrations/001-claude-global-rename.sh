#!/usr/bin/env bash
#
# Migrate claude/ -> claude-global/ symlink rename.
# If ~/.claude/settings.local.json points to the old claude/ path,
# update it to point to claude-global/ directly.

set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
LINK="$HOME/.claude/settings.local.json"

if [ -L "$LINK" ]; then
  target=$(readlink "$LINK")
  if [[ "$target" == */claude/settings.local.json ]]; then
    ln -sf "$DOTFILES/claude-global/settings.local.json" "$LINK"
    echo "Updated ~/.claude/settings.local.json symlink to claude-global/"
  fi
fi
