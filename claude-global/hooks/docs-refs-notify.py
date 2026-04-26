#!/usr/bin/env python3
"""
PostToolUse hook for Edit|Write|MultiEdit. Reads the tool-call payload from
stdin, asks docs-refs.py which markdown docs reference the touched file, and
(if any are stale) emits a `hookSpecificOutput.additionalContext` message
nudging the agent to consider updating them — or delegating the assessment
to a haiku subagent.

Filters applied before notifying:
  - mtime gate: skip docs whose mtime is >= the touched file's mtime (the
    doc was already updated at/after the change, so it's not out of date).
  - session dedupe: skip (doc, file, doc_mtime) tuples we've already raised
    in this session, so repeated edits to the same file don't re-nag while
    the doc remains untouched. The doc_mtime is part of the key so that if
    the agent *does* update the doc and the file changes again, we'll
    re-notify on the next edit.

Wired up via the PostToolUse Edit|Write|MultiEdit matcher in
claude-global/settings.json.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCANNER = Path(__file__).parent / "docs-refs.py"


def emit_context(message: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": message,
            }
        },
        sys.stdout,
    )
    sys.stdout.write("\n")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path")
    if not file_path:
        return 0

    cwd = payload.get("cwd") or os.getcwd()
    session_id = payload.get("session_id") or "no-session"

    abs_file = Path(file_path)
    if not abs_file.is_absolute():
        abs_file = Path(cwd) / abs_file
    try:
        abs_file = abs_file.resolve()
    except OSError:
        pass
    if not abs_file.exists():
        return 0

    try:
        proc = subprocess.run(
            ["python3", str(SCANNER), "for-file", str(abs_file), "--quiet"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.SubprocessError, OSError):
        return 0
    if proc.returncode != 0:
        return 0

    docs = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if not docs:
        return 0

    try:
        file_mtime = abs_file.stat().st_mtime
    except OSError:
        return 0

    state_file = Path(tempfile.gettempdir()) / f"claude-docs-refs-{session_id}.notified"
    seen: set[str] = set()
    if state_file.exists():
        try:
            seen = set(state_file.read_text().splitlines())
        except OSError:
            seen = set()

    actionable: list[str] = []
    new_keys: list[str] = []
    for doc in docs:
        doc_path = Path(doc)
        try:
            doc_mtime = doc_path.stat().st_mtime
        except OSError:
            continue
        if doc_mtime >= file_mtime:
            continue
        key = f"{doc}|{abs_file}|{doc_mtime}"
        if key in seen:
            continue
        actionable.append(doc)
        new_keys.append(key)

    if not actionable:
        return 0

    try:
        with state_file.open("a") as f:
            for key in new_keys:
                f.write(key + "\n")
    except OSError:
        pass

    bullets = "\n".join(f"  - {d}" for d in actionable)
    message = (
        f"[docs-refs] You modified {abs_file}.\n"
        f"The following docs reference this path and may be out of date:\n"
        f"{bullets}\n"
        f"If the change might affect documentation accuracy, consider delegating "
        f'the assessment to a haiku subagent (Agent tool with model="haiku") '
        f"to identify what needs updating."
    )
    emit_context(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
