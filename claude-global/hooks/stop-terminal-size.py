#!/usr/bin/env python3
"""Stop hook: record when the turn's final reply overflowed the terminal-fit budget.

The UserPromptSubmit counterpart (user-prompt-terminal-size.sh) tells the agent,
before the turn, how many rendered lines its reply should fit in. This hook is
the post-turn check: it reads what the agent actually wrote, estimates its
rendered line count, and — if it overflowed — drops a small marker file. The
NEXT UserPromptSubmit reads that marker and surfaces a one-line, read-only
heads-up in the turn's context, then deletes it (consume-once).

Why a marker instead of acting now: a Stop hook can only reach the model via
{"decision":"block",...}, which forces a revision and appends MORE text below an
already-painted reply (it can't retract what's on screen). The goal here is a
read-only nudge, not a forced rewrite — so we defer the message to the next
turn's UserPromptSubmit, whose stdout is injected as plain context the agent can
read and freely ignore (e.g. when a long reply was genuinely warranted).

Both this hook and the pre-turn hint pull their budget from term-fit-budget.sh,
so the number the agent is told and the number it's checked against can't drift.

Silent no-op (and clears any stale marker) when the reply fits. No-op when not
in tmux (helper prints nothing), the transcript can't be read, or there's no
session_id to key the marker on.
"""

import json
import math
import os
import subprocess
import sys
import time


def marker_path(sid):
    tmp = os.environ.get("TMPDIR", "/tmp")
    return os.path.join(tmp, f"claude-term-fit-overflow-{sid}.warn")


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


def last_assistant_entry(transcript_path):
    """Return (text, has_tool_use) for the final assistant entry in the transcript.

    `text` is the concatenated text blocks (None if the entry carries no text);
    `has_tool_use` is True when that entry also contains a tool_use block, which
    means the turn isn't finished — more is coming after the pending tool result.
    Returns (None, False) if the transcript is unreadable or has no assistant yet.
    """
    try:
        with open(transcript_path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None, False
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
            return content, False
        texts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        has_tool = any(
            isinstance(b, dict) and b.get("type") == "tool_use" for b in content
        )
        text = "\n".join(texts) if any(t.strip() for t in texts) else None
        return text, has_tool
    return None, False


def final_reply_text(transcript_path, max_wait=2.0, step=0.05):
    """Text of the turn's final user-facing reply, waiting out the flush race.

    A Stop hook can fire before the turn's last assistant message is flushed to
    the transcript — at that instant the last entry is still the pre-tool-call
    text (which carries a tool_use block), so naively reading "the last text"
    measures the wrong, earlier message. We poll until the last assistant entry
    is text-bearing AND free of tool_use (i.e. a terminal reply), or until the
    deadline. Turns that legitimately end on a tool call never satisfy that and
    fall through to best-effort at timeout (those have no reply to measure).
    """
    waited = 0.0
    text, has_tool = last_assistant_entry(transcript_path)
    while (not text or has_tool) and waited < max_wait:
        time.sleep(step)
        waited += step
        text, has_tool = last_assistant_entry(transcript_path)
    return text if not has_tool else None


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

    sid = "".join(c for c in str(payload.get("session_id", "")) if c.isalnum() or c in "._-")
    if not sid:
        return  # no key to hang the marker on; can't hand off to next turn

    budget = load_budget()
    if budget is None:
        return
    avail_lines, usable_cols, cols, rows = budget

    transcript = payload.get("transcript_path")
    text = final_reply_text(transcript) if transcript else None
    used = rendered_lines(text, usable_cols) if text and text.strip() else 0

    path = marker_path(sid)
    if used > avail_lines:
        # Stash the numbers; the next UserPromptSubmit renders + consumes them.
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(f"{used} {avail_lines} {cols} {rows}\n")
        except OSError:
            pass
    else:
        # Reply fit — clear any stale marker from an earlier overflow.
        try:
            os.remove(path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
