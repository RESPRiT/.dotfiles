#!/usr/bin/env bash
# Migration: symlink committed Claude CLI helpers into ~/.local/bin.
#
# Backfills the install step that links claude-global/bin/* (e.g.
# claude-sessions for reboot save/restore) into ~/.local/bin, for machines
# that have only run post-merge since the helpers were added (no full
# install.sh). Without the symlinks the helpers aren't on PATH.
#
# Idempotent: link skips when the symlink already points at the canonical
# source. Mirrors the loop in install.sh so the two can't drift.

set -euo pipefail

DOTFILES="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
# shellcheck source=../lib/colors.sh
. "$DOTFILES/lib/colors.sh"
# shellcheck source=../lib/helpers.sh
. "$DOTFILES/lib/helpers.sh"

[ -d "$DOTFILES/claude-global/bin" ] || exit 0

mkdir -p "$HOME/.local/bin"
for _bin in "$DOTFILES/claude-global/bin"/*; do
  [ -f "$_bin" ] || continue
  link "$_bin" "$HOME/.local/bin/$(basename "$_bin")"
done
