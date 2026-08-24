#!/bin/sh
# UserPromptSubmit: one-line, every-turn reminder of the reply conventions in
# claude-global/CLAUDE.md, so the rule sits near the point of generation rather
# than only at the top of a long context, where CLAUDE.md content sinks and
# compliance decays. CLAUDE.md carries the full spec with the worked example;
# this prints only the compact form, worded to stand alone after context
# compaction.
#
# Deliberately its own hook rather than a line in user-prompt-terminal-size.sh:
# that hook measures via tmux and exits early outside it, while these
# conventions apply everywhere. Reads nothing from the payload (no session
# state, no dedupe) — repetition is the point.
#
# stdout from a UserPromptSubmit hook is injected into the model's context, so
# the line below becomes guidance the assistant sees.

cat >/dev/null  # drain the JSON payload; unused
printf '%s\n' "reply conventions: label every item that awaits the user's answer (decision, question, choice) as (N) leading the line in place of a bullet — numbered sequentially across the whole reply so each label is unique in the message, restarting at (1) each reply; a lone item is still (1); echo the label when acting on an answer."
exit 0
