#!/usr/bin/env bash
# Migration: install ~/.claude/statusline-command.sh symlink.
#
# Backfills the install step added in commit 59e8798 ("Add portable
# statusline base and universal Claude prefs") for machines that have
# only run post-merge since (no full install.sh). settings.json points
# at ~/.claude/statusline-command.sh; without this symlink the status
# line silently no-ops.
#
# Idempotent: link_shell skips when the symlink already points at the
# canonical source. Pre-existing real files at the destination are
# moved to statusline-command.local.sh (the override extension) rather
# than backed up, so any monolithic per-machine logic is preserved.

set -euo pipefail

DOTFILES="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
# shellcheck source=../lib/colors.sh
. "$DOTFILES/lib/colors.sh"
# shellcheck source=../lib/helpers.sh
. "$DOTFILES/lib/helpers.sh"

mkdir -p "$HOME/.claude"
link_shell "$DOTFILES/claude-global/statusline-command.sh" \
  "$HOME/.claude/statusline-command.sh" \
  "$HOME/.claude/statusline-command.local.sh"
