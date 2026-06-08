#!/bin/sh
# SessionStart: rename the wrapping tmux session to claude-<sid8> so the
# Claude session id shows up in tmux's session list and choose-tree picker.
#
# Only fires when the shellrc claude() wrapper launched tmux (signaled by
# CLAUDE_EXIT_FILE being set on the tmux session env). When the user runs
# claude inside their own tmux session, CLAUDE_EXIT_FILE is unset and we
# no-op so manually-named sessions are left alone.
#
# Leader ownership: CLAUDE_EXIT_FILE lives in the tmux *session* env, so it is
# inherited by *every* claude process spawned anywhere in the session --
# headless `claude -p` runs kicked off from a Bash tool or a hook, second
# interactive claudes in another pane/window, and (if they ever fire
# SessionStart) subagents. Each of their SessionStart events would otherwise
# hijack the session name and leave it pointing at an ephemeral, non-resumable
# id. So ownership is tracked by a lock: @claude-leader-pid, a session-scoped
# tmux var holding the pid of the owning ("leader") claude. The claude()
# wrapper stamps it with the pane-root claude's pid at session-creation time,
# so the launched session -- not whichever guest happens to fire SessionStart
# first -- owns the name. Only the lock holder may (re)name the session; its
# own lifecycle re-fires (/clear, /compact, --resume) keep the same pid, so the
# title still tracks the currently resumable id, while interloper sessions are
# ignored. The lock is considered *released* once its pid is no longer a live
# claude (the leader exited), so a guest that outlives the leader re-acquires
# ownership on its next SessionStart. The var is session-scoped: it survives
# /clear & /compact and dies with the session (destroy-unattached on).

[ -n "$CLAUDE_EXIT_FILE" ] || exit 0
[ -n "$TMUX" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Each SessionStart hook gets an independent copy of the JSON payload on
# stdin. Parse session_id without jq for portability.
sid=$(grep -o '"session_id":"[^"]*"' | head -1 | sed 's/.*://;s/"//g')
[ -n "$sid" ] || exit 0

# PID of the claude process that fired this hook: the nearest ancestor whose
# executable name contains "claude". Walking up from $PPID (rather than
# trusting it directly) tolerates an intermediate `sh -c` wrapper.
firing_claude=""
pid=$PPID
while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
  case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
    *claude*) firing_claude=$pid; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

# Read the lock and treat it as held only while its pid is still a live claude.
# A dead pid (leader exited) or one recycled by another program yields no
# "claude" from ps -> released, so the next SessionStart can re-acquire it.
leader=$(tmux show -v @claude-leader-pid 2>/dev/null)
case "$(ps -o comm= -p "$leader" 2>/dev/null)" in
  *claude*) ;;        # held by a live claude
  *) leader="" ;;     # empty / dead / recycled -> released
esac

# Acquire the released lock (handoff to a surviving guest) or seed it when the
# wrapper didn't stamp one (e.g. a session that predates the wrapper change).
if [ -z "$leader" ] && [ -n "$firing_claude" ]; then
  leader=$firing_claude
  tmux set @claude-leader-pid "$leader" 2>/dev/null
fi

# Only the lock holder may (re)name the session. If we couldn't identify the
# firing process (ps unavailable / unexpected naming), fall through and rename
# rather than regress the normal single-session case.
if [ -n "$firing_claude" ] && [ -n "$leader" ] && [ "$firing_claude" != "$leader" ]; then
  exit 0
fi

short=$(printf '%.8s' "$sid")
# rename-session fails with "duplicate session" if another wrapper already
# claimed this 8-char prefix; swallow and keep the existing claude-$$ name.
tmux rename-session "claude-$short" 2>/dev/null || true
