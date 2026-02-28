#!/bin/bash
set -e

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

# Bold light blue (ANSI 117) to match shell prompt
PROMPT_COLOR=$'\033[1;38;5;117m'
YES_COLOR=$'\033[1;38;5;120m'   # light green
NO_COLOR=$'\033[1;38;5;248m'    # grey
N_COLOR=$'\033[1;38;5;210m'     # light red (for N in y/N prompts)
RESET=$'\033[0m'

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

# Auto-update dotfiles on shell startup
_autoupdate_configured=false
if [ -n "$DOTFILES_AUTO_UPDATE" ]; then
  _autoupdate_configured=true
else
  for _local_rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
    if [ -f "$_local_rc" ] && grep -q 'DOTFILES_AUTO_UPDATE' "$_local_rc"; then
      _autoupdate_configured=true
      break
    fi
  done
fi

if [ "$_autoupdate_configured" = true ]; then
  echo "Auto-update already configured, skipping"
else
  read -rp "${PROMPT_COLOR}Enable automatic dotfiles update on shell startup? [y/${N_COLOR}N${PROMPT_COLOR}]${RESET} " _autoupdate_answer
  if [[ "$_autoupdate_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Enabling auto-update...${RESET}"
    for _local_rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
      if [ -f "$_local_rc" ] && ! grep -q 'DOTFILES_AUTO_UPDATE' "$_local_rc"; then
        printf '\nexport DOTFILES_AUTO_UPDATE=1\n' >> "$_local_rc"
      fi
    done
    echo "Auto-update enabled (DOTFILES_AUTO_UPDATE=1 in local rc files)"
  else
    echo "${NO_COLOR}(Selected N) Skipping auto-update${RESET}"
  fi
  unset _autoupdate_answer
fi
unset _autoupdate_configured _local_rc

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
if [ ! -e "$HOME/.claude/settings.local.json" ]; then
  link "$DOTFILES/claude/settings.local.json" "$HOME/.claude/settings.local.json"
else
  echo "$HOME/.claude/settings.local.json already exists, skipping"
fi

# Ghostty
mkdir -p "$HOME/.config/ghostty"
link "$DOTFILES/ghostty/config" "$HOME/.config/ghostty/config"

# keychain (SSH agent management)
_install_keychain=true
if [ -x "$HOME/.local/bin/keychain" ]; then
  echo "keychain already installed (~/.local/bin/keychain), skipping"
  _install_keychain=false
elif [ -S "$HOME/.1password/agent.sock" ]; then
  echo "keychain skipped: 1Password SSH agent detected"
  _install_keychain=false
elif [ -n "$SSH_AUTH_SOCK" ] && ssh-add -l &>/dev/null; then
  echo "keychain skipped: existing SSH agent with loaded keys detected"
  _install_keychain=false
fi

if [ "$_install_keychain" = true ]; then
  read -rp "${PROMPT_COLOR}Install keychain for SSH agent management? [y/${N_COLOR}N${PROMPT_COLOR}]${RESET} " _kc_answer
  if [[ "$_kc_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing keychain...${RESET}"
    mkdir -p "$HOME/.local/bin"
    curl -fsSL https://github.com/danielrobbins/keychain/releases/latest/download/keychain \
      -o "$HOME/.local/bin/keychain"
    chmod +x "$HOME/.local/bin/keychain"
    echo "Installed keychain to ~/.local/bin/keychain"
  else
    echo "${NO_COLOR}(Selected N) Skipping keychain${RESET}"
  fi
fi
unset _install_keychain _kc_answer

# zoxide
if command -v zoxide &>/dev/null; then
  echo "zoxide already installed, skipping"
else
  read -rp "${PROMPT_COLOR}Install zoxide (smarter cd)? [y/${N_COLOR}N${PROMPT_COLOR}]${RESET} " _zoxide_answer
  if [[ "$_zoxide_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing zoxide...${RESET}"
    curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
    echo "Installed zoxide"
  else
    echo "${NO_COLOR}(Selected N) Skipping zoxide${RESET}"
  fi
  unset _zoxide_answer
fi

# eza (modern ls)
if command -v eza &>/dev/null; then
  echo "eza already installed, skipping"
else
  _eza_prompt="Install eza (modern ls)?"
  if ! command -v cargo &>/dev/null; then
    _eza_prompt="Install eza (modern ls)? (will also install Rust)"
  fi
  read -rp "${PROMPT_COLOR}${_eza_prompt} [y/${N_COLOR}N${PROMPT_COLOR}]${RESET} " _eza_answer
  unset _eza_prompt
  if [[ "$_eza_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing eza...${RESET}"
    if ! command -v cargo &>/dev/null; then
      echo "Rust/Cargo not found, installing via rustup..."
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
      . "$HOME/.cargo/env"
    fi
    cargo install eza
    echo "Installed eza"
  else
    echo "${NO_COLOR}(Selected N) Skipping eza${RESET}"
  fi
  unset _eza_answer
fi

# atuin
if ! command -v atuin &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
else
  echo "atuin already installed, skipping"
fi

if [ ! -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/key" ]; then
  read -rp "${PROMPT_COLOR}Log in to Atuin sync? [y/${N_COLOR}N${PROMPT_COLOR}]${RESET} " _atuin_answer
  if [[ "$_atuin_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Logging in to Atuin...${RESET}"
    read -rp "${PROMPT_COLOR}Atuin username:${RESET} " ATUIN_USERNAME
    read -rsp "${PROMPT_COLOR}Atuin password:${RESET} " ATUIN_PASSWORD
    echo ""
    read -rsp "${PROMPT_COLOR}Atuin key:${RESET} " ATUIN_KEY
    echo ""

    atuin login -u "$ATUIN_USERNAME" -p "$ATUIN_PASSWORD" -k "$ATUIN_KEY"
    atuin sync
    echo "Atuin login and sync complete"
  else
    echo "${NO_COLOR}(Selected N) Skipping Atuin login${RESET}"
  fi
  unset _atuin_answer
else
  echo "atuin already logged in, skipping"
fi

echo ""
echo "Done! Machine-specific config goes in ~/.zshrc.local or ~/.bashrc.local"

