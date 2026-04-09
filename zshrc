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

# atuin
[ -f "$HOME/.atuin/bin/env" ] && . "$HOME/.atuin/bin/env"
command -v atuin &>/dev/null && eval "$(atuin init zsh)"

# Source machine-local config last so overrides (like DOTFILES_AUTO_UPDATE) win
[ -f ~/.zshrc.local ] && source ~/.zshrc.local

# Auto-update dotfiles (must run after local rc sets DOTFILES_AUTO_UPDATE)
if [ -d "$HOME/.dotfiles/.git" ] && [ "$DOTFILES_AUTO_UPDATE" = "1" ]; then
  (_dotfiles_update &)
  _dotfiles_show_update() {
    local msg="$HOME/.dotfiles/.update-msg"
    if [ -f "$msg" ]; then
      cat "$msg"
      rm -f "$msg"
      precmd_functions=(${precmd_functions:#_dotfiles_show_update})
      unset -f _dotfiles_show_update
    fi
  }
  precmd_functions+=(_dotfiles_show_update)
fi
unset -f _dotfiles_update
