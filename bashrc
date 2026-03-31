# Shared config (early, so PATH is set before tools that depend on it)
. ~/.shellrc

# zoxide
eval "$(zoxide init bash)"
export _ZO_DOCTOR=0

# Prompt: user@machine in light blue, current dir, with $/#
PS1='\[\e[38;5;117m\]\u@\h\[\e[0m\] \w \$ '

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
bind 'set completion-ignore-case on'
bind 'TAB:menu-complete'
bind '"\e[Z":menu-complete-backward'

# atuin
[ -f "$HOME/.atuin/bin/env" ] && . "$HOME/.atuin/bin/env"
command -v atuin &>/dev/null && eval "$(atuin init bash)"

# Source machine-local config last so overrides (like DOTFILES_AUTO_UPDATE) win
[ -f ~/.bashrc.local ] && . ~/.bashrc.local
