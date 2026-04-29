# Color constants used by install.sh, helpers, migrations, and post-merge.
# Source this from any script that wants matching color output:
#   . "$DOTFILES/lib/colors.sh"
# Pure data, no behavior. Bash $'...' ANSI-C quoting; safe under set -euo.

PROMPT_COLOR=$'\033[1;38;5;117m'   # bold light blue (matches shell prompt)
YES_COLOR=$'\033[1;38;5;120m'      # light green
N_COLOR=$'\033[1;38;5;210m'        # light red (for N in y/[N] prompts)
SKIP_COLOR=$'\033[38;5;240m'       # dark grey (for "already X" skip messages)
BANNER_COLOR=$'\033[38;5;244m'     # mid grey (for startup decision banner)
RESET=$'\033[0m'
