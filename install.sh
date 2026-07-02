#!/bin/bash
set -e

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/colors.sh
. "$DOTFILES/lib/colors.sh"
# shellcheck source=lib/helpers.sh
. "$DOTFILES/lib/helpers.sh"

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
    ssh-multiplex)    echo "SSH connection multiplexing for github.com" ;;
    tmux-upgrade)     echo "tmux 3.5+ upgrade" ;;
    keychain)         echo "keychain (SSH agent manager)" ;;
    tailscale-sshd)   echo "SSH over Tailscale (sshd + key-only auth)" ;;
    wsl-sshd)         echo "SSH into WSL over Tailscale (native sshd on 2222)" ;;
    zsh-install)      echo "installing zsh" ;;
    zsh-default)      echo "setting zsh as default shell" ;;
    rust)             echo "Rust toolchain" ;;
    go)               echo "Go toolchain" ;;
    zoxide)           echo "zoxide" ;;
    atuin-install)    echo "atuin" ;;
    atuin-login)      echo "atuin login / sync" ;;
    wsl-open)         echo "wslview (open links/files in Windows)" ;;
    *)                echo "$1" ;;
  esac
}

# Helpers shared by is_satisfied(tailscale-sshd) and the SSH-over-Tailscale
# step below, so the "already set up" signal can't drift from what the step
# checks before running.
_sshd_listening() {
  # bash's /dev/tcp: the open succeeds iff something accepts on localhost:PORT
  # (default 22; pass a port for a non-default listener — WSL uses 2222).
  # Under WSL mirrored networking a connect to a CLOSED localhost port hangs
  # for many seconds instead of refusing immediately, so cap it with `timeout`
  # where available (all Linux/WSL). macOS has no `timeout` but refuses closed
  # ports instantly, so it falls through to the unbounded probe with no hang.
  local _port="${1:-22}"
  if command -v timeout &>/dev/null; then
    timeout -s KILL 2 bash -c ': < /dev/tcp/127.0.0.1/"$0"' "$_port" 2>/dev/null
  else
    ( : < /dev/tcp/127.0.0.1/"$_port" ) 2>/dev/null
  fi
}

# Every non-comment key in $1 is present in $2, matched on "type blob" so a
# differing comment doesn't read as a missing key.
_authorized_keys_synced() {
  local _src="$1" _dst="$2" _line _blob
  [ -f "$_src" ] || return 0
  while IFS= read -r _line; do
    case "$_line" in ''|\#*) continue ;; esac
    _blob="$(printf '%s' "$_line" | awk '{print $1" "$2}')"
    { [ -f "$_dst" ] && grep -qF "$_blob" "$_dst"; } || return 1
  done < "$_src"
}

_sshd_ready() {
  _sshd_listening \
    && _authorized_keys_synced "$DOTFILES/ssh/authorized_keys" "$HOME/.ssh/authorized_keys"
}

# --- SSH directly into WSL (mirrored networking) -----------------------------
# The tailscale-sshd step defers on WSL because, under the default NAT mode,
# sshd inside WSL isn't reachable at the Windows machine's tailnet address.
# Mirrored networking removes that barrier: it mirrors the host's interfaces
# (including Tailscale's) into the distro, so a listener here is reachable at
# the tailnet IP with no portproxy. A dedicated port keeps it from colliding
# with a Windows-host sshd on 22 (powershell/install.ps1).
_WSL_SSHD_PORT=2222

# loopback0 is the interface WSL adds only in mirrored mode — the runtime
# signal that the mirrored architecture is active.
_wsl_mirrored() {
  grep -qi microsoft /proc/version 2>/dev/null && ip link show loopback0 &>/dev/null
}

_wsl_sshd_ready() {
  _sshd_listening "$_WSL_SSHD_PORT" \
    && _authorized_keys_synced "$DOTFILES/ssh/authorized_keys" "$HOME/.ssh/authorized_keys"
}

# First tailnet (100.64.0.0/10 CGNAT) IPv4 on any interface. In mirrored mode
# the host's Tailscale address is mirrored in, so this surfaces it for the
# success message and a "Tailscale not up on the host?" warning.
_tailnet_ip() {
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -Em1 '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
}

