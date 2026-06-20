#!/usr/bin/env bash
# Migration: symlink committed keybindings into ~/.claude/keybindings.json.
#
# Backfills the install step that links claude-global/keybindings.json into
# ~/.claude/keybindings.json, for machines that have only run post-merge since
# the file was added (no full install.sh). Without the symlink the custom
# Claude Code key rebinds (e.g. ctrl+z / cmd+z -> chat:undo) aren't applied.
#
# Plain `link` (like skills, not link_shell): keybindings.json is JSON with no
# include/source mechanism, and unlike settings.json it isn't rewritten by
# Claude Code's own UI, so a straight symlink is safe and needs no overlay.
#
# Idempotent: link skips when the symlink already points at the canonical
# source. Mirrors the call in install.sh so the two can't drift.

set -euo pipefail

DOTFILES="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
# shellcheck source=../lib/colors.sh
. "$DOTFILES/lib/colors.sh"
# shellcheck source=../lib/helpers.sh
. "$DOTFILES/lib/helpers.sh"

[ -f "$DOTFILES/claude-global/keybindings.json" ] || exit 0

mkdir -p "$HOME/.claude"
link "$DOTFILES/claude-global/keybindings.json" "$HOME/.claude/keybindings.json"
