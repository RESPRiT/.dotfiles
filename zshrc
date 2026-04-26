# Shared config (early, so PATH is set before tools that depend on it)
. ~/.shellrc

# zoxide
export _ZO_DOCTOR=0
eval "$(zoxide init zsh)"

# Prompt: user@machine in light blue, current dir only, with %
setopt PROMPT_SUBST

if [[ -n "$SSH_CONNECTION" ]]; then
  PROMPT='%F{114}%n@%m%f %2~$(_git_branch_info) %# '
else
  PROMPT='%F{117}%n@%m%f %2~$(_git_branch_info) %# '
fi

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS

# Directory navigation
setopt AUTO_CD

# Correction
#setopt CORRECT
#setopt CORRECT_ALL

# Vim mode
# bindkey -v

# Tab completion with cycling
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
zmodload zsh/complist
autoload -Uz compinit && compinit
setopt COMPLETE_ALIASES

# Shift-tab to cycle backwards
bindkey -M menuselect '^[[Z' reverse-menu-complete

# Source machine-local config last so overrides (like DOTFILES_AUTO_UPDATE) win
[ -f ~/.zshrc.local ] && source ~/.zshrc.local

# Auto-update repos (must run after local rc sets the *_AUTO_UPDATE flags).
# Synchronous so post-merge migration output is visible at startup.
if [ -d "$HOME/.dotfiles/.git" ] && [ "$DOTFILES_AUTO_UPDATE" = "1" ]; then
  _repo_auto_update dotfiles "$HOME/.dotfiles"
fi
if [ -d "$HOME/.docs/.git" ] && [ "$DOCS_AUTO_UPDATE" = "1" ]; then
  _repo_auto_update docs "$HOME/.docs"
fi
unset -f _repo_auto_update
