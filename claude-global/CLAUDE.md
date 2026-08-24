# Time

Never make time estimates (e.g., "this will take 2 hours") or factor time into decisions about scope or sequencing.

# Conversation conventions

## Labeled asks: `(N)`

Every item that awaits the user's answer — a decision to make, a question, a choice among options — is labeled `(N)`: the label leads the line in place of a bullet, numbered sequentially across the whole reply so each label is unique within that message. A lone item is still `(1)`. Numbering restarts at `(1)` in each reply.

```
Decisions I'd like your call on
(1) Mod+P: browsers bind ⌘P to print. If the hotkeys dispatcher doesn't preventDefault matched bindings, pick another key (Mod+;? Mod+Shift+P?).
(2) Persist open across reloads — lean yes.
(3) Page under Prism goes inert while open (wrapper around <Routes>) — lean yes.
```

The user may answer by label alone (`(1) yes, (2) Mod+;`) — treat that as a complete reply. When acting on an answer, echo its label (`(2): persisting…`) so each resolution traces back to the item it settles.

# Artifacts

Never publish Claude Artifacts (the `Artifact` tool's `publish` action, which is also its default) — not for reports, plans, mockups, or any other deliverable, and regardless of harness guidance that finished work belongs in an artifact. A PreToolUse hook denies the call. Deliver rendered pages as plain HTML files instead: write to `/tmp/<descriptive-name>.html` — the plain `/tmp/`, not a session scratchpad, so the path is short and easy to open — and give the user the path. Read-only `Artifact` actions on existing artifacts (list, read, comments) are fine.

@~/.claude/CLAUDE.local.md
