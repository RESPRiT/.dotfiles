#!/usr/bin/env bash
# Claude Code status line: portable base.
# Mirrors the zsh prompt style: user@machine dir (branch) | ctx%
#
# Composition: the committed base emits portable segments and then invokes
# ~/.claude/statusline-command.local.sh (if present) with the same input JSON
# on stdin. The local script writes additional segments to stdout (no newline)
# and we append. This lets per-machine extensions (metacog/trace, etc.) plug in
# without forking the base. install.sh's link_shell symlinks this file to
# ~/.claude/statusline-command.sh and moves any pre-existing real file at that
# path to ~/.claude/statusline-command.local.sh.

input=$(cat)

cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')

short_dir=$(printf '%s' "$cwd" | awk -F'/' '{
  n = NF
  if (n >= 2) print $(n-1) "/" $n
  else print $n
}')

branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
dirty=""
if [ -n "$branch" ] && [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
  dirty="*"
fi

LIGHT_BLUE="\033[38;5;117m"
RED="\033[38;5;210m"
GREEN="\033[32m"
PINK="\033[38;5;218m"
DIM="\033[2m"
RESET="\033[0m"

user_host="${LIGHT_BLUE}$(whoami)@$(hostname -s)${RESET}"
dir_part=" ${short_dir}"

if [ -n "$branch" ]; then
  if [ -n "$dirty" ]; then
    branch_part=" ${RED}(${dirty}${branch})${RESET}"
  elif [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    branch_part=" ${PINK}(${branch})${RESET}"
  else
    branch_part=" ${GREEN}(${branch})${RESET}"
  fi
else
  branch_part=""
fi

display_pct="${used_pct:-0}"
used_int=${display_pct%.*}
if [ "${used_int:-0}" -ge 80 ]; then
  ctx_color="\033[31m"
elif [ "${used_int:-0}" -ge 50 ]; then
  ctx_color="\033[33m"
else
  ctx_color="\033[32m"
fi
ctx_part=" ${DIM}|${RESET} ${ctx_color}ctx:${display_pct}%${RESET}"

extra=""
local_script="$HOME/.claude/statusline-command.local.sh"
if [ -f "$local_script" ]; then
  extra=$(printf '%s' "$input" | bash "$local_script" 2>/dev/null || true)
fi

printf '%b\n' "${user_host}${dir_part}${branch_part}${ctx_part}${extra}"
