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

# Source machine-local config last so overrides (like DOTFILES_AUTO_UPDATE) win
[ -f ~/.bashrc.local ] && . ~/.bashrc.local

# Auto-update repos (must run after local rc sets the *_AUTO_UPDATE flags).
# Synchronous so post-merge migration output is visible at startup.
if [ -d "$HOME/.dotfiles/.git" ] && [ "$DOTFILES_AUTO_UPDATE" = "1" ]; then
  _repo_auto_update dotfiles "$HOME/.dotfiles"
fi
if [ -d "$HOME/.docs/.git" ] && [ "$DOCS_AUTO_UPDATE" = "1" ]; then
  _repo_auto_update docs "$HOME/.docs"
fi
unset -f _repo_auto_update