# Append any key from $1 that $2 lacks; creates $2 (600, dir 700) if missing.
_merge_authorized_keys() {
  local _src="$1" _dst="$2" _line _blob _added=0
  [ -f "$_src" ] || return 0
  mkdir -p "$(dirname "$_dst")"
  chmod 700 "$(dirname "$_dst")"
  [ -f "$_dst" ] || touch "$_dst"
  chmod 600 "$_dst"
  # A dst without a trailing newline would glue the first appended key onto
  # its last line; normalize before appending.
  if [ -s "$_dst" ] && [ -n "$(tail -c 1 "$_dst")" ]; then
    echo >> "$_dst"
  fi
  while IFS= read -r _line; do
    case "$_line" in ''|\#*) continue ;; esac
    _blob="$(printf '%s' "$_line" | awk '{print $1" "$2}')"
    if ! grep -qF "$_blob" "$_dst"; then
      printf '%s\n' "$_line" >> "$_dst"
      _added=$((_added + 1))
    fi
  done < "$_src"
  if [ "$_added" -gt 0 ]; then
    echo "Authorized $_added new key(s) in $_dst"
  fi
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
    ssh-multiplex)
      # User has set up multiplex (any ControlMaster line in ssh config) — or
      # has it but for a non-github host. Either way, don't re-prompt.
      [ -f "$HOME/.ssh/config" ] && grep -qE '^[[:space:]]*ControlMaster' "$HOME/.ssh/config" ;;
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
    tailscale-sshd) _sshd_ready ;;
    wsl-sshd)       _wsl_sshd_ready ;;
    zsh-install)    command -v zsh &>/dev/null ;;
    zsh-default)    [ "$(basename "${SHELL:-}")" = "zsh" ] ;;
    rust)           command -v cargo &>/dev/null ;;
    go)             command -v go &>/dev/null ;;
    zoxide)         command -v zoxide &>/dev/null ;;
    atuin-install)  command -v atuin &>/dev/null ;;
    atuin-login)    [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/key" ] ;;
    wsl-open)
      # Satisfied once wslview is installed and a representative content type
      # (text/plain) routes to it — mirrors the _wslview_ready check in the
      # install step. text/plain (not x-scheme-handler/file) because file://
      # clicks resolve by content type, so that's the meaningful signal.
      command -v wslview &>/dev/null \
        && [ "$(xdg-mime query default text/plain 2>/dev/null)" = "wslview.desktop" ] ;;
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

# Shell. ~/.bashrc and ~/.zshrc are real wrapper files (not symlinks) — see
# install_wrapper in lib/helpers.sh for why. ~/.shellrc stays a symlink
# because tools never write there, and shellrc is sourced from inside
# bashrc/zshrc anyway.
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

# SSH connection multiplexing for github.com — keeps a control socket open
# for ControlPersist (10m) so subsequent shell-startup fetches reuse the
# already-established TLS/auth handshake. Cuts a warm fetch from ~1.5s to
# ~0.5s. Only useful if at least one auto-update is enabled (otherwise no
# fetches to amortize), so we gate the prompt on that.
_ssh_mux_useful=false
if [ -n "$DOTFILES_AUTO_UPDATE" ] || [ -n "$DOCS_AUTO_UPDATE" ]; then
  _ssh_mux_useful=true
else
  for _local_rc in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
    if [ -f "$_local_rc" ] && grep -qE 'DOTFILES_AUTO_UPDATE|DOCS_AUTO_UPDATE' "$_local_rc"; then
      _ssh_mux_useful=true
      break
    fi
  done
fi

_ssh_config="$HOME/.ssh/config"
_ssh_mux_configured=false
if [ -f "$_ssh_config" ] && grep -qE '^[[:space:]]*ControlMaster' "$_ssh_config"; then
  _ssh_mux_configured=true
fi

if [ "$_ssh_mux_useful" = false ]; then
  : # no auto-update enabled; nothing to amortize
elif [ "$_ssh_mux_configured" = true ]; then
  skip_msg "SSH multiplexing already configured in $_ssh_config"
elif was_declined ssh-multiplex; then
  skip_msg "SSH multiplexing already declined"
