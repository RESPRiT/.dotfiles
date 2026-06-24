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
#
# Guard against PID reuse: each target's identity (start time + command) is
# snapshotted before the TERM/KILL grace period and re-verified immediately
# before every signal. macOS recycles PIDs aggressively, so a chrome PID that
# exits mid-teardown can be reassigned to an unrelated process (e.g. a Firefox
# helper) that would otherwise catch the stray signal; a recycled PID fails the
# identity match and is skipped. Each run appends a summary to
# .state/chrome-mcp-cleanup.log.

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

# Snapshot each target's identity — process start time + full command — so the
# kill phase can confirm a PID still refers to the same process before signalling.
proc_identity() {
  ps -o lstart= -o command= -p "$1" 2>/dev/null
}

# Audit log under the repo's .state/ (gitignored, rotated at 1MB), alongside the
# other cleanup logs. Best-effort — a logging failure never fails the hook, and
# logging is disabled when invoked outside the canonical hook path.
log=""
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || script_dir=""
case "$script_dir" in
  */claude-global/hooks)
    if mkdir -p "${script_dir%/claude-global/hooks}/.state" 2>/dev/null; then
      log="${script_dir%/claude-global/hooks}/.state/chrome-mcp-cleanup.log"
      if [ -f "$log" ]; then
        sz=$(wc -c <"$log" 2>/dev/null | tr -d ' ')
        [ "${sz:-0}" -gt 1048576 ] && mv "$log" "$log.1" 2>/dev/null || true
      fi
    fi
    ;;
esac
stamp=$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '?')
audit() { [ -n "$log" ] && printf '%s\n' "$1" >>"$log" 2>/dev/null || true; }

# Verified work set: "pid<TAB>identity" per line, skipping targets already gone.
work=$(
  for t in $targets; do
    id=$(proc_identity "$t")
    [ -n "$id" ] || continue
    printf '%s\t%s\n' "$t" "$id"
  done
)

# Dry-run hook for testing: print the kill set and identities, don't signal.
if [ -n "${CLEANUP_CHROME_MCP_DRYRUN:-}" ]; then
  echo "claude_pid=$claude_pid would kill: $targets"
  printf '%s\n' "$work" | awk 'NF{print "  - "$0}'
  exit 0
fi

audit "$stamp session=$claude_pid targets=[${targets% }]"

# Signal only PIDs whose live identity still matches the snapshot. A mismatch
# means the PID was recycled between snapshot and now — never signal it, and
# record the reuse so it's auditable. Reaching the KILL pass, a target that
# exited cleanly under TERM no longer matches and is left alone.
signal_verified() {
  sig=$1
  printf '%s\n' "$work" | while IFS=$(printf '\t') read -r pid id; do
    [ -n "$pid" ] || continue
    cur=$(proc_identity "$pid")
    if [ -z "$cur" ]; then
      :                                   # already exited; nothing to signal
    elif [ "$cur" = "$id" ]; then
      kill -"$sig" "$pid" 2>/dev/null && audit "  $sig pid=$pid $id" || true
    else
      audit "  SKIP-REUSED pid=$pid was=[$id] now=[$cur]"
    fi
  done
}

# Graceful TERM, brief grace period, then KILL any verified survivor.
signal_verified TERM
sleep 0.5
signal_verified KILL

exit 0
