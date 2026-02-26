#!/bin/bash
set -e

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    if [ -e "${dst}.bak" ]; then
      echo "Error: ${dst}.bak already exists. Reconcile manually before installing." >&2
      exit 1
    fi
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
  if [ ! -e "$local" ]; then
    echo "# Machine-specific configuration for this host" > "$local"
    echo "Created $local"
  fi
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

# keychain (SSH agent management)
_install_keychain=true
if command -v keychain &>/dev/null; then
  echo "keychain already installed, skipping"
  _install_keychain=false
elif [ -S "$HOME/.1password/agent.sock" ]; then
  echo "keychain skipped: 1Password SSH agent detected"
  _install_keychain=false
elif [ -n "$SSH_AUTH_SOCK" ] && ssh-add -l &>/dev/null; then
  echo "keychain skipped: existing SSH agent with loaded keys detected"
  _install_keychain=false
fi

if [ "$_install_keychain" = true ]; then
  read -rp "Install keychain for SSH agent management? [y/N] " _kc_answer
  if [[ "$_kc_answer" =~ ^[Yy]$ ]]; then
    if [ "$(uname)" = "Darwin" ]; then
      brew install keychain
    else
      mkdir -p "$HOME/.local/bin"
      curl -fsSL https://github.com/danielrobbins/keychain/releases/latest/download/keychain \
        -o "$HOME/.local/bin/keychain"
      chmod +x "$HOME/.local/bin/keychain"
    fi
    echo "Installed keychain"
  else
    echo "keychain install skipped"
  fi
fi
unset _install_keychain _kc_answer

# atuin
if ! command -v atuin &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
else
  echo "atuin already installed, skipping"
fi

if [ ! -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/key" ]; then
  echo ""
  read -rp "Atuin username: " ATUIN_USERNAME
  read -rsp "Atuin password: " ATUIN_PASSWORD
  echo ""
  read -rsp "Atuin key: " ATUIN_KEY
  echo ""

  atuin login -u "$ATUIN_USERNAME" -p "$ATUIN_PASSWORD" -k "$ATUIN_KEY"
  atuin sync
else
  echo "atuin already logged in, skipping"
fi

echo ""
echo "Done! Machine-specific config goes in ~/.zshrc.local or ~/.bashrc.local"