else
  read -rp "${PROMPT_COLOR}Enable SSH multiplexing for github.com (faster auto-update fetches)? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _ssh_mux_answer
  if [[ "$_ssh_mux_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Enabling SSH multiplexing...${RESET}"
    mkdir -p "$HOME/.ssh/sockets"
    chmod 700 "$HOME/.ssh/sockets"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    if [ ! -f "$_ssh_config" ]; then
      touch "$_ssh_config"
      chmod 600 "$_ssh_config"
    fi
    # Append; ssh_config keyword precedence is "first match wins per keyword",
    # so adding a Host github.com block at the end coexists with an existing
    # Host * block above (different keywords).
    cat >> "$_ssh_config" <<'EOF'

# Added by dotfiles install.sh — speeds up shell-startup auto-update fetches.
Host github.com
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%C
  ControlPersist 10m
EOF
    echo "Added Host github.com multiplex block to $_ssh_config"
  else
    record_decline ssh-multiplex
    skip_msg "SSH multiplexing already declined"
  fi
  unset _ssh_mux_answer
fi
unset _ssh_mux_useful _ssh_mux_configured _ssh_config

# Vim
link "$DOTFILES/vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.vim/pack/plugins/start"
if [ ! -d "$HOME/.vim/pack/plugins/start/vim-colors-solarized" ]; then
  git clone https://github.com/altercation/vim-colors-solarized.git \
    "$HOME/.vim/pack/plugins/start/vim-colors-solarized"
  echo "Installed vim-colors-solarized"
fi

# Git hooks
link "$DOTFILES/git-hooks/post-merge" "$DOTFILES/.git/hooks/post-merge"

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

# Global instructions: committed base + optional machine-local extension,
# wired together via Claude Code's @import syntax (CLAUDE.md has no native
# include directive, but imports work the same way). link_shell moves any
# pre-existing ~/.claude/CLAUDE.md to CLAUDE.local.md so hand-written
# instructions are preserved and pulled in via the base file's trailing
# @~/.claude/CLAUDE.local.md import.
link_shell "$DOTFILES/claude-global/CLAUDE.md" \
  "$HOME/.claude/CLAUDE.md" \
  "$HOME/.claude/CLAUDE.local.md"

# Status line: committed portable base + optional machine-local extension.
# The base script invokes ~/.claude/statusline-command.local.sh (if present)
# to append per-machine segments (e.g. metacog/trace). On first install,
# link_shell moves any pre-existing monolithic statusline-command.sh to
# .local.sh so existing machine-specific logic is preserved automatically.
link_shell "$DOTFILES/claude-global/statusline-command.sh" \
  "$HOME/.claude/statusline-command.sh" \
  "$HOME/.claude/statusline-command.local.sh"

# Skills: symlink each committed skill directory into ~/.claude/skills/ so it's
# user-global. Per-skill symlinks (not a whole-dir symlink) so machine-local
# skills can coexist in the same directory.
mkdir -p "$HOME/.claude/skills"
for _skill_dir in "$DOTFILES/claude-global/skills"/*/; do
  [ -d "$_skill_dir" ] || continue
  link "${_skill_dir%/}" "$HOME/.claude/skills/$(basename "$_skill_dir")"
done
unset _skill_dir

# Keybindings: symlink the committed Claude Code keybindings so custom rebinds
# (e.g. ctrl+z / cmd+z -> chat:undo) are user-global. Plain link (like skills):
# keybindings.json has no include/source mechanism and isn't rewritten by
# Claude Code's UI, so it needs neither the local-overlay nor the settings.json
# merge dance.
link "$DOTFILES/claude-global/keybindings.json" "$HOME/.claude/keybindings.json"

if command -v jq &>/dev/null; then
  # --force: install.sh is unattended and needs to make forward progress.
  # Drift (if any) is logged to .state/claude-settings-drift.log before
  # being clobbered, so the next session's agent can review and promote.
  DOTFILES_ROOT="$DOTFILES" bash "$DOTFILES/claude-global/merge-settings.sh" --force \
    && echo "Merged Claude settings -> $HOME/.claude/settings.json"
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

# SSH over Tailscale — enable the OS sshd and authorize the committed public
# keys (ssh/authorized_keys) so the machines on the tailnet can SSH into this
# one. Tailscale owns the network layer (its ACLs decide who reaches port 22);
# this step covers the host layer: sshd on, key-only auth, repo keys trusted.
# Windows is handled by powershell/install.ps1. WSL is handled by the separate
# wsl-sshd step below (native sshd, which mirrored networking makes reachable
# at the tailnet IP); under NAT mode WSL still defers to the Windows installer.
_sshd_os="$(uname -s)"
_sshd_supported=true
if [ "$_sshd_os" != "Darwin" ] && [ "$_sshd_os" != "Linux" ]; then
  _sshd_supported=false
elif grep -qi microsoft /proc/version 2>/dev/null; then
  _sshd_supported=false
fi

if [ "$_sshd_supported" = false ]; then
  : # Windows/WSL/other — not this installer's job
elif _sshd_ready; then
  skip_msg "sshd already enabled and committed keys authorized"
elif was_declined tailscale-sshd; then
  skip_msg "SSH over Tailscale already declined"
else
  read -rp "${PROMPT_COLOR}Enable SSH access over Tailscale (sshd, key-only auth; uses sudo)? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _sshd_answer
  if [[ "$_sshd_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Setting up sshd...${RESET}"
    if ! command -v tailscale &>/dev/null && [ ! -d "/Applications/Tailscale.app" ]; then
      echo "Note: Tailscale not detected — sshd will only be reachable on networks this machine is already on. Install it from https://tailscale.com/download" >&2
    fi

    # Authorize the committed keys before disabling password auth, so the
    # key-only drop-in can't create a lockout window.
    _merge_authorized_keys "$DOTFILES/ssh/authorized_keys" "$HOME/.ssh/authorized_keys"

    # Key-only auth via a drop-in. Named 010-* so it sorts — and therefore
    # wins, first-match per keyword — ahead of macOS's 100-macos.conf, which
    # sets PasswordAuthentication yes.
    if grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config 2>/dev/null; then
      sudo mkdir -p /etc/ssh/sshd_config.d
      sudo tee /etc/ssh/sshd_config.d/010-dotfiles.conf >/dev/null <<'EOF'
# Managed by dotfiles install.sh (SSH over Tailscale step). Tailscale ACLs
# gate the network layer; these settings gate authentication.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
      echo "Wrote /etc/ssh/sshd_config.d/010-dotfiles.conf (key-only auth)"
    else
      echo "Warning: /etc/ssh/sshd_config has no sshd_config.d include; skipped key-only hardening" >&2
    fi

    if [ "$_sshd_os" = "Darwin" ]; then
      # macOS ships sshd; Remote Login just turns it on. launchd spawns sshd
      # per connection, so the drop-in above needs no reload to take effect.
      if ! _sshd_listening; then
        # systemsetup can silently no-op when the terminal lacks Full Disk
        # Access, so poll port 22 for the truth and fall back to launchctl.
        sudo systemsetup -setremotelogin on >/dev/null 2>&1 || true
        for _i in 1 2 3; do _sshd_listening && break; sleep 1; done
        if ! _sshd_listening; then
          sudo launchctl enable system/com.openssh.sshd 2>/dev/null || true
          sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
          for _i in 1 2 3; do _sshd_listening && break; sleep 1; done
        fi
        unset _i
      fi
    else
      if [ ! -x /usr/sbin/sshd ] && ! command -v sshd &>/dev/null; then
        if command -v apt-get &>/dev/null; then
          sudo apt-get update && sudo apt-get install -y openssh-server
        elif command -v dnf &>/dev/null; then
          sudo dnf install -y openssh-server
        elif command -v pacman &>/dev/null; then
          sudo pacman -S --needed --noconfirm openssh
        elif command -v apk &>/dev/null; then
          sudo apk add openssh-server
        else
          echo "No supported package manager found; install openssh-server manually" >&2
        fi
      fi
      if command -v systemctl &>/dev/null; then
        # Unit name is ssh on Debian/Ubuntu, sshd on Fedora/Arch/Alpine.
        sudo systemctl enable --now ssh 2>/dev/null \
          || sudo systemctl enable --now sshd 2>/dev/null \
          || echo "Warning: could not enable the ssh/sshd unit" >&2
        # Pick up the key-only drop-in if sshd was already running.
        sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
      else
        echo "Warning: no systemctl; enable sshd via this machine's init system manually" >&2
      fi
    fi

    if _sshd_listening; then
      echo "sshd is up — reachable over the tailnet as $(hostname -s 2>/dev/null || hostname)"
    else
      echo "Warning: sshd is not listening on port 22 — enable it manually, then re-run install.sh" >&2
    fi
  else
    record_decline tailscale-sshd
    skip_msg "SSH over Tailscale already declined"
  fi
  unset _sshd_answer
fi
unset _sshd_os _sshd_supported

# SSH directly into WSL over Tailscale (mirrored networking only). See the
# _wsl_* helpers near the top for why mirrored mode is the enabler and why we
# use a dedicated port. Inbound still needs a Hyper-V firewall allow on the
# Windows side, which needs elevation we don't have from here — so we finish
# the Linux side and print the exact elevated command for the user to run.
if ! grep -qi microsoft /proc/version 2>/dev/null; then
  : # not WSL — the tailscale-sshd step above owns macOS/Linux
elif ! _wsl_mirrored; then
  : # WSL without mirrored networking — defers to powershell/install.ps1
elif _wsl_sshd_ready; then
  skip_msg "WSL sshd already listening on $_WSL_SSHD_PORT with committed keys authorized"
elif was_declined wsl-sshd; then
  skip_msg "SSH into WSL already declined"
else
  read -rp "${PROMPT_COLOR}Enable SSH directly into WSL over Tailscale (native sshd on port $_WSL_SSHD_PORT, key-only auth; uses sudo)? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _wsl_sshd_answer
  if [[ "$_wsl_sshd_answer" =~ ^[Yy]$ ]]; then
    echo "${YES_COLOR}(Selected y) Setting up sshd inside WSL...${RESET}"
    if [ -z "$(_tailnet_ip)" ]; then
      echo "Note: no tailnet (100.x) address is mirrored into WSL — make sure Tailscale is running on the Windows host, or this will only be reachable on the LAN." >&2
    fi

    # Authorize the committed keys before disabling password auth, so the
    # key-only config can't create a lockout window (mirrors tailscale-sshd).
    _merge_authorized_keys "$DOTFILES/ssh/authorized_keys" "$HOME/.ssh/authorized_keys"

    if [ ! -x /usr/sbin/sshd ] && ! command -v sshd &>/dev/null; then
      if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y openssh-server
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y openssh-server
      elif command -v pacman &>/dev/null; then
        sudo pacman -S --needed --noconfirm openssh
      elif command -v apk &>/dev/null; then
        sudo apk add openssh-server
      else
        echo "No supported package manager found; install openssh-server manually" >&2
      fi
    fi

    # Dedicated port + key-only auth via a drop-in. Ubuntu's main sshd_config
    # leaves Port commented, so this is the only Port directive — sshd listens
    # on $_WSL_SSHD_PORT alone and can't collide with a Windows-host sshd on 22.
    if grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config 2>/dev/null; then
      sudo mkdir -p /etc/ssh/sshd_config.d
      sudo tee /etc/ssh/sshd_config.d/010-dotfiles.conf >/dev/null <<EOF
# Managed by dotfiles install.sh (SSH into WSL step). Mirrored networking makes
# this listener reachable at the tailnet IP; Tailscale ACLs gate the network
# layer and these settings gate authentication.
Port $_WSL_SSHD_PORT
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
      echo "Wrote /etc/ssh/sshd_config.d/010-dotfiles.conf (port $_WSL_SSHD_PORT, key-only auth)"
    else
      echo "Warning: /etc/ssh/sshd_config has no sshd_config.d include; skipped port/key-only config" >&2
    fi

    if command -v systemctl &>/dev/null; then
      # Unit name is ssh on Debian/Ubuntu, sshd on Fedora/Arch/Alpine.
      sudo systemctl enable --now ssh 2>/dev/null \
        || sudo systemctl enable --now sshd 2>/dev/null \
        || echo "Warning: could not enable the ssh/sshd unit" >&2
      # Restart (not reload) so the new Port takes effect if sshd was running.
      sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
    else
      echo "Warning: no systemctl (is systemd enabled in /etc/wsl.conf?); start sshd manually" >&2
    fi

    if _sshd_listening "$_WSL_SSHD_PORT"; then
      _tip="$(_tailnet_ip || true)"  # || true: bare assignment must not trip set -e when no tailnet IP
      echo "sshd is up inside WSL on port $_WSL_SSHD_PORT."
      echo "${BANNER_COLOR}One more step — run this in an ELEVATED PowerShell on the Windows host to open the Hyper-V firewall:${RESET}"
      echo "  New-NetFirewallHyperVRule -Name 'WSL-SSH-$_WSL_SSHD_PORT' -DisplayName 'WSL SSH ($_WSL_SSHD_PORT)' -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts $_WSL_SSHD_PORT"
      [ -n "$_tip" ] && echo "Then from another tailnet machine: ssh -p $_WSL_SSHD_PORT $USER@$_tip"
      unset _tip
    else
      echo "Warning: sshd is not listening on port $_WSL_SSHD_PORT — check 'sudo systemctl status ssh' and re-run install.sh" >&2
    fi
  else
    record_decline wsl-sshd
    skip_msg "SSH into WSL already declined"
  fi
  unset _wsl_sshd_answer
fi

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

# WSL: route link/file clicks to the Windows host. Under WSLg the xdg
# defaults point at Linux GUI apps, so a clicked file:// or http(s):// link
# (or a folder open) lands in a Linux browser/file manager instead of the
# native Windows app. wslu's `wslview` translates the path (wslpath -w) and
# hands off to Windows; we install it and register it as the default handler.
# WSL-only — the whole block no-ops elsewhere. shellrc separately exports
# BROWSER=wslview (guarded by `command -v wslview`) for CLI tools.
#
# Note: xdg-open resolves a file:// link to a *regular file* by the file's
# content MIME type, NOT the x-scheme-handler/file association — so making a
# clicked file open Windows-side means mapping the content types, not just the
# scheme. We map every concrete type in the shared-mime-info db (plus the web
# schemes and folders), which is what "open everything in Windows" requires.
# Trade-off: text files no longer open in terminal vim via a click; running
# `vim file` directly is unaffected (this only touches xdg-open routing).
if grep -qi microsoft /proc/version 2>/dev/null; then
  # Point wslview at the web/file schemes, folders, and every concrete MIME
  # type the system knows about. Run in a subshell-style function so the
  # positional-param accumulation (`set --`) can't leak to the script.
  _wsl_register_handlers() {
    command -v xdg-mime &>/dev/null || return 0
    xdg-settings set default-web-browser wslview.desktop 2>/dev/null || true
    local d media f sub
    set --  # function-local positionals; does not touch the script's $@
    for d in /usr/share/mime/*/; do
      media=$(basename "$d")
      case "$media" in
        inode|x-content|x-scheme-handler|multipart|packages|icons) continue ;;
      esac
      for f in "$d"*.xml; do
        [ -e "$f" ] || continue
        sub=$(basename "$f" .xml)
        set -- "$@" "$media/$sub"
      done
    done
    xdg-mime default wslview.desktop \
      x-scheme-handler/http x-scheme-handler/https \
      x-scheme-handler/file inode/directory "$@" 2>/dev/null || true
  }

  # "Fully configured" signal: wslview present AND a representative content
  # type (text/plain) already routes to it — proves the per-type mapping ran,
  # not just the scheme handlers. Mirrored by is_satisfied(wsl-open) above.
  _wslview_ready=false
  if command -v wslview &>/dev/null \
    && [ "$(xdg-mime query default text/plain 2>/dev/null)" = "wslview.desktop" ]; then
    _wslview_ready=true
  fi

  if [ "$_wslview_ready" = true ]; then
    skip_msg "wslview already installed and registered as the default handler for links/files"
  elif was_declined wsl-open; then
    skip_msg "wslview link redirection already declined"
  else
    read -rp "${PROMPT_COLOR}Route link/file clicks to Windows via wslview? y/${N_COLOR}[N]${PROMPT_COLOR}${RESET} " _wslview_answer
    if [[ "$_wslview_answer" =~ ^[Yy]$ ]]; then
      echo "${YES_COLOR}(Selected y) Setting up wslview...${RESET}"
      if ! command -v wslview &>/dev/null; then
        if command -v apt-get &>/dev/null; then
          sudo apt-get update && sudo apt-get install -y wslu
        else
          echo "No apt-get found; install wslu manually (https://github.com/wslutilities/wslu)" >&2
        fi
      fi
      if command -v wslview &>/dev/null && command -v xdg-mime &>/dev/null; then
        _wsl_register_handlers
        echo "Registered wslview as the default handler for web links, folders, and all file types"
      else
        echo "wslview or xdg-mime unavailable; skipped handler registration" >&2
      fi
    else
      record_decline wsl-open
      skip_msg "wslview link redirection already declined"
    fi
    unset _wslview_answer
  fi
  unset _wslview_ready
  unset -f _wsl_register_handlers 2>/dev/null || true
fi

# Seed migration tracker if missing, then run any pending migrations
if [ ! -f "$STATE_DIR/migrated" ]; then
  echo "0" > "$STATE_DIR/migrated"
fi
"$DOTFILES/git-hooks/post-merge"

echo ""
echo "${YES_COLOR}Done!${RESET} Machine-specific config goes in ~/.zshrc.local or ~/.bashrc.local"
echo ""
echo "${PROMPT_COLOR}Restarting your shell to pick up new config...${RESET}"
exec "${SHELL:-/bin/bash}"

