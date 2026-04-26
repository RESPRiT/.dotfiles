#!/bin/bash
set -e

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

# Bold light blue (ANSI 117) to match shell prompt
PROMPT_COLOR=$'\033[1;38;5;117m'
YES_COLOR=$'\033[1;38;5;120m'   # light green
N_COLOR=$'\033[1;38;5;210m'     # light red (for N in y/[N] prompts)
SKIP_COLOR=$'\033[38;5;240m'    # dark grey (for "already X" skip messages)
BANNER_COLOR=$'\033[38;5;244m'  # mid grey (for startup decision banner)
RESET=$'\033[0m'

# --fresh re-prompts every optional install by clearing stored "no" decisions.
# Already-installed checks still skip, so the script stays idempotent.
FRESH=false
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=true ;;
  esac
done

# Per-machine state lives inside the repo at .state/ (gitignored). Keeps
# $HOME clean and co-locates state with the code it pertains to.
STATE_DIR="$DOTFILES/.state"
mkdir -p "$STATE_DIR"

# Relocate legacy state files from $HOME (pre-.state/ layout). Idempotent:
# only moves when the old file exists and the new one doesn't.
for _old_name in migrated decisions; do
  _old_path="$HOME/.dotfiles-$_old_name"
  _new_path="$STATE_DIR/$_old_name"
  if [ -f "$_old_path" ] && [ ! -f "$_new_path" ]; then
    mv "$_old_path" "$_new_path"
    echo "Relocated $_old_path -> $_new_path"
  fi
done
unset _old_name _old_path _new_path

# Persist [N] answers so we don't re-ask declined prompts on every run.
# One key per line, exact-match against was_declined. Cleared by --fresh.
DECISIONS_FILE="$STATE_DIR/decisions"

if [ "$FRESH" = true ] && [ -f "$DECISIONS_FILE" ]; then
  rm -f "$DECISIONS_FILE"
  echo "${PROMPT_COLOR}--fresh: cleared stored decisions${RESET}"
fi

skip_msg() {
  printf '%s%s%s\n' "$SKIP_COLOR" "$*" "$RESET"
}

was_declined() {
  [ -f "$DECISIONS_FILE" ] && grep -qx "$1" "$DECISIONS_FILE"
}

record_decline() {
  was_declined "$1" && return
  echo "$1" >> "$DECISIONS_FILE"
}

# Friendly label for a decision key, used by the startup banner and the
# reconciliation block below.
decision_label() {
  case "$1" in
    auto-update)      echo "auto-update for dotfiles" ;;
    docs-clone)       echo "cloning .docs companion repo" ;;
    docs-auto-update) echo "auto-update for .docs" ;;
    tmux-upgrade)     echo "tmux 3.5+ upgrade" ;;
    keychain)         echo "keychain (SSH agent manager)" ;;
    zsh-install)      echo "installing zsh" ;;
    zsh-default)      echo "setting zsh as default shell" ;;
    rust)             echo "Rust toolchain" ;;
    go)               echo "Go toolchain" ;;
    zoxide)           echo "zoxide" ;;
    atuin-install)    echo "atuin" ;;
    atuin-login)      echo "atuin login / sync" ;;
    *)                echo "$1" ;;
  esac
}

