#!/usr/bin/env bash
# Migration: symlink committed skills into ~/.claude/skills/.
#
# Backfills the install step that links each claude-global/skills/<name>
# directory into ~/.claude/skills/<name>, for machines that have only run
# post-merge since the skills directory was added (no full install.sh).
# Without the symlink the global skills (e.g. /fast-ship) aren't available.
#
# Idempotent: link skips when the symlink already points at the canonical
# source. Mirrors the loop in install.sh so the two can't drift.

set -euo pipefail

DOTFILES="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
# shellcheck source=../lib/colors.sh
. "$DOTFILES/lib/colors.sh"
# shellcheck source=../lib/helpers.sh
. "$DOTFILES/lib/helpers.sh"

[ -d "$DOTFILES/claude-global/skills" ] || exit 0

mkdir -p "$HOME/.claude/skills"
for _skill_dir in "$DOTFILES/claude-global/skills"/*/; do
  [ -d "$_skill_dir" ] || continue
  link "${_skill_dir%/}" "$HOME/.claude/skills/$(basename "$_skill_dir")"
done
