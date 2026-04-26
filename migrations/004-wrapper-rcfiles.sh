#!/usr/bin/env bash
# Migration: convert ~/.bashrc, ~/.zshrc, ~/.bash_profile from symlinks
# (pointing at dotfiles repo files) into real wrapper files. This lets
# third-party installers (nvm, conda, rustup, fzf, …) append to those files
# without mutating the committed dotfiles. See CLAUDE.md for the layered-
# config pattern.
#
# Idempotent: if a file is already a wrapper, no-op.

set -euo pipefail

DOTFILES="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"

migrate_rc() {
  local dst="$1" base="$2" local_file="$3"
  [ -L "$dst" ] || return 0
  [ "$(readlink "$dst")" = "$base" ] || return 0

  rm "$dst"
  cat > "$dst" <<EOF
# Wrapper installed by dotfiles install.sh.
# Real file (not symlink) so third-party installers (nvm, conda, fzf, rustup, …)
# can append below without mutating the dotfiles repo. Hand-curated overrides
# go in $(basename "$local_file") (sourced from $(basename "$base") near the end).
. "$base"
EOF
  echo "[004] Replaced $dst symlink with wrapper -> $base"
}

migrate_rc "$HOME/.bashrc" "$DOTFILES/bashrc" "$HOME/.bashrc.local"
migrate_rc "$HOME/.zshrc"  "$DOTFILES/zshrc"  "$HOME/.zshrc.local"

# bash_profile: the dotfiles repo file is removed in this same change, so
# the symlink is dangling post-pull. Replace with a wrapper that just sources
# ~/.bashrc (which itself is now a wrapper sourcing the dotfiles base).
_bp="$HOME/.bash_profile"
if [ -L "$_bp" ] && [ ! -e "$_bp" ]; then
  rm "$_bp"
fi
if [ ! -e "$_bp" ]; then
  cat > "$_bp" <<'EOF'
# Wrapper installed by dotfiles install.sh.
# Bash login shells (e.g. SSH) read ~/.bash_profile but NOT ~/.bashrc.
# Real file (not symlink) so installers like rustup can append safely.
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
  echo "[004] Installed wrapper at $_bp -> ~/.bashrc"
fi
