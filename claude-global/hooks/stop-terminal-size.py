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

The line estimate is block-aware (see analyze()): markdown grid tables render
TALLER than their source (a rule between every row) and fenced code blocks
render SHORTER (fences stripped) — measured against Claude Code's TUI renderer.
The marker carries those block counts so the next turn's heads-up can name the
likely culprit (e.g. "a table drove most of the overflow").

Every measured reply (fit or overflow) also appends a sizes/counts-only record
to .state/term-fit.log (never the reply text; rotated at 1MB), so the estimator
can be calibrated against real turns instead of hand-reconstructed cases.

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


def log_path():
    """`.state/term-fit.log` at the dotfiles repo root (hooks live two dirs in)."""
    here = os.path.dirname(os.path.abspath(__file__))      # claude-global/hooks
    repo = os.path.dirname(os.path.dirname(here))          # repo root
    return os.path.join(repo, ".state", "term-fit.log")


def append_log(line):
    """Append one calibration record, rotating at 1MB like the other .state logs."""
    path = log_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path) and os.path.getsize(path) > 1_000_000:
            os.replace(path, path + ".1")
        with open(path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def debug_log(fields):
    """Append one greppable line per Stop, gated behind CLAUDE_TERM_FIT_DEBUG.

    Off by default (no env var → no-op, zero cost on the hot path). When set to
    a truthy value, records every Stop's branch and the flush-poll outcome so we
    can see whether real overflows are being measured or silently swallowed
    (e.g. a flush-race bail to used=0 on a long reply). Best-effort: never raises
    into the hook.

    Distinct from append_log(): that records sizes/counts for *measured* replies
    to calibrate the estimator; this records the *control-flow branch* (incl. the
    bail paths that never measure a reply) to debug the flush race itself.

    Logs to the dotfiles repo's gitignored `.state/term-fit-debug.log` — a
    stable, per-machine path. Deliberately NOT $TMPDIR: hooks and the agent's
    Bash tool run with *different* TMPDIRs, so a $TMPDIR-relative log is written
    in one place and read from another. The hook is symlinked into
    ~/.claude/hooks, so realpath() resolves back to the real file in the repo
    before walking up to the repo root.
    """
    if os.environ.get("CLAUDE_TERM_FIT_DEBUG", "").lower() not in ("1", "true", "yes", "on"):
        return
    ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime())
    line = ts + " " + " ".join(f"{k}={v}" for k, v in fields.items())
    here = os.path.dirname(os.path.realpath(__file__))  # …/claude-global/hooks
    state = os.path.normpath(os.path.join(here, "..", "..", ".state"))
    try:
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "term-fit-debug.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


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

    Returns (reply_or_None, diag) where diag records how the poll resolved —
    waited seconds, whether it hit the deadline, and the end-state of the last
    entry — so the diagnostic log can tell a flush-race bail (timed out with the
    final text not yet flushed) apart from a legitimate tool-call ending.
    """
    waited = 0.0
    text, has_tool = last_assistant_entry(transcript_path)
    while (not text or has_tool) and waited < max_wait:
        time.sleep(step)
        waited += step
        text, has_tool = last_assistant_entry(transcript_path)
    reply = text if not has_tool else None
    diag = {
        "waited": round(waited, 2),
        "timed_out": waited >= max_wait,
        "has_tool_at_end": bool(has_tool),
        "had_text_at_end": bool(text),
    }
    return reply, diag


def _is_table_sep(line):
    """True for a markdown table separator row like `|---|:--:|` or `--- | ---`."""
    s = line.strip()
    if "-" not in s or "|" not in s:
        return False
    return all(c in "|-: " for c in s)


def analyze(text, usable_cols):
    """Estimate rendered terminal rows and note the block elements that drive it.

    Returns (total_rows, info) where info counts the elements whose RENDERED
    height diverges from their source line count — measured empirically against
    Claude Code's TUI markdown renderer (see docs/HOOKS.md):

      * Grid tables render a separator rule between every row plus top/bottom
        borders: an N-source-line table (header + `|---|` spec + N-2 data rows)
        paints 2N-1 rows. So a table is UNDER-counted by N-1 if treated 1:1 —
        the dominant overflow source we observed.
      * Fenced code blocks render with the ``` / ~~~ fence lines STRIPPED, so a
        block is slightly OVER-counted (by its two fences) if treated 1:1.

    Everything else costs ≥1 row per source line (blank lines included, as
    markdown keeps paragraph spacing) plus a row per soft wrap at usable_cols.
    An approximation — good enough to flag a real overflow, not to be exact.
    """
    def wrap(line):
        width = len(line.rstrip())
        return max(1, math.ceil(width / usable_cols)) if width else 1

    lines = text.split("\n")
    n = len(lines)
    total = 0
    info = {"tables": 0, "table_extra": 0, "code_blocks": 0}
    in_code = False
    i = 0
    while i < n:
        line = lines[i]
        stripped = line.strip()
        # Fenced code block: the fence lines render to nothing; content renders 1:1.
        if stripped.startswith("```") or stripped.startswith("~~~"):
            if not in_code:
                in_code = True
                info["code_blocks"] += 1
            else:
                in_code = False
            i += 1
            continue
        if in_code:
            total += wrap(line)
            i += 1
            continue
        # Grid table: a row with a pipe whose NEXT line is a separator spec.
        if "|" in line and i + 1 < n and _is_table_sep(lines[i + 1]):
            j = i
            while j < n and "|" in lines[j] and lines[j].strip():
                j += 1
            src = j - i              # source table lines (header + spec + data)
            rendered = 2 * src - 1   # grid expansion: rule between every row + borders
            total += rendered
            info["tables"] += 1
            info["table_extra"] += rendered - src
            i = j
            continue
        total += wrap(line)
        i += 1
    return total, info


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
    if transcript:
        text, flush = final_reply_text(transcript)
    else:
        text, flush = None, {"waited": 0.0, "timed_out": False,
                             "has_tool_at_end": False, "had_text_at_end": False}
    has_reply = bool(text and text.strip())
    if has_reply:
        used, info = analyze(text, usable_cols)
        chars = len(text)
    else:
        used, info, chars = 0, {"tables": 0, "table_extra": 0, "code_blocks": 0}, 0

    overflow = used > avail_lines
    path = marker_path(sid)
    if overflow:
        # Stash the numbers + block-element counts; the next UserPromptSubmit
        # renders a heads-up with contextual tips and consumes the marker.
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    f"{used} {avail_lines} {cols} {rows} "
                    f"{info['tables']} {info['table_extra']} {info['code_blocks']}\n"
                )
        except OSError:
            pass
    else:
        # Reply fit — clear any stale marker from an earlier overflow.
        try:
            os.remove(path)
        except OSError:
            pass

    # Calibration log: one record per measured reply (fit or overflow), so the
    # estimator can be tuned against real data rather than reconstructed cases.
    # Records only sizes/counts — never the reply text. Skips turns with no
    # user-facing reply (tool-end turns), which carry no signal to calibrate on.
    if chars:
        try:
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        except Exception:
            stamp = "?"
        append_log(
            f"{stamp} sid={sid} pane={cols}x{rows} budget={avail_lines} "
            f"est={used} fired={1 if overflow else 0} tables={info['tables']} "
            f"table_extra={info['table_extra']} code={info['code_blocks']} chars={chars}"
        )

    # Diagnostic (gated): which branch did this Stop take, and why? A "bail"
    # means we never measured a reply — the suspected silent-overflow path when
    # a long final reply hasn't flushed by the poll deadline.
    if not transcript:
        branch = "no-transcript"
    elif not has_reply:
        branch = "bail-flush" if flush["timed_out"] else "bail-no-reply"
    else:
        branch = "overflow" if overflow else "fit"
    debug_log({
        "sid": sid, "pane": f"{cols}x{rows}", "budget": avail_lines,
        "usable": usable_cols, "used": used, "branch": branch,
        "reply": "yes" if has_reply else "no",
        "waited": flush["waited"], "timed_out": flush["timed_out"],
        "has_tool": flush["has_tool_at_end"],
    })


if __name__ == "__main__":
    main()
