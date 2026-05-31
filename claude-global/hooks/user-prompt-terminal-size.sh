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

printf 'Terminal window (via tmux): %sx%s (cols x rows).\n' "$cols" "$rows"
printf 'Keep your final end-of-turn message within ~%s rendered lines so it ' "$avail_lines"
printf 'fits without the user scrolling. Rendered lines is the hard limit: '
printf 'count the blank lines markdown inserts between paragraphs and list '
printf 'items, not just lines of text. As a secondary check, that is roughly '
printf '~%s words at this width. This governs the final reply only, not tool ' "$max_words"
printf 'output or intermediate steps; exceed it when the task genuinely needs '
printf 'more, but prefer concision, dense formatting, and trimming anything '
printf 'that does not earn its row.\n'
