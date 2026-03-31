# Shared config (early, so PATH is set before tools that depend on it)
. ~/.shellrc

# zoxide
export _ZO_DOCTOR=0
eval "$(zoxide init zsh)"

# Prompt: user@machine in light blue, current dir only, with %
setopt PROMPT_SUBST

_git_branch_info() {
  local branch dirty=""
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
  git diff --quiet 2>/dev/null || dirty="*"
  local color
  if [[ -n "$dirty" ]]; then
    color="210"
  elif [[ "$branch" == "main" || "$branch" == "master" ]]; then
    color="218"
  else
    color="green"
  fi
  printf ' %%F{%s}(%s%s)%%f' "$color" "$dirty" "$branch"
}

_outbox_count() {
  local n
  n=$(find ~/.metacog/outbox -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  (( n > 0 )) && printf ' %%F{red}(%d)%%f' "$n"
}

PROMPT='%F{117}%n@%m%f %2~$(_git_branch_info)$(_outbox_count) %# '

# Suppress glob expansion for message tools
alias inbox='noglob inbox'
alias outbox='noglob outbox'

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
