#!/bin/sh
# UserPromptSubmit: report the current terminal size (measured via tmux) and a
# recommended budget for the assistant's end-of-turn message, so the final
# user-facing reply fits within the visible terminal window without scrolling.
#
# The governing constraint is RENDERED LINES — counting the blank lines that
# markdown puts between paragraphs and list items, not just lines that hold
# text. A reply can sit at its word budget and still overflow because airy
# formatting spends rows on whitespace, so lines lead and words are a softer
# secondary sanity check (scaled by a fill factor, below).
#
# Verbosity: the first prompt of a session gets a full message that explains
# what the hint is and how to read the compact form; every prompt after that
# gets the compact one-liner (still self-describing enough to survive context
# compaction losing the preamble). "First" is tracked per session via a marker
# file in $TMPDIR keyed on session_id; if session_id can't be parsed we fall
# back to the compact form rather than re-explaining every turn.
#
# stdout from a UserPromptSubmit hook is injected into the model's context for
# the turn, so everything echoed below becomes guidance the assistant sees.
#
# Only fires inside tmux (that's how we measure). When Claude is run outside
# tmux, the shared budget helper prints nothing and we no-op silently rather
# than guess at a size. The post-turn counterpart is stop-terminal-size.py,
# which warns when the reply actually written overflows this same budget; both
# get their numbers from term-fit-budget.sh so the hint and the check agree.
# See that helper for the tunable env vars (reserved rows, gutter, etc.).

# Read session_id from the JSON payload on stdin (no jq, for portability).
# Each UserPromptSubmit hook gets its own copy of the payload.
sid=$(grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
# Keep only filename-safe characters.
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')

# Read-only overflow heads-up from last turn. The Stop hook (stop-terminal-size.py)
# drops a marker with "used avail cols rows" when the previous reply overran the
# budget; surface it once here (UserPromptSubmit stdout is injected as context the
# agent can read and freely ignore), then consume it. Printed before the budget
# bail and self-contained from the stored numbers, so it shows even if this turn
# can't measure (e.g. not in tmux now). Stays silent when there's no overflow.
if [ -n "$sid" ]; then
  warn="${TMPDIR:-/tmp}/claude-term-fit-overflow-${sid}.warn"
  if [ -f "$warn" ]; then
    set -- $(cat "$warn" 2>/dev/null)
    rm -f "$warn" 2>/dev/null || true
    if [ "$#" -ge 4 ]; then
      over=$(( $1 - $2 ))
      printf 'term-fit warning: your previous reply ran ~%s rendered lines vs the ' "$1"
      printf '%s-line budget (%sx%s) — over by ~%s. Read-only heads-up: aim to fit ' "$2" "$3" "$4" "$over"
      printf 'the window, but ignore this if that turn genuinely warranted the length '
      printf '(e.g. the user asked for depth or the task needed it).\n'
    fi
  fi
fi

# Measure + compute the budget via the shared helper (single source of truth).
# Prints nothing when not measurable (no tmux); bail in that case.
set -- $(sh "$(dirname "$0")/term-fit-budget.sh")
[ "$#" -ge 4 ] || exit 0
cols=$1
rows=$2
avail_lines=$3
max_words=$4

# Decide full vs compact. First prompt of a session (no marker yet) → full.
full=1
if [ -n "$sid" ]; then
  marker="${TMPDIR:-/tmp}/claude-term-fit-${sid}.seen"
  if [ -f "$marker" ]; then
    full=0
  else
    : > "$marker" 2>/dev/null || true
  fi
else
  # No session_id to dedupe on — don't re-explain every turn.
  full=0
fi

# Compact form, repeated each turn. Self-describing so it still reads correctly
# if the full preamble is lost to compaction.
compact() {
  printf 'term-fit: %sx%s -> final reply <=%s rendered lines (~%s words); ' \
    "$cols" "$rows" "$avail_lines" "$max_words"
  printf 'rendered lines (incl. blank lines between paragraphs/list items) is the primary limit.\n'
}

if [ "$full" -eq 1 ]; then
  printf 'Terminal-fit hint (via tmux): each turn reports the current pane size '
  printf 'and a budget for the final end-of-turn reply, so it fits in the visible '
  printf 'window without scrolling.\n'
  printf 'Terminal window: %sx%s (cols x rows). Keep the final reply within ' "$cols" "$rows"
  printf '~%s RENDERED lines — the primary constraint, counting the blank lines ' "$avail_lines"
  printf 'markdown inserts between paragraphs and list items, not just lines of '
  printf 'text. Secondary check: ~%s words at this width. Applies to the final ' "$max_words"
  printf 'reply only, not tool output or intermediate steps; exceeding it is fine '
  printf 'when the task genuinely needs more, but prefer concision, dense '
  printf 'formatting, and trimming anything that does not earn its row.\n'
  printf 'Later turns report this compactly as: '
  compact
else
  compact
fi
