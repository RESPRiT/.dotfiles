# Shared git-state logic for the two prompt segments that render "(branch)":
# the interactive shell prompt (_git_branch_info in shellrc) and the Claude Code
# status line (claude-global/statusline-command.sh). Both want identical
# semantics; keeping the gathering here stops them drifting (a staged-only change
# once showed dirty in the status line but not the shell prompt).
#
# This lib gathers facts only — the markers and the color cascade. Rendering
# (zsh %F{} vs bash readline-wrapped ANSI vs the status line's raw ANSI) stays
# in each caller, since those escapes are context-specific.
#
# Markers:
#   *  dirty  — any staged, unstaged, or untracked change
#   ^  ahead  — commits ahead of @{upstream} (shown regardless of color)
# Color cascade (dirty wins, so a dirty+ahead branch reads "(*main^)" in red):
#   210 dirty / 220 ahead-of-remote (clean) / 218 main|master / 2 other.
#
# POSIX/bash/zsh portable: [ ] tests, no [[ ]], no arrays, no zsh-only syntax.

# _git_prompt_state [dir]
#   dir defaults to the current directory.
# On success returns 0 and sets these globals; on no-repo/no-branch returns 1
# with all four cleared:
#   GIT_PS_BRANCH  branch name (empty if detached/not a repo)
#   GIT_PS_DIRTY   "*" if the tree differs from HEAD, else ""
#   GIT_PS_AHEAD   "^" if ahead of upstream, else ""
#   GIT_PS_COLOR   256-color code per the cascade above
_git_prompt_state() {
  GIT_PS_BRANCH=""; GIT_PS_DIRTY=""; GIT_PS_AHEAD=""; GIT_PS_COLOR=""
  local dir="${1:-.}"

  # GIT_OPTIONAL_LOCKS=0 on every call: these run at prompt-render / ~1Hz, and a
  # plain status/diff opportunistically refreshes the index, grabbing index.lock
  # and racing a concurrent git add/commit/rebase. Set inline (not exported) so
  # the interactive shell's own git invocations keep default locking behavior.
  GIT_PS_BRANCH=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || return 1

  # One `status --porcelain` catches staged + unstaged + untracked; the shell
  # prompt's old diff/ls-files pair missed staged-only changes.
  [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" status --porcelain 2>/dev/null)" ] && GIT_PS_DIRTY="*"

  local ahead_count
  ahead_count=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null)
  [ -n "$ahead_count" ] && [ "$ahead_count" -gt 0 ] && GIT_PS_AHEAD="^"

  if [ -n "$GIT_PS_DIRTY" ]; then
    GIT_PS_COLOR="210"
  elif [ -n "$GIT_PS_AHEAD" ]; then
    GIT_PS_COLOR="220"
  elif [ "$GIT_PS_BRANCH" = "main" ] || [ "$GIT_PS_BRANCH" = "master" ]; then
    GIT_PS_COLOR="218"
  else
    GIT_PS_COLOR="2"
  fi
  return 0
}
