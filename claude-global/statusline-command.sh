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
SSH_GREEN="\033[38;5;114m"
RED="\033[38;5;210m"
GREEN="\033[32m"
PINK="\033[38;5;218m"
WHITE="\033[97m"
LIGHT_ORANGE="\033[38;5;215m"
CORNFLOWER="\033[38;5;69m"
DIM="\033[2m"
RESET="\033[0m"

# Match the shell prompt: green over SSH, light blue locally.
if [ -n "$SSH_CONNECTION" ]; then
  host_color="$SSH_GREEN"
else
  host_color="$LIGHT_BLUE"
fi
user_host="${host_color}$(whoami)@$(hostname -s)${RESET}"
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

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
stop_file="$HOME/.claude/last-stop/$session_id"

# Last-message timestamp [HH:MM]: when Claude's last visible reply landed,
# written per-session by the stop-last-message-time.sh Stop hook. Rendered
# dim while a turn is in flight (prompt stamped at/after the last Stop by
# the user-prompt-last-message-stale.sh UserPromptSubmit hook); the next
# Stop's fresher epoch lights it back up. See docs/HOOKS.md.
time_part=""
if [ -n "$session_id" ] && [ -f "$stop_file" ]; then
  read -r stop_epoch last_msg_time stop_tz < "$stop_file" 2>/dev/null
  if [ -n "$last_msg_time" ]; then
    hh="${last_msg_time%%:*}"
    mm="${last_msg_time#*:}"; mm="${mm%%:*}"
    prompt_epoch=$(cat "$stop_file.prompt" 2>/dev/null)
    if [ -n "$prompt_epoch" ] && [ "$prompt_epoch" -ge "${stop_epoch:-0}" ] 2>/dev/null; then
      time_part=" ${DIM}|${RESET} ${DIM}[${hh}:${mm}${stop_tz:+ ${stop_tz}}]${RESET}"
    else
      time_part=" ${DIM}|${RESET} ${LIGHT_ORANGE}[${RESET}${WHITE}${hh}${RESET}${LIGHT_ORANGE}:${mm}${stop_tz:+ ${stop_tz}}]${RESET}"
    fi
  fi
fi

# Session-start timestamp [HH:MM TZ]: when this session began, stamped
# write-once by the session-start-time.sh SessionStart hook. Cornflower
# with a white hour. Fencepost zero: it stands in for the last-message
# stamp until the first Stop produces one, then yields — only the most
# recent boundary stamp is shown. While the first turn is in flight
# (prompt stamped, no Stop yet) it renders dim, same as the last-message
# stamp does on later turns. See docs/HOOKS.md.
start_part=""
start_file="$HOME/.claude/session-start/$session_id"
if [ -n "$session_id" ] && [ -z "$time_part" ] && [ -f "$start_file" ]; then
  read -r _ start_time start_tz < "$start_file" 2>/dev/null
  if [ -n "$start_time" ]; then
    s_hh="${start_time%%:*}"
    s_mm="${start_time#*:}"; s_mm="${s_mm%%:*}"
    if [ -f "$stop_file.prompt" ] && [ ! -f "$stop_file" ]; then
      start_part=" ${DIM}|${RESET} ${DIM}[${s_hh}:${s_mm}${start_tz:+ ${start_tz}}]${RESET}"
    else
      start_part=" ${DIM}|${RESET} ${CORNFLOWER}[${RESET}${WHITE}${s_hh}${RESET}${CORNFLOWER}:${s_mm}${start_tz:+ ${start_tz}}]${RESET}"
    fi
  fi
fi

# Fixed-breakpoint wrap: identity (user@host dir) always stays on line 1;
# the status tail (branch, ctx, local extras, timestamps) drops to line 2 as
# one unit when the combined line would overflow the terminal. COLUMNS is set
# by Claude Code >= 2.1.153 before invoking the script; older versions get an
# 80-col guess.
visible_len() {
  printf '%b' "$1" | sed $'s/\x1b\\[[0-9;]*m//g' | wc -m | tr -d ' '
}

head_part="${user_host}${dir_part}"
tail_part="${branch_part}${ctx_part}${extra}${start_part}${time_part}"

if [ "$(visible_len "${head_part}${tail_part}")" -le "${COLUMNS:-80}" ]; then
  printf '%b\n' "${head_part}${tail_part}"
else
  printf '%b\n%b\n' "$head_part" "${tail_part# }"
fi