# Returns 0 if the underlying state for a declined decision is now satisfied,
# meaning the marker is stale and can be cleared without re-prompting. Each
# branch must mirror the corresponding "already X" short-circuit in the
# install step below — drift here means we'd re-prompt unnecessarily.
is_satisfied() {
  local _rc _ver _maj _min _mr
  case "$1" in
    auto-update)
      [ -n "$DOTFILES_AUTO_UPDATE" ] && return 0
      for _rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
        [ -f "$_rc" ] && grep -q 'DOTFILES_AUTO_UPDATE' "$_rc" && return 0
      done
      return 1 ;;
    docs-clone)
      [ -d "$HOME/.docs/.git" ] ;;
    docs-auto-update)
      [ -n "$DOCS_AUTO_UPDATE" ] && return 0
      for _rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
        [ -f "$_rc" ] && grep -q 'DOCS_AUTO_UPDATE' "$_rc" && return 0
      done
      return 1 ;;
    tmux-upgrade)
      command -v tmux &>/dev/null || return 1
      _ver="$(tmux -V | awk '{print $2}')"
      _maj="${_ver%%.*}"
      _mr="${_ver#*.}"
      _min="${_mr%%[!0-9]*}"
      { [ "$_maj" -gt 3 ] || { [ "$_maj" -eq 3 ] && [ "$_min" -ge 5 ]; }; } ;;
    keychain)
      [ -x "$HOME/.local/bin/keychain" ] && return 0
      command -v keychain &>/dev/null && return 0
      [ -S "$HOME/.1password/agent.sock" ] && return 0
      [ -n "$SSH_AUTH_SOCK" ] && ssh-add -l &>/dev/null && return 0
      return 1 ;;
    zsh-install)    command -v zsh &>/dev/null ;;
    zsh-default)    [ "$(basename "${SHELL:-}")" = "zsh" ] ;;
    rust)           command -v cargo &>/dev/null ;;
    go)             command -v go &>/dev/null ;;
    zoxide)         command -v zoxide &>/dev/null ;;
    atuin-install)  command -v atuin &>/dev/null ;;
    atuin-login)    [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/key" ] ;;
    *)              return 1 ;;
  esac
}

# Reconcile declined decisions with current state: drop entries the user has
# satisfied out-of-band (e.g., declined "install zsh" but later installed it
# manually). Done silently — what's left is what the banner reports.
if [ "$FRESH" != true ] && [ -s "$DECISIONS_FILE" ]; then
  _kept=$(mktemp)
  while IFS= read -r _key; do
    [ -z "$_key" ] && continue
    is_satisfied "$_key" || echo "$_key" >> "$_kept"
  done < "$DECISIONS_FILE"
  if [ -s "$_kept" ]; then
    mv "$_kept" "$DECISIONS_FILE"
  else
    rm -f "$DECISIONS_FILE" "$_kept"
  fi
  unset _kept _key

  if [ -s "$DECISIONS_FILE" ]; then
    printf '%sSkipping previously declined prompts:%s\n' "$BANNER_COLOR" "$RESET"
    while IFS= read -r _key; do
      [ -z "$_key" ] && continue
      printf '%s  - %s%s\n' "$BANNER_COLOR" "$(decision_label "$_key")" "$RESET"
    done < "$DECISIONS_FILE"
    printf '%sRe-run with --fresh to re-prompt these.%s\n\n' "$BANNER_COLOR" "$RESET"
    unset _key
  fi
fi

link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    skip_msg "$dst already linked"
    return
  elif [ -L "$dst" ]; then
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
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    skip_msg "$dst already linked"
    return
  elif [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    if [ -e "$local" ]; then
      echo "Error: $local already exists. Remove it manually before installing." >&2
      exit 1
    fi
    # Check if the existing file is just a distro default (e.g. /etc/skel/.bashrc).
    # These pollute the .local override file with boilerplate that conflicts with
    # the dotfiles config. Warn and discard rather than silently preserving.
    local skel="/etc/skel/$(basename "$dst")"
    if [ -f "$skel" ] && diff -q "$dst" "$skel" >/dev/null 2>&1; then
      echo "${SKIP_COLOR}Discarding distro default $dst (identical to $skel)${RESET}"
    else
      mv "$dst" "$local"
      echo "Moved existing $dst -> $local"
      if [ -f "$skel" ]; then
        echo "${PROMPT_COLOR}Note:${RESET} $local was created from a pre-existing $dst."
        echo "  Review it and remove any distro defaults that conflict with the dotfiles config."
      fi
    fi
  fi
  ln -s "$src" "$dst"
  echo "Linked $dst -> $src"
  if [ ! -e "$local" ]; then
    echo "# Machine-specific configuration for this host" > "$local"
    echo "Created $local"
  fi
}

