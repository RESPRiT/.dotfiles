#!/bin/sh
# UserPromptSubmit: keep the session's repo aware of remote state, so the
# assistant doesn't assume the local branch (or main) is current when it has
# actually fallen behind origin.
#
# Each turn this hook (a) fires a throttled `git fetch` for the repo the
# session's cwd lives in, and (b) reads the now-cached remote-tracking refs
# and, IF the local branch is behind/diverged, injects a one-line summary into
# the model's context. `git fetch` only updates remote-tracking refs — it never
# touches the working tree, index, or current branch — so it is safe to run
# against any repo unprompted.
#
# Throttle: the fetch runs at most once per CLAUDE_GIT_FETCH_TTL_MIN minutes
# (default 5), gated by an mtime stamp in the repo's *common* git dir. The stamp
# is touched BEFORE the fetch so a slow/flaky network can't make every turn
# re-fetch, and so sibling worktrees of the same repo share one gate (their
# remote-tracking refs are shared, so a single fetch serves them all).
#
# Timing: on the turn the throttle opens, the fetch runs INLINE with a short cap
# (CLAUDE_GIT_FETCH_TIMEOUT, default 3s) so the reported numbers are fresh from
# the first message; every other turn reads cached refs with no network and
# near-zero latency.
#
# Worktrees: cwd may be a linked worktree (where .git is a file). We resolve the
# repo via `git -C "$cwd"` and the stamp via --git-common-dir, so both the
# throttle and the report work whether cwd is the main checkout or a worktree.
# main vs origin/main is readable from any worktree because those refs are
# shared — which is exactly the "on a feature branch, assumed main was current"
# blind spot this addresses.
#
# Verbosity: report only when behind/diverged; silent when up to date, ahead
# only, detached with no upstream, not a repo, or git is unavailable.
#
# stdout from a UserPromptSubmit hook is injected into the model's context for
# the turn, so anything echoed below becomes guidance the assistant sees.

command -v git >/dev/null 2>&1 || exit 0

# cwd from the JSON payload on stdin (no jq, matching the sibling hook).
cwd=$(grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

# Must be inside a work tree; bail silently otherwise.
git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The common git dir holds the shared refs and our throttle stamp. Resolve to an
# absolute path so it is valid regardless of the hook's own working directory
# (and so it works from a worktree, where plain .git is a file, not a dir).
common=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$common" in /*) ;; *) common="$cwd/$common" ;; esac
stamp="$common/.last-autofetch"

ttl_min=${CLAUDE_GIT_FETCH_TTL_MIN:-5}

# Is a fetch due? (no stamp yet, or older than the TTL). -mmin is supported by
# both BSD (macOS) and GNU find.
due=0
if [ ! -e "$stamp" ]; then
  due=1
elif [ -n "$(find "$stamp" -mmin +"$ttl_min" 2>/dev/null)" ]; then
  due=1
fi

# Run a command under a wall-clock timeout, mirroring shellrc's _with_timeout
# (this hook does not source shellrc, so the chain is inlined here).
run_timeout() {
  secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else "$@"; fi
}

if [ "$due" -eq 1 ]; then
  # Touch the stamp BEFORE fetching: even if the fetch fails or times out, we
  # won't retry until the next interval (no per-turn hammering on flaky links).
  : > "$stamp" 2>/dev/null || touch "$stamp" 2>/dev/null || true
  GIT_TERMINAL_PROMPT=0 run_timeout "${CLAUDE_GIT_FETCH_TIMEOUT:-3}" \
    git -C "$cwd" fetch --quiet 2>/dev/null || true
fi

plural() { [ "$1" -eq 1 ] && printf commit || printf commits; }

msg=""

# Current branch vs its upstream. `rev-list --left-right --count A...B` prints
# "<left> <right>": commits in HEAD not upstream (ahead), then upstream not HEAD
# (behind). Skipped when detached or no upstream is configured.
branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)
if [ -n "$branch" ] && git -C "$cwd" rev-parse --verify -q '@{u}' >/dev/null 2>&1; then
  set -- $(git -C "$cwd" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null)
  ahead=${1:-0}; behind=${2:-0}
  up=$(git -C "$cwd" rev-parse --abbrev-ref '@{u}' 2>/dev/null)
  if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
    msg="local ${branch} is ${ahead} ahead, ${behind} behind ${up} (diverged — pull/rebase before relying on it)"
  elif [ "$behind" -gt 0 ]; then
    msg="local ${branch} is ${behind} $(plural "$behind") behind ${up} (pull before relying on it)"
  fi
fi

# main/master vs origin/<default>, reported only when NOT already on the default
# branch (otherwise the upstream check above covered it). This is the core case:
# working on a feature branch while assuming main is current.
def=$(git -C "$cwd" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
def=${def#origin/}
if [ -z "$def" ]; then
  for c in main master; do
    if git -C "$cwd" rev-parse --verify -q "refs/remotes/origin/$c" >/dev/null 2>&1; then
      def=$c; break
    fi
  done
fi
if [ -n "$def" ] && [ "$branch" != "$def" ] \
   && git -C "$cwd" rev-parse --verify -q "refs/heads/$def" >/dev/null 2>&1 \
   && git -C "$cwd" rev-parse --verify -q "refs/remotes/origin/$def" >/dev/null 2>&1; then
  set -- $(git -C "$cwd" rev-list --left-right --count "${def}...origin/${def}" 2>/dev/null)
  dbehind=${2:-0}
  if [ "$dbehind" -gt 0 ]; then
    line="local ${def} is ${dbehind} $(plural "$dbehind") behind origin/${def}"
    if [ -n "$msg" ]; then
      msg="${msg}; ${line}"
    else
      msg="${line} (you are on ${branch:-a detached HEAD})"
    fi
  fi
fi

[ -n "$msg" ] || exit 0
printf 'git: %s.\n' "$msg"
