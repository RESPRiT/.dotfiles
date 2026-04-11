#!/usr/bin/env bash
#
# Install TPM (tmux plugin manager) and fetch declared plugins.
# Required because tmux.conf now declares plugins via @plugin and ends with
# `run '~/.tmux/plugins/tpm/tpm'`. Without TPM installed, that line errors
# on every config reload and the declared plugins (tmux-yank, tmux-resurrect)
# are never fetched.

set -euo pipefail

# Skip if tmux isn't installed — nothing to manage
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not installed, skipping TPM setup"
  exit 0
fi

TPM_DIR="$HOME/.tmux/plugins/tpm"

if [ ! -d "$TPM_DIR" ]; then
  mkdir -p "$HOME/.tmux/plugins"
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
  echo "Installed tpm"
fi

# Skip plugin install if ~/.tmux.conf hasn't been linked yet (install.sh has
# never run on this machine). The next install.sh run will handle it.
if [ ! -f "$HOME/.tmux.conf" ]; then
  echo "~/.tmux.conf not found, skipping plugin install"
  exit 0
fi

if [ -x "$TPM_DIR/bin/install_plugins" ]; then
  # install_plugins reads TMUX_PLUGIN_MANAGER_PATH from a tmux server, but
  # `tmux start-server` alone doesn't load the conf. Source the conf first so
  # the `run '~/.tmux/plugins/tpm/tpm'` line executes and sets the variable.
  tmux start-server \; source-file "$HOME/.tmux.conf"
  "$TPM_DIR/bin/install_plugins"
fi
