#!/usr/bin/env bash
# Claude Code status line: portable base.
# Mirrors the zsh prompt style: user@machine dir (branch) | ctx%
#
# Composition: the committed base emits portable segments and then invokes
# ~/.claude/statusline-command.local.sh (if present) with the same input JSON
# on stdin. The local script writes additional segments to stdout (no newline)
# and we append. This lets per-host-only segments plug in without forking the
# base (the session-id head and sesh segments that once lived in the local
# script are now rendered natively below).
# install.sh's link_shell symlinks this file to
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
# "^" marks "ahead of upstream"; shows regardless of color (dirty wins the color).
ahead=""
if [ -n "$branch" ]; then
  ahead_count=$(git -C "$cwd" rev-list --count '@{upstream}..HEAD' 2>/dev/null)
  [ -n "$ahead_count" ] && [ "$ahead_count" -gt 0 ] && ahead="^"
fi

LIGHT_BLUE="\033[38;5;117m"
SSH_GREEN="\033[38;5;114m"
RED="\033[38;5;210m"
GREEN="\033[32m"
PINK="\033[38;5;218m"
YELLOW="\033[38;5;220m"
LIGHT_ORANGE="\033[38;5;215m"
LIGHT_YELLOW="\033[38;5;229m"
CORNFLOWER="\033[38;5;69m"
DIM="\033[2m"
RESET="\033[0m"

# Theme-adaptive highlight. The bright-white "pop" used for the timestamp
# hour (and, in the local extension, the session-id head) is nearly
# invisible on light terminal themes. Claude Code persists the active theme
# in ~/.claude/settings.json as a light*/dark*-prefixed name, so read it and
# fall back to near-black on light backgrounds; anything else (incl. a
# missing/unreadable file) stays bright white, preserving prior behavior.
# Exported so the local statusline extension reuses the choice without
# re-detecting. The statusline input JSON does not carry the theme, so
# settings.json is the source of truth.
claude_theme=$(jq -r '.theme // empty' "$HOME/.claude/settings.json" 2>/dev/null)
case "$claude_theme" in
  light*) HIGHLIGHT="\033[38;5;16m" ;;
  *)      HIGHLIGHT="\033[97m" ;;
esac
export STATUSLINE_HIGHLIGHT="$HIGHLIGHT"

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
    branch_part=" ${RED}(${dirty}${branch}${ahead})${RESET}"
  elif [ -n "$ahead" ]; then
    branch_part=" ${YELLOW}(${branch}${ahead})${RESET}"
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

