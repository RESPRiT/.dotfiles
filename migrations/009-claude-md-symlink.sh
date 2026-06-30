#!/usr/bin/env bash
# Migration: install ~/.claude/CLAUDE.md symlink.
#
# Backfills the install step that brings global Claude Code instructions
# under the dotfiles base + machine-local overlay pattern. settings.json
# already works this way (merge-settings.sh); CLAUDE.md achieves the same
# split via Claude Code's @import syntax instead, since CLAUDE.md has no
# native include directive.
#
# Idempotent: link_shell skips when the symlink already points at the
# canonical source. A pre-existing real ~/.claude/CLAUDE.md is moved to
# CLAUDE.local.md (imported from the base file's trailing
# @~/.claude/CLAUDE.local.md line) rather than backed up, so existing
# hand-written instructions are preserved.

set -euo pipefail

DOTFILES="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
# shellcheck source=../lib/colors.sh
. "$DOTFILES/lib/colors.sh"
# shellcheck source=../lib/helpers.sh
. "$DOTFILES/lib/helpers.sh"

mkdir -p "$HOME/.claude"
link_shell "$DOTFILES/claude-global/CLAUDE.md" \
  "$HOME/.claude/CLAUDE.md" \
  "$HOME/.claude/CLAUDE.local.md"
