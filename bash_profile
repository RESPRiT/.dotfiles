# Bash login shells (e.g. SSH sessions) read ~/.bash_profile but NOT ~/.bashrc.
# Source ~/.bashrc here so login shells get the aliases, prompt, and functions
# defined in bashrc/shellrc — same behavior as a non-login interactive shell.
[ -f ~/.bashrc ] && . ~/.bashrc
