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

if [ -x "$TPM_DIR/bin/install_plugins" ]; then
  "$TPM_DIR/bin/install_plugins"
fi