# Like link_shell but installs $dst as a *real wrapper file* that sources
# $base. Used for ~/.bashrc and ~/.zshrc because third-party installers
# (nvm, conda, fzf, rustup, …) commonly do `>> ~/.bashrc`; with a symlink,
# those appends mutate the dotfiles repo. With a wrapper file the appends
# pile up below the source line and the repo file stays pristine. Hand-
# curated overrides still go in $local_file (sourced from $base near its
# end). Load order: base -> local -> app appends in wrapper.
install_wrapper() {
  local base="$1" dst="$2" local_file="$3"

  # Already a wrapper (any line referencing $base): keep it untouched so any
  # third-party appends below the source line are preserved.
  if [ -f "$dst" ] && [ ! -L "$dst" ] && grep -qF "$base" "$dst"; then
    skip_msg "$dst already wraps the dotfiles base"
    if [ ! -e "$local_file" ]; then
      echo "# Machine-specific configuration for this host" > "$local_file"
      echo "Created $local_file"
    fi
    return
  fi

  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    if [ -e "$local_file" ]; then
      echo "Error: $local_file already exists. Remove it manually before installing." >&2
      exit 1
    fi
    local skel="/etc/skel/$(basename "$dst")"
    if [ -f "$skel" ] && diff -q "$dst" "$skel" >/dev/null 2>&1; then
      echo "${SKIP_COLOR}Discarding distro default $dst (identical to $skel)${RESET}"
    else
      mv "$dst" "$local_file"
      echo "Moved existing $dst -> $local_file"
    fi
  fi

  cat > "$dst" <<EOF
# Wrapper installed by dotfiles install.sh.
# Real file (not symlink) so third-party installers (nvm, conda, fzf, rustup, …)
# can append below without mutating the dotfiles repo. Hand-curated overrides
# go in $(basename "$local_file") (sourced from $(basename "$base") near the end).
. "$base"
EOF
  echo "Installed wrapper $dst -> $base"

  if [ ! -e "$local_file" ]; then
    echo "# Machine-specific configuration for this host" > "$local_file"
    echo "Created $local_file"
  fi
}

# ~/.bash_profile is a special case: bash login shells read it but not
# ~/.bashrc, so it just needs to source ~/.bashrc. Real file (not symlink)
# because installers like rustup commonly append here.
install_bash_profile() {
  local dst="$HOME/.bash_profile"

  if [ -f "$dst" ] && [ ! -L "$dst" ] && grep -qF '$HOME/.bashrc' "$dst"; then
    skip_msg "$dst already sources ~/.bashrc"
    return
  fi

  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    if [ -e "$dst.bak" ]; then
      echo "Error: $dst.bak already exists. Reconcile manually before installing." >&2
      exit 1
    fi
    mv "$dst" "$dst.bak"
    echo "Backing up existing $dst -> $dst.bak"
  fi

  cat > "$dst" <<'EOF'
# Wrapper installed by dotfiles install.sh.
# Bash login shells (e.g. SSH) read ~/.bash_profile but NOT ~/.bashrc.
# Real file (not symlink) so installers like rustup can append safely.
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
  echo "Installed wrapper $dst -> ~/.bashrc"
}

# Shell. ~/.bashrc and ~/.zshrc are real wrapper files (not symlinks) — see
# install_wrapper above for why. ~/.shellrc stays a symlink because tools
# never write there, and shellrc is sourced from inside bashrc/zshrc anyway.
link "$DOTFILES/shellrc" "$HOME/.shellrc"
install_wrapper "$DOTFILES/zshrc" "$HOME/.zshrc" "$HOME/.zshrc.local"
install_wrapper "$DOTFILES/bashrc" "$HOME/.bashrc" "$HOME/.bashrc.local"
install_bash_profile
# Seed ~/.shellrc.local if missing (shellrc sources it for shared per-host config)
if [ ! -e "$HOME/.shellrc.local" ]; then
  echo "# Machine-specific configuration shared by bash and zsh" > "$HOME/.shellrc.local"
  echo "Created $HOME/.shellrc.local"
fi

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
  skip_msg "Auto-update already configured"
elif was_declined auto-update; then
  skip_msg "Auto-update already declined"