# Session-id head: first 8 chars of the session id, the 3-char prefix in the
# theme highlight and the 5-char remainder dim. When the session is tracked by
# sesh, append a (<alias-or-id>) indicator (the dirname encodes the optional
# alias; prefer it over the bare id). Self-guards on `command -v sesh`, so it
# no-ops where sesh isn't installed. Folded in from the old local extension.
session_part=""
if [ -n "$session_id" ]; then
  short_id="${session_id:0:8}"
  id_prefix="${short_id:0:3}"
  id_suffix="${short_id:3}"
  styled_id="${HIGHLIGHT}${id_prefix}${RESET}${DIM}${id_suffix}${RESET}"
  sesh_label=""
  if command -v sesh >/dev/null 2>&1; then
    sesh_path=$(sesh path --session-id "$short_id" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$sesh_path" ]; then
      sesh_dirname=$(basename "$sesh_path")
      sesh_alias=$(printf '%s' "$sesh_dirname" | sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-${short_id}-?//")
      sesh_label="${sesh_alias:-$short_id}"
    fi
  fi
  if [ -n "$sesh_label" ]; then
    session_part=" ${DIM}|${RESET} ${styled_id} ${LIGHT_YELLOW}(${sesh_label})${RESET}"
  else
    session_part=" ${DIM}|${RESET} ${styled_id}"
  fi
fi

# Last-message timestamp [HH:MM]: when Claude's last visible reply landed,
# written per-session by the stop-last-message-time.sh Stop hook. Rendered
# dim while a turn is in flight (prompt stamped at/after the last Stop by
# the user-prompt-last-message-stale.sh UserPromptSubmit hook); the next
# Stop's fresher epoch lights it back up. A stamp older than STALE_SECS
# renders all-red instead — the session has sat idle long past the point
# the time is glanceable context. A stale-red stamp from a previous local
# calendar day also gets a red " (N days ago)" suffix after the bracket.
# See docs/HOOKS.md.
STALE_SECS=$((8 * 3600))
now_epoch=$(date +%s)

# " (N days ago)" when epoch $1 falls on an earlier local calendar day than
# now; empty for today. Day boundaries use the current UTC offset (date +%z,
# portable across BSD/GNU) — a DST shift since the stamp can mis-bucket
# within an hour of midnight, acceptable for a glanceable hint.
days_ago_suffix() {
  off=$(date +%z)
  case "$off" in
    [+-][0-9][0-9][0-9][0-9])
      off_secs=$(( 10#${off:1:2} * 3600 + 10#${off:3:2} * 60 ))
      [ "${off:0:1}" = "-" ] && off_secs=$(( -off_secs ))
      ;;
    *) off_secs=0 ;;
  esac
  n=$(( (now_epoch + off_secs) / 86400 - ($1 + off_secs) / 86400 ))
  if [ "$n" -eq 1 ]; then
    printf ' (1 day ago)'
  elif [ "$n" -gt 1 ]; then
    printf ' (%s days ago)' "$n"
  fi
}
time_part=""
if [ -n "$session_id" ] && [ -f "$stop_file" ]; then
  read -r stop_epoch last_msg_time stop_tz < "$stop_file" 2>/dev/null
  if [ -n "$last_msg_time" ]; then
    hh="${last_msg_time%%:*}"
    mm="${last_msg_time#*:}"; mm="${mm%%:*}"
    prompt_epoch=$(cat "$stop_file.prompt" 2>/dev/null)
    if [ -n "$prompt_epoch" ] && [ "$prompt_epoch" -ge "${stop_epoch:-0}" ] 2>/dev/null; then
      time_part=" ${DIM}|${RESET} ${DIM}[${hh}:${mm}${stop_tz:+ ${stop_tz}}]${RESET}"
    elif [ "$stop_epoch" -gt 0 ] 2>/dev/null && [ $((now_epoch - stop_epoch)) -ge "$STALE_SECS" ]; then
      time_part=" ${DIM}|${RESET} ${RED}[${RESET}${HIGHLIGHT}${hh}${RESET}${RED}:${mm}${stop_tz:+ ${stop_tz}}]$(days_ago_suffix "$stop_epoch")${RESET}"
    else
      time_part=" ${DIM}|${RESET} ${LIGHT_ORANGE}[${RESET}${HIGHLIGHT}${hh}${RESET}${LIGHT_ORANGE}:${mm}${stop_tz:+ ${stop_tz}}]${RESET}"
    fi
  fi
fi

# Session-start timestamp [HH:MM TZ]: when this session began, stamped
# write-once by the session-start-time.sh SessionStart hook. Cornflower
# with a highlighted hour. Fencepost zero: it stands in for the last-message
# stamp until the first Stop produces one, then yields — only the most
# recent boundary stamp is shown. While the first turn is in flight
# (prompt stamped, no Stop yet) it renders dim, same as the last-message
# stamp does on later turns; past STALE_SECS it goes all-red the same
# way too. See docs/HOOKS.md.
start_part=""
start_file="$HOME/.claude/session-start/$session_id"
if [ -n "$session_id" ] && [ -z "$time_part" ] && [ -f "$start_file" ]; then
  read -r start_epoch start_time start_tz < "$start_file" 2>/dev/null
  if [ -n "$start_time" ]; then
    s_hh="${start_time%%:*}"
    s_mm="${start_time#*:}"; s_mm="${s_mm%%:*}"
    if [ -f "$stop_file.prompt" ] && [ ! -f "$stop_file" ]; then
      start_part=" ${DIM}|${RESET} ${DIM}[${s_hh}:${s_mm}${start_tz:+ ${start_tz}}]${RESET}"
    elif [ "$start_epoch" -gt 0 ] 2>/dev/null && [ $((now_epoch - start_epoch)) -ge "$STALE_SECS" ]; then
      start_part=" ${DIM}|${RESET} ${RED}[${RESET}${HIGHLIGHT}${s_hh}${RESET}${RED}:${s_mm}${start_tz:+ ${start_tz}}]$(days_ago_suffix "$start_epoch")${RESET}"
    else
      start_part=" ${DIM}|${RESET} ${CORNFLOWER}[${RESET}${HIGHLIGHT}${s_hh}${RESET}${CORNFLOWER}:${s_mm}${start_tz:+ ${start_tz}}]${RESET}"
    fi
  fi
fi

# Consolidated dir+branch: when the cwd is named after the branch (worktree
# convention, with the branch's "/" flattened to "-"), the duplicated suffix
# is dropped from the dir and the branch segment butted directly against
# the remainder, e.g. numeric-io/fdp-(*hrsn/fdp-981-...). Only a suffix match
# at a separator boundary counts, so branch "main" never eats the tail of an
# unrelated dir like "domain".
fused_part=""
if [ -n "$branch" ]; then
  norm_branch=${branch//\//-}
  case "$short_dir" in
    "$norm_branch"|*"/$norm_branch"|*"-$norm_branch"|*"_$norm_branch"|*".$norm_branch")
      fused_part=" ${short_dir%"$norm_branch"}${branch_part# }"
      ;;
  esac
fi

# Output cascade: consolidated one-liner whenever the dir is branch-named
# (it's strictly shorter than the full form, so no extra fit check ordering
# is needed), else full one-liner, else two lines wrapped before the branch
# with the continuation indented two spaces.
# COLUMNS is set by Claude Code >= 2.1.153 before invoking the script; older
# versions get an 80-col guess.
visible_len() {
  printf '%b' "$1" | sed $'s/\x1b\\[[0-9;]*m//g' | wc -m | tr -d ' '
}

cols=${COLUMNS:-80}
status_tail="${ctx_part}${session_part}${extra}${start_part}${time_part}"
head_part="${user_host}${dir_part}"
tail_part="${branch_part}${status_tail}"

if [ -n "$fused_part" ] && [ "$(visible_len "${user_host}${fused_part}${status_tail}")" -le "$cols" ]; then
  printf '%b\n' "${user_host}${fused_part}${status_tail}"
elif [ "$(visible_len "${head_part}${tail_part}")" -le "$cols" ]; then
  printf '%b\n' "${head_part}${tail_part}"
else
  printf '%b\n  %b\n' "$head_part" "${tail_part# }"
fi
