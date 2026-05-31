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
# tmux, $TMUX is unset and we no-op silently rather than guess at a size.
#
# Tunables (export from the shell or settings env if the defaults feel off):
#   CLAUDE_TERM_FIT_RESERVED_ROWS  rows kept clear for the TUI chrome — input
#                                  box, status line, mode hint, completion stat
#                                  line, surrounding blanks (default 10;
#                                  measured empirically via `tmux capture-pane`)
#   CLAUDE_TERM_FIT_GUTTER_COLS    left-gutter columns the TUI indents content
#                                  by, subtracted from usable width (default 2)
#   CLAUDE_TERM_FIT_CHARS_PER_WORD avg rendered chars per word incl. trailing
#                                  space (default 6)
#   CLAUDE_TERM_FIT_FILL_PCT       % of a line real markdown actually fills,
#                                  after blank/short lines — scales the word
#                                  estimate down from full-packing (default 55)

[ -n "$TMUX" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Read session_id from the JSON payload on stdin (no jq, for portability).
# Each UserPromptSubmit hook gets its own copy of the payload.
sid=$(grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
# Keep only filename-safe characters.
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')

# Measure the pane Claude is rendering into. $TMUX_PANE is exported by tmux for
# the current pane; falls back to the active pane if somehow unset.
dims=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} '#{pane_width} #{pane_height}' 2>/dev/null)
cols=${dims% *}
rows=${dims#* }

# Bail if tmux gave us anything non-numeric.
case "$cols$rows" in
  ''|*[!0-9]*) exit 0 ;;
esac

reserved=${CLAUDE_TERM_FIT_RESERVED_ROWS:-10}
gutter=${CLAUDE_TERM_FIT_GUTTER_COLS:-2}
cpw=${CLAUDE_TERM_FIT_CHARS_PER_WORD:-6}
fill=${CLAUDE_TERM_FIT_FILL_PCT:-55}

avail_lines=$((rows - reserved))
[ "$avail_lines" -lt 1 ] && avail_lines=1

usable_cols=$((cols - gutter))
[ "$usable_cols" -lt 1 ] && usable_cols=1

# Secondary word estimate: words a full line holds, scaled by the fill factor
# so it reflects whitespace-heavy markdown rather than densely packed prose.
words_per_line=$((usable_cols / cpw))
max_words=$((avail_lines * words_per_line * fill / 100))

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