else
  read -rp "${PROMPT_COLOR}Enable automatic dotfiles update on shell startup? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _autoupdate_answer
  if [[ "$_autoupdate_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Enabling auto-update...${RESET}"
    for _local_rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
      if [ -f "$_local_rc" ] && ! grep -q 'DOTFILES_AUTO_UPDATE' "$_local_rc"; then
        printf '\nexport DOTFILES_AUTO_UPDATE=1\n' >> "$_local_rc"
      fi
    done
    echo "Auto-update enabled (DOTFILES_AUTO_UPDATE=1 in local rc files)"
  else
    record_decline auto-update
    skip_msg "Auto-update already declined"
  fi
  unset _autoupdate_answer
fi
unset _autoupdate_configured _local_rc

# .docs companion repo (notes/docs, cloned to ~/.docs)
_docs_repo="$HOME/.docs"
_docs_url="git@github.com:RESPRiT/.docs.git"
if [ -d "$_docs_repo/.git" ]; then
  skip_msg ".docs already cloned at $_docs_repo"
elif [ -e "$_docs_repo" ]; then
  skip_msg "$_docs_repo exists but is not a git repo; skipping clone"
elif was_declined docs-clone; then
  skip_msg ".docs clone already declined"
else
  read -rp "${PROMPT_COLOR}Clone .docs into $_docs_repo? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _docs_clone_answer
  if [[ "$_docs_clone_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Cloning .docs...${RESET}"
    if ! git clone "$_docs_url" "$_docs_repo"; then
      echo "Failed to clone .docs (check SSH access); continuing" >&2
    fi
  else
    record_decline docs-clone
    skip_msg ".docs clone already declined"
  fi
  unset _docs_clone_answer
fi

# Auto-update .docs on shell startup (only if cloned)
if [ -d "$_docs_repo/.git" ]; then
  _docs_autoupdate_configured=false
  if [ -n "$DOCS_AUTO_UPDATE" ]; then
    _docs_autoupdate_configured=true
  else
    for _local_rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
      if [ -f "$_local_rc" ] && grep -q 'DOCS_AUTO_UPDATE' "$_local_rc"; then
        _docs_autoupdate_configured=true
        break
      fi
    done
  fi

  if [ "$_docs_autoupdate_configured" = true ]; then
    skip_msg ".docs auto-update already configured"
  elif was_declined docs-auto-update; then
    skip_msg ".docs auto-update already declined"
  else
    read -rp "${PROMPT_COLOR}Enable automatic .docs update on shell startup? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _docs_autoupdate_answer
    if [[ "$_docs_autoupdate_answer" =~ ^[Yy]$ ]]; then
      echo "${YES_COLOR}(Selected y) Enabling .docs auto-update...${RESET}"
      for _local_rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
        if [ -f "$_local_rc" ] && ! grep -q 'DOCS_AUTO_UPDATE' "$_local_rc"; then
          printf '\nexport DOCS_AUTO_UPDATE=1\n' >> "$_local_rc"
        fi
      done
      echo ".docs auto-update enabled (DOCS_AUTO_UPDATE=1 in local rc files)"
    else
      record_decline docs-auto-update
      skip_msg ".docs auto-update already declined"
    fi
    unset _docs_autoupdate_answer
  fi
  unset _docs_autoupdate_configured _local_rc
fi
unset _docs_repo _docs_url

# Vim
link "$DOTFILES/vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.vim/pack/plugins/start"
if [ ! -d "$HOME/.vim/pack/plugins/start/vim-colors-solarized" ]; then
  git clone https://github.com/altercation/vim-colors-solarized.git \
    "$HOME/.vim/pack/plugins/start/vim-colors-solarized"
  echo "Installed vim-colors-solarized"
fi

# Git hooks
link "$DOTFILES/hooks/post-merge" "$DOTFILES/.git/hooks/post-merge"

# jq — required by the Claude settings merge below; also a generally useful
# CLI for shell scripts that touch JSON. Installed without prompting because
# it's small and the Claude config layout depends on it.
if command -v jq &>/dev/null; then
  skip_msg "jq already installed"
elif command -v apt-get &>/dev/null; then
  echo "${YES_COLOR}Installing jq...${RESET}"
  sudo apt-get update && sudo apt-get install -y jq
elif command -v brew &>/dev/null; then
  echo "${YES_COLOR}Installing jq...${RESET}"
  brew install jq
else
  echo "Warning: could not install jq automatically (no apt-get or brew). Claude settings merge will be skipped until jq is available." >&2
fi

# Claude Code: ~/.claude/settings.json is generated by deep-merging the
# canonical base (claude-global/settings.json) with the machine-local overlay
# (~/.claude/settings.local.json). Direct edits to the merged file are blocked
# by claude-global/hooks/protect-settings.sh, wired up via PreToolUse. See
# claude-global/merge-settings.sh for the jq logic, and CLAUDE.md for rationale.
mkdir -p "$HOME/.claude"
if command -v jq &>/dev/null; then
  _merge_rc=0
  DOTFILES_ROOT="$DOTFILES" bash "$DOTFILES/claude-global/merge-settings.sh" || _merge_rc=$?
  case "$_merge_rc" in
    0) echo "Merged Claude settings -> $HOME/.claude/settings.json" ;;
    2) skip_msg "Claude settings already up to date" ;;
  esac
  unset _merge_rc
else
  skip_msg "Skipped Claude settings merge (jq not installed)"
fi

# tmux 3.5+ — needed for `extended-keys-format csi-u` (tmux.conf:42).
# Ubuntu 24.04 and similar LTS distros still ship 3.4, so build from source
# when the package manager can't satisfy the version requirement.
_tmux_min_major=3
_tmux_min_minor=5
_tmux_needs_install=true
_tmux_current=""
if command -v tmux &>/dev/null; then
  _tmux_current="$(tmux -V | awk '{print $2}')"
  _tmux_major="${_tmux_current%%.*}"
  _tmux_minor_raw="${_tmux_current#*.}"
  _tmux_minor="${_tmux_minor_raw%%[!0-9]*}"
  if [ "$_tmux_major" -gt "$_tmux_min_major" ] \
    || { [ "$_tmux_major" -eq "$_tmux_min_major" ] && [ "$_tmux_minor" -ge "$_tmux_min_minor" ]; }; then
    _tmux_needs_install=false
  fi
fi

if [ "$_tmux_needs_install" = false ]; then
  skip_msg "tmux $_tmux_current already meets minimum (${_tmux_min_major}.${_tmux_min_minor}+)"
elif was_declined tmux-upgrade; then
  skip_msg "tmux upgrade already declined"
else
  if [ -n "$_tmux_current" ]; then
    _tmux_prompt="Upgrade tmux to ${_tmux_min_major}.${_tmux_min_minor}+ (currently $_tmux_current)?"
  else
    _tmux_prompt="Install tmux ${_tmux_min_major}.${_tmux_min_minor}+?"
  fi
  read -rp "${PROMPT_COLOR}${_tmux_prompt} y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _tmux_answer
  if [[ "$_tmux_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing tmux...${RESET}"
    if command -v brew &>/dev/null; then
      brew install tmux
    else
      _tmux_src_version="3.5a"
      if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y build-essential libevent-dev libncurses-dev bison pkg-config
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y gcc make libevent-devel ncurses-devel bison pkgconf-pkg-config
      elif command -v pacman &>/dev/null; then
        sudo pacman -S --needed --noconfirm base-devel libevent ncurses bison
      elif command -v apk &>/dev/null; then
        sudo apk add build-base libevent-dev ncurses-dev bison pkgconf
      else
        echo "No supported package manager found; install build deps manually" >&2
        exit 1
      fi
      _tmux_build="$(mktemp -d)"
      _tmux_tarball="tmux-${_tmux_src_version}.tar.gz"
      curl -fsSL "https://github.com/tmux/tmux/releases/download/${_tmux_src_version}/${_tmux_tarball}" \
        -o "${_tmux_build}/${_tmux_tarball}"
      tar -C "$_tmux_build" -xzf "${_tmux_build}/${_tmux_tarball}"
      (cd "${_tmux_build}/tmux-${_tmux_src_version}" && ./configure && make)
      sudo make -C "${_tmux_build}/tmux-${_tmux_src_version}" install
      rm -rf "$_tmux_build"
      unset _tmux_src_version _tmux_tarball _tmux_build
    fi
    hash -r 2>/dev/null || true
    echo "Installed tmux $(tmux -V)"
  else
    record_decline tmux-upgrade
    skip_msg "tmux upgrade already declined"
  fi
  unset _tmux_answer _tmux_prompt
fi
unset _tmux_needs_install _tmux_current _tmux_major _tmux_minor _tmux_minor_raw _tmux_min_major _tmux_min_minor

# tmux config
link_shell "$DOTFILES/tmux.conf" "$HOME/.tmux.conf" "$HOME/.tmux.local.conf"

# tmux plugins (TPM)
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
  mkdir -p "$HOME/.tmux/plugins"
  git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
  echo "Installed tpm"
fi
if [ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]; then
  # install_plugins reads TMUX_PLUGIN_MANAGER_PATH from a tmux server, but
  # `tmux start-server` alone doesn't load the conf. Source the conf first so
  # the `run '~/.tmux/plugins/tpm/tpm'` line executes and sets the variable.
  tmux start-server \; source-file "$HOME/.tmux.conf"
  "$HOME/.tmux/plugins/tpm/bin/install_plugins" \
    | sed -E "s/^(Already installed.*)$/${SKIP_COLOR}\\1${RESET}/"
fi

# Ghostty
mkdir -p "$HOME/.config/ghostty"
link "$DOTFILES/ghostty/config" "$HOME/.config/ghostty/config"

# keychain (SSH agent management)
_install_keychain=true
if [ -x "$HOME/.local/bin/keychain" ]; then
  skip_msg "keychain already installed (~/.local/bin/keychain)"
  _install_keychain=false
elif command -v keychain &>/dev/null; then
  skip_msg "keychain already installed ($(command -v keychain))"
  _install_keychain=false
elif [ -S "$HOME/.1password/agent.sock" ]; then
  skip_msg "keychain not needed (1Password SSH agent detected)"
  _install_keychain=false
elif [ -n "$SSH_AUTH_SOCK" ] && ssh-add -l &>/dev/null; then
  skip_msg "keychain not needed (existing SSH agent with loaded keys detected)"
  _install_keychain=false
elif was_declined keychain; then
  skip_msg "keychain already declined"
  _install_keychain=false
fi

if [ "$_install_keychain" = true ]; then
  read -rp "${PROMPT_COLOR}Install keychain for SSH agent management? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _kc_answer
  if [[ "$_kc_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing keychain...${RESET}"
    mkdir -p "$HOME/.local/bin"
    curl -fsSL https://github.com/danielrobbins/keychain/releases/latest/download/keychain \
      -o "$HOME/.local/bin/keychain"
    chmod +x "$HOME/.local/bin/keychain"
    echo "Installed keychain to ~/.local/bin/keychain"
  else
    record_decline keychain
    skip_msg "keychain already declined"
  fi
fi
unset _install_keychain _kc_answer

# zsh
if command -v zsh &>/dev/null; then
  skip_msg "zsh already installed"
elif was_declined zsh-install; then
  skip_msg "zsh already declined"
else
  read -rp "${PROMPT_COLOR}Install zsh? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _zsh_install_answer
  if [[ "$_zsh_install_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing zsh...${RESET}"
    if command -v apt-get &>/dev/null; then
      sudo apt-get update && sudo apt-get install -y zsh
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y zsh
    elif command -v pacman &>/dev/null; then
      sudo pacman -S --noconfirm zsh
    elif command -v apk &>/dev/null; then
      sudo apk add zsh
    elif command -v brew &>/dev/null; then
      brew install zsh
    else
      echo "No supported package manager found; install zsh manually" >&2
    fi
  else
    record_decline zsh-install
    skip_msg "zsh already declined"
  fi
  unset _zsh_install_answer
fi

# zsh as default shell
_zsh_path="$(command -v zsh 2>/dev/null || true)"
if [ -z "$_zsh_path" ]; then
  : # zsh not installed; skip silently (the install step above already reported)
elif [ "$(basename "${SHELL:-}")" = "zsh" ]; then
  skip_msg "zsh already set as default shell"
elif was_declined zsh-default; then
  skip_msg "zsh as default shell already declined"
else
  read -rp "${PROMPT_COLOR}Set zsh as default shell? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _zsh_default_answer
  if [[ "$_zsh_default_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Setting zsh as default shell...${RESET}"
    # chsh refuses shells that aren't listed in /etc/shells; add it if missing.
    if [ -f /etc/shells ] && ! grep -qx "$_zsh_path" /etc/shells; then
      echo "$_zsh_path" | sudo tee -a /etc/shells >/dev/null
    fi
    chsh -s "$_zsh_path"
    echo "Default shell changed to $_zsh_path (takes effect on next login)"
  else
    record_decline zsh-default
    skip_msg "zsh as default shell already declined"
  fi
  unset _zsh_default_answer
fi
unset _zsh_path

# Rust / Cargo
if command -v cargo &>/dev/null; then
  skip_msg "cargo already installed"
elif was_declined rust; then
  skip_msg "Rust already declined"
else
  read -rp "${PROMPT_COLOR}Install Rust and Cargo? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _rust_answer
  if [[ "$_rust_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing Rust...${RESET}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
    echo "Installed Rust and Cargo"
  else
    record_decline rust
    skip_msg "Rust already declined"
  fi
  unset _rust_answer
fi

# Go
if command -v go &>/dev/null; then
  skip_msg "go already installed"
elif was_declined go; then
  skip_msg "Go already declined"
else
  read -rp "${PROMPT_COLOR}Install Go? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _go_answer
  if [[ "$_go_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing Go...${RESET}"
    _go_version="1.24.1"
    _go_arch="$(uname -m)"
    if [ "$_go_arch" = "x86_64" ]; then
      _go_arch="amd64"
    elif [ "$_go_arch" = "aarch64" ] || [ "$_go_arch" = "arm64" ]; then
      _go_arch="arm64"
    fi
    _go_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    _go_tarball="go${_go_version}.${_go_os}-${_go_arch}.tar.gz"
    curl -fsSL "https://go.dev/dl/${_go_tarball}" -o "/tmp/${_go_tarball}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${_go_tarball}"
    rm -f "/tmp/${_go_tarball}"
    export PATH="/usr/local/go/bin:$PATH"
    echo "Installed Go $(go version)"
    unset _go_version _go_arch _go_os _go_tarball
  else
    record_decline go
    skip_msg "Go already declined"
  fi
  unset _go_answer
fi

# zoxide
if command -v zoxide &>/dev/null; then
  skip_msg "zoxide already installed"
elif was_declined zoxide; then
  skip_msg "zoxide already declined"
else
  read -rp "${PROMPT_COLOR}Install zoxide (smarter cd)? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _zoxide_answer
  if [[ "$_zoxide_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing zoxide...${RESET}"
    curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
    echo "Installed zoxide"
  else
    record_decline zoxide
    skip_msg "zoxide already declined"
  fi
  unset _zoxide_answer
fi

# atuin
if command -v atuin &>/dev/null; then
  skip_msg "atuin already installed"
elif was_declined atuin-install; then
  skip_msg "atuin already declined"
else
  read -rp "${PROMPT_COLOR}Install atuin (shell history sync)? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _atuin_install_answer
  if [[ "$_atuin_install_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Installing atuin...${RESET}"
    if ! curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh; then
      echo "atuin installer failed, trying cargo install..."
      if command -v cargo &>/dev/null; then
        cargo install atuin
      else
        echo "cargo not found, skipping atuin install"
      fi
    fi
  else
    record_decline atuin-install
    skip_msg "atuin already declined"
  fi
  unset _atuin_install_answer
fi

if [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/key" ]; then
  skip_msg "atuin already logged in"
elif was_declined atuin-login; then
  skip_msg "Atuin login already declined"
else
  read -rp "${PROMPT_COLOR}Log in to Atuin sync? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _atuin_answer
  if [[ "$_atuin_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Logging in to Atuin...${RESET}"
    read -rp "${PROMPT_COLOR}Atuin username:${RESET} " ATUIN_USERNAME
    read -rsp "${PROMPT_COLOR}Atuin password:${RESET} " ATUIN_PASSWORD
    echo ""
    read -rsp "${PROMPT_COLOR}Atuin key:${RESET} " ATUIN_KEY
    echo ""

    # atuin installer puts the binary in ~/.atuin/bin; ensure it's on PATH
    export PATH="${HOME}/.atuin/bin:${HOME}/.cargo/bin:${PATH}"

    atuin login -u "$ATUIN_USERNAME" -p "$ATUIN_PASSWORD" -k "$ATUIN_KEY"
    atuin sync
    echo "Atuin login and sync complete"
  else
    record_decline atuin-login
    skip_msg "Atuin login already declined"
  fi
  unset _atuin_answer
fi

# Seed migration tracker if missing, then run any pending migrations
if [ ! -f "$STATE_DIR/migrated" ]; then
  echo "0" > "$STATE_DIR/migrated"
fi
"$DOTFILES/hooks/post-merge"

echo ""
echo "${YES_COLOR}Done!${RESET} Machine-specific config goes in ~/.zshrc.local or ~/.bashrc.local"
echo ""
echo "${PROMPT_COLOR}Restarting your shell to pick up new config...${RESET}"
exec "${SHELL:-/bin/bash}"

