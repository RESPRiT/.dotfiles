#!/bin/sh
# Shared terminal-fit budget calculator. Measures the pane Claude renders into
# (via tmux) and derives the end-of-turn reply budget. Printed on one line so
# both the UserPromptSubmit hint (user-prompt-terminal-size.sh) and the Stop
# warning (stop-terminal-size.py) consume the SAME numbers — single source of
# truth, no drift between the pre-turn hint and the post-turn check.
#
# Output (stdout, space-separated): cols rows avail_lines max_words usable_cols
# Prints nothing and exits 0 when not measurable (no tmux / non-numeric dims),
# so callers can `set -- $(...)` and bail when fewer than 5 fields come back.
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

printf '%s %s %s %s %s\n' "$cols" "$rows" "$avail_lines" "$max_words" "$usable_cols"
