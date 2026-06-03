#!/usr/bin/env python3
"""Stop hook: warn when the turn's final reply overflows the terminal-fit budget.

The UserPromptSubmit counterpart (user-prompt-terminal-size.sh) tells the agent,
before the turn, how many rendered lines its reply should fit in. This hook is
the post-turn check: it reads what the agent actually wrote, estimates its
rendered line count, and — if it overflows — blocks the stop ONCE with a reason
fed back to the model, so the model either condenses the reply or, when a longer
answer was genuinely warranted, acknowledges the overage and states the amount.

Single-shot by design: if stop_hook_active is set (we already blocked once this
turn), we never block again — the model gets exactly one nudge, no loops.

Both this hook and the pre-turn hint pull their numbers from term-fit-budget.sh,
so the budget the agent is told and the budget it's checked against can't drift.

No-ops silently (exit 0, no output) when: not in tmux (helper prints nothing),
the transcript can't be read, or the reply fits. A Stop hook only reaches the
model via {"decision":"block","reason":...}; plain stdout would go nowhere, so a
fit / non-measurable turn must stay completely quiet.
"""

import json
import math
import os
import subprocess
import sys


def load_budget():
    """Run the shared helper; return (avail_lines, usable_cols, cols, rows) or None."""
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "term-fit-budget.sh")
    try:
        out = subprocess.run(
            ["sh", helper], capture_output=True, text=True, timeout=5
        ).stdout.split()
    except Exception:
        return None
    if len(out) < 5:
        return None
    try:
        cols, rows, avail_lines, _max_words, usable_cols = (int(x) for x in out[:5])
    except ValueError:
        return None
    return avail_lines, usable_cols, cols, rows


def last_reply_text(transcript_path):
    """Concatenated text blocks of the final assistant message in the transcript.

    A turn can have several assistant events (text interleaved with tool_use);
    the user-facing reply is the text of the LAST assistant message, so we scan
    from the end for the first assistant entry that carries any text block.
    """
    try:
        with open(transcript_path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None
    for raw in reversed(lines):
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if entry.get("type") != "assistant":
            continue
        content = entry.get("message", {}).get("content", [])
        if isinstance(content, str):
            return content
        texts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        if any(t.strip() for t in texts):
            return "\n".join(texts)
    return None


def rendered_lines(text, usable_cols):
    """Estimate rendered terminal rows, counting blank lines and soft-wrapping.

    Mirrors the budget's "rendered lines" notion: each source line costs at
    least one row (blank lines included, as markdown keeps paragraph spacing),
    and long lines cost extra rows for every soft wrap at the usable width.
    An approximation — good enough to flag a real overflow, not to be exact.
    """
    total = 0
    for line in text.split("\n"):
        width = len(line.rstrip())
        total += max(1, math.ceil(width / usable_cols)) if width else 1
    return total


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    # Already blocked once this turn — let the model stop, no second nudge.
    if payload.get("stop_hook_active"):
        return

    budget = load_budget()
    if budget is None:
        return
    avail_lines, usable_cols, cols, rows = budget

    transcript = payload.get("transcript_path")
    if not transcript:
        return
    text = last_reply_text(transcript)
    if not text or not text.strip():
        return

    used = rendered_lines(text, usable_cols)
    if used <= avail_lines:
        return

    reason = (
        f"Your final reply was ~{used} rendered lines, over the terminal-fit "
        f"budget of {avail_lines} lines for this {cols}x{rows} window. Condense "
        f"it to fit the visible window without scrolling — trim anything that "
        f"doesn't earn its row, tighten formatting, drop redundant preamble. "
        f"If a longer reply was genuinely warranted (the user asked for depth, "
        f"or the task truly needs it), keep it but briefly acknowledge the "
        f"overage and state by how much (~{used} vs {avail_lines} lines)."
    )
    print(json.dumps({"decision": "block", "reason": reason}))


if __name__ == "__main__":
    main()
