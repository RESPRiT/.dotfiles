#!/bin/sh
# session-end-cleanup-chrome-mcp.sh — SessionEnd hook
#
# Kills the chrome-devtools-mcp process tree belonging to THIS Claude session
# only, so the isolated Chrome + node helpers don't leak after the session ends.
#
# Why this is needed: the MCP stack is
#     claude -> `pnpm dlx chrome-devtools-mcp` (node) -> chrome-devtools-mcp
#            -> telemetry watchdog (node) -> isolated Chrome
# and the watchdog deliberately detaches into its OWN process group, so it
# survives the normal teardown of the session's process group. That orphaned
# watchdog (and any Chrome it babysits) is the leak this hook closes.
#
# Why it is scoped, not a blanket pkill: multiple Claude sessions run
# concurrently, each with its own chrome-devtools-mcp stack hanging off its own
# `claude` process. `pkill -f chrome-devtools-mcp` would nuke every session's
# MCP. Instead we resolve THIS session's `claude` ancestor (the hook runs as a
# child of it) and only touch processes in that subtree — sibling sessions are
# left strictly alone. If we cannot positively identify our own session, we do
# nothing.

set -u

# SessionEnd delivers a JSON payload on stdin; drain it so the writer's pipe
# closes cleanly. We don't need any of its fields.
cat >/dev/null 2>&1 || true

# --- recursively print all transitive child pids of $1, one per line ---
descendants() {
  for _k in $(pgrep -P "$1" 2>/dev/null); do
    echo "$_k"
    descendants "$_k"
  done
}

# --- locate this session's `claude` process by walking up the parent chain ---
claude_pid=""
pid=$PPID
i=0
while [ "${pid:-0}" -gt 1 ] && [ "$i" -lt 12 ]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
  case "${comm##*/}" in
    claude) claude_pid=$pid; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  i=$((i + 1))
done

# Safety: no identified session => do nothing (never risk a sibling's procs).
[ -n "$claude_pid" ] || exit 0

# Set of pids that belong to our session: the claude proc and everything under
# it (space-padded for whole-word matching below).
our_pids=" $claude_pid $(descendants "$claude_pid" | tr '\n' ' ') "

# Select chrome-devtools-mcp processes that are ours: either in our subtree, or
# a watchdog whose recorded --parent-pid points into our subtree (catches a
# watchdog that has already been reparented to init).
targets=""
for p in $(pgrep -f 'chrome-devtools-mcp' 2>/dev/null); do
  case "$our_pids" in
    *" $p "*) targets="$targets $p"; continue ;;
  esac
  cmd=$(ps -o command= -p "$p" 2>/dev/null) || continue
  case "$cmd" in
    *watchdog*--parent-pid=*)
      ppid_arg=${cmd##*--parent-pid=}
      ppid_arg=${ppid_arg%% *}
      case "$our_pids" in
        *" $ppid_arg "*) targets="$targets $p" ;;
      esac
      ;;
  esac
done

[ -n "${targets# }" ] || exit 0

# Expand each matched process with its own descendants so the isolated Chrome
# (a child of chrome-devtools-mcp, which doesn't itself match the pattern) is
# included. Then dedupe.
expanded=""
for t in $targets; do
  expanded="$expanded $t $(descendants "$t" | tr '\n' ' ')"
done
targets=$(printf '%s\n' $expanded | awk 'NF' | sort -un | tr '\n' ' ')

# Dry-run hook for testing: print the kill set instead of signalling.
if [ -n "${CLEANUP_CHROME_MCP_DRYRUN:-}" ]; then
  echo "claude_pid=$claude_pid would kill: $targets"
  exit 0
fi

# Graceful TERM, brief grace period, then KILL any survivor.
# shellcheck disable=SC2086
kill -TERM $targets 2>/dev/null || true
sleep 0.5
for t in $targets; do
  kill -0 "$t" 2>/dev/null && kill -KILL "$t" 2>/dev/null || true
done

exit 0
