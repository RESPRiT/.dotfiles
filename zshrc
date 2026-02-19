# z
eval "$(zoxide init zsh)"
export _ZO_DOCTOR=0

# Prompt: user@machine in light blue, current dir only, with %
PROMPT='%F{117}%n@%m%f %2~ %# '

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

# Colorized ls
export CLICOLOR=1
export LSCOLORS=Exfxcxdxcxegedabagaced

# Aliases
alias ll='ls -la'
alias l='ls -l'
alias cd='z'
alias ..='z ..'
alias ...='z ../..'
alias grep='grep --color=auto'
alias mkdir='mkdir -pv'
alias path='echo $PATH | tr ":" "\n"'

# Source machine-local config if present
[ -f ~/.zshrc.local ] && source ~/.zshrc.local

# Claude
export PATH="$HOME/.local/bin:$PATH"
export ENABLE_LSP_TOOL=1

# atuin
. "$HOME/.atuin/bin/env"
eval "$(atuin init zsh)"

# bun completions
[ -s "/Users/resprit/.bun/_bun" ] && source "/Users/resprit/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# deno
. "/Users/resprit/.deno/env"
