# Shared filesystem helpers for the dotfiles infrastructure: idempotent
# symlink and wrapper-file installers. Sourced by install.sh and by any
# migration that needs to backfill an install step on existing machines.
#
# Usage:
#   DOTFILES="..." . "$DOTFILES/lib/helpers.sh"
#
# Callers must define $DOTFILES (absolute path to repo root) before
# invoking the helpers — symlink source paths are passed in by the caller,
# not derived here, so any path arg works. Colors are auto-loaded from
# lib/colors.sh if not already in scope.

if [ -z "${RESET:-}" ]; then
  _helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=colors.sh
  . "$_helpers_dir/colors.sh"
  unset _helpers_dir
fi

skip_msg() {
  printf '%s%s%s\n' "$SKIP_COLOR" "$*" "$RESET"
}

# Idempotent symlink. If $dst already points at $src, no-op. If it's a
# different symlink, replace. If it's a real file, back it up to $dst.bak
# (refuses if .bak already exists — manual reconciliation required).
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

# Like link() but for shell-style configs that support a "base + .local
# override" pattern. Any pre-existing file at $dst is moved to $local
# (the override file) so existing machine-specific content is preserved
# rather than backed up to .bak. Seeds an empty $local if none exists.
# Distro defaults (matching /etc/skel/<basename>) are discarded instead
# of moved, to keep $local free of boilerplate.
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

# Like link_shell but installs $dst as a real wrapper file (not a symlink)
# that sources $base. Used for ~/.bashrc and ~/.zshrc because third-party
# installers (nvm, conda, fzf, rustup, …) commonly do `>> ~/.bashrc`; with
# a symlink, those appends mutate the dotfiles repo. With a wrapper file
# the appends pile up below the source line and the repo file stays
# pristine. Hand-curated overrides still go in $local_file (sourced from
# $base near its end). Load order: base -> local -> app appends in wrapper.
install_wrapper() {
  local base="$1" dst="$2" local_file="$3"

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
