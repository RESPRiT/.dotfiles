#!/bin/bash
set -e

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    echo "Backing up existing $dst -> ${dst}.bak"
    mv "$dst" "${dst}.bak"
  fi
  ln -s "$src" "$dst"
  echo "Linked $dst -> $src"
}

link_shell() {
  local src="$1" dst="$2" local="$3"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    if [ -e "$local" ]; then
      echo "Error: $local already exists. Remove it manually before installing." >&2
      exit 1
    fi
    mv "$dst" "$local"
    echo "Moved existing $dst -> $local"
  fi
  ln -s "$src" "$dst"
  echo "Linked $dst -> $src"
}

# Shell
link "$DOTFILES/shellrc" "$HOME/.shellrc"
link_shell "$DOTFILES/zshrc" "$HOME/.zshrc" "$HOME/.zshrc.local"
link_shell "$DOTFILES/bashrc" "$HOME/.bashrc" "$HOME/.bashrc.local"

# Vim
link "$DOTFILES/vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.vim/pack/plugins/start"
if [ ! -d "$HOME/.vim/pack/plugins/start/vim-colors-solarized" ]; then
  git clone https://github.com/altercation/vim-colors-solarized.git \
    "$HOME/.vim/pack/plugins/start/vim-colors-solarized"
  echo "Installed vim-colors-solarized"
fi

# Claude Code
mkdir -p "$HOME/.claude"
link "$DOTFILES/claude/settings.local.json" "$HOME/.claude/settings.local.json"

# Ghostty
mkdir -p "$HOME/.config/ghostty"
link "$DOTFILES/ghostty/config" "$HOME/.config/ghostty/config"

# atuin
curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh

echo ""
read -rp "Atuin username: " ATUIN_USERNAME
read -rsp "Atuin password: " ATUIN_PASSWORD
echo ""
read -rsp "Atuin key: " ATUIN_KEY
echo ""

atuin login -u "$ATUIN_USERNAME" -p "$ATUIN_PASSWORD" -k "$ATUIN_KEY"
atuin sync

echo ""
echo "Done! Machine-specific config goes in ~/.zshrc.local or ~/.bashrc.local"

