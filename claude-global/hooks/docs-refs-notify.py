#!/usr/bin/env python3
"""
PostToolUse hook for Edit|Write|MultiEdit. Reads the tool-call payload from
stdin and, if other markdown docs `tracks:` the touched file and their mtime
is older than the file's, lists them as a single
`hookSpecificOutput.additionalContext` message so the agent can decide whether
to update them (or delegate to a haiku subagent).

`tracks:` is optional: a doc with no `tracks:` block simply opts out of the
reference system and is never flagged for the omission.

Filters applied before notifying:
  - mtime gate: skip docs whose mtime is >= the touched file's mtime — the doc
    was updated at/after the change, so not stale.
  - session dedupe: a state file at ${TMPDIR}/claude-docs-refs-<sid>.notified
    holds keys we've already raised, as `<doc>|<file>|<doc_mtime>` (re-fires
    when the doc's mtime advances after a presumed fix).

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

    state_file = Path(tempfile.gettempdir()) / f"claude-docs-refs-{session_id}.notified"
    seen: set[str] = set()
    if state_file.exists():
        try:
            seen = set(state_file.read_text().splitlines())
        except OSError:
            seen = set()

    sections: list[str] = []
    new_keys: list[str] = []

    # Other docs that track abs_file and may now be stale.
    try:
        proc = subprocess.run(
            ["python3", str(SCANNER), "for-file", str(abs_file), "--quiet"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5,
        )
        docs = (
            [line.strip() for line in proc.stdout.splitlines() if line.strip()]
            if proc.returncode == 0
            else []
        )
    except (subprocess.SubprocessError, OSError):
        docs = []

    if docs:
        try:
            file_mtime = abs_file.stat().st_mtime
        except OSError:
            file_mtime = None

        if file_mtime is not None:
            actionable: list[str] = []
            for doc in docs:
                try:
                    doc_mtime = Path(doc).stat().st_mtime
                except OSError:
                    continue
                if doc_mtime >= file_mtime:
                    continue
                key = f"{doc}|{abs_file}|{doc_mtime}"
                if key in seen:
                    continue
                actionable.append(doc)
                new_keys.append(key)

            if actionable:
                bullets = "\n".join(f"  - {d}" for d in actionable)
                sections.append(
                    f"[docs-refs] You modified {abs_file}.\n"
                    f"The following docs reference this path and may be out of date:\n"
                    f"{bullets}\n"
                    f"If the change might affect documentation accuracy, consider "
                    f'delegating the assessment to a haiku subagent (Agent tool with '
                    f'model="haiku") to identify what needs updating.'
                )

    if not sections:
        return 0

    try:
        with state_file.open("a") as f:
            for key in new_keys:
                f.write(key + "\n")
    except OSError:
        pass

    emit_context("\n\n".join(sections))
    return 0


if __name__ == "__main__":
    sys.exit(main())
