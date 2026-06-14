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
      # Fields 5-7 (added later) carry block-element counts for a contextual tip;
      # absent in legacy markers, so default to 0 and degrade to the plain warning.
      tables=${5:-0}; table_extra=${6:-0}; code=${7:-0}
      printf 'term-fit warning: your previous reply ran ~%s rendered lines vs the ' "$1"
      printf '%s-line budget (%sx%s) — over by ~%s. ' "$2" "$3" "$4" "$over"
      # Tip: if a table accounted for most of the overrun, name it — grid tables
      # render ~2 lines per row (a rule between every row), the top overflow cause.
      if [ "$tables" -ge 1 ] && [ "$table_extra" -ge "$over" ]; then
        printf 'A markdown table likely drove this: %s table line(s) came from grid ' "$table_extra"
        printf 'rendering (a rule between every row) — a compact bullet list or fewer '
        printf 'columns would reclaim most of those rows. '
      elif [ "$tables" -ge 1 ]; then
        printf '(Note: %s of those lines came from grid-table rendering.) ' "$table_extra"
      fi
      printf 'Read-only heads-up: aim to fit the window, but ignore this if that turn '
      printf 'genuinely warranted the length (e.g. the user asked for depth or the task '
      printf 'needed it).\n'
    fi
  fi
fi

# Measure + compute the budget via the shared helper (single source of truth).
# Prints nothing when not measurable (no tmux); bail in that case.
set -- $(sh "$(dirname "$0")/term-fit-budget.sh")
[ "$#" -ge 6 ] || exit 0
cols=$1
rows=$2
avail_lines=$3
max_words=$4
target=$6  # field 5 is usable_cols (unused here); field 6 is the soft target

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
  printf 'term-fit: %sx%s -> aim <=%s rendered lines (%s hard ceiling, ~%s words); ' \
    "$cols" "$rows" "$target" "$avail_lines" "$max_words"
  printf 'rendered lines (incl. blank lines between paragraphs/list items) is the primary limit; '
  printf 'the ceiling is hard unless the user asked for depth.\n'
}

if [ "$full" -eq 1 ]; then
  printf 'Terminal-fit hint (via tmux): each turn reports the current pane size '
  printf 'and a budget for the final end-of-turn reply, so it fits in the visible '
  printf 'window without scrolling.\n'
  printf 'Terminal window: %sx%s (cols x rows). Aim for %s RENDERED lines or fewer ' "$cols" "$rows" "$target"
  printf 'in the final reply; %s lines is the hard ceiling — do not exceed it. ' "$avail_lines"
  printf '"Rendered" counts the blank lines markdown inserts between paragraphs and '
  printf 'list items, not just lines of text, so airy formatting spends rows fast — '
  printf 'aim a few lines under the ceiling rather than filling to it. Secondary '
  printf 'check: ~%s words at this width. This applies to the final reply only, not ' "$max_words"
  printf 'tool output or intermediate steps. Treat the ceiling as hard for ordinary '
  printf 'replies; exceed it only when the user explicitly asked for depth or length.\n'
  printf 'Note how block elements render vs their source: a markdown TABLE paints '
  printf '~2 rows per data row (a separator rule between every row, plus borders), '
  printf 'so it is taller than it looks in source; a fenced CODE block renders '
  printf 'slightly shorter (the ``` fences are stripped). Budget tables especially '
  printf 'carefully — they are the most common cause of a reply overflowing.\n'
  printf 'Later turns report this compactly as: '
  compact
else
  compact
fi
