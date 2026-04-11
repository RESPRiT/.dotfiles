# Shared config (early, so PATH is set before tools that depend on it)
. ~/.shellrc

# zoxide
export _ZO_DOCTOR=0
eval "$(zoxide init bash)"

# Prompt: user@machine in light blue, current dir, with $/#
if [[ -n "$SSH_CONNECTION" ]]; then
  PS1='\[\e[38;5;114m\]\u@\h\[\e[0m\] \w$(_git_branch_info) \$ '
else
  PS1='\[\e[38;5;117m\]\u@\h\[\e[0m\] \w$(_git_branch_info) \$ '
fi

# History
HISTFILE=~/.bash_history
HISTSIZE=10000
HISTFILESIZE=10000
HISTCONTROL=ignoredups
shopt -s histappend
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# Tab completion with cycling and case-insensitive matching
if [ -f /etc/bash_completion ]; then
  . /etc/bash_completion
fi
if [[ $- == *i* ]]; then
  bind 'set completion-ignore-case on'
  bind 'TAB:menu-complete'
  bind '"\e[Z":menu-complete-backward'
fi

# atuin
[ -f "$HOME/.atuin/bin/env" ] && . "$HOME/.atuin/bin/env"
command -v atuin &>/dev/null && eval "$(atuin init bash)"

# Source machine-local config last so overrides (like DOTFILES_AUTO_UPDATE) win
[ -f ~/.bashrc.local ] && . ~/.bashrc.local

# Auto-update dotfiles (must run after local rc sets DOTFILES_AUTO_UPDATE)
if [ -d "$HOME/.dotfiles/.git" ] && [ "$DOTFILES_AUTO_UPDATE" = "1" ]; then
  (_dotfiles_update &)
  _dotfiles_show_update() {
    local msg="$HOME/.dotfiles/.update-msg"
    if [ -f "$msg" ]; then
      cat "$msg"
      rm -f "$msg"
      PROMPT_COMMAND="${PROMPT_COMMAND/_dotfiles_show_update;/}"
      unset -f _dotfiles_show_update
    fi
  }
  PROMPT_COMMAND="_dotfiles_show_update;${PROMPT_COMMAND:+$PROMPT_COMMAND}"
fi
unset -f _dotfiles_update
