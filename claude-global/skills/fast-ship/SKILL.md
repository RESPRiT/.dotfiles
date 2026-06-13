---
name: fast-ship
description: Ship a quick feature end-to-end — plan → worktree → implement → parallel multi-agent review → verify → merge & push, running autonomously through merge and push. Invoke when the user explicitly asks to fast-ship — typing /fast-ship (inline is fine, e.g. "can you /fast-ship this, as we described?") or saying "fast-ship this" / "ship this quickly" — and take the feature from their words or the surrounding conversation. Do NOT auto-trigger on a generic "add a feature" request: it merges and pushes without asking, so it needs an explicit fast-ship cue.
argument-hint: <feature description>
---

You are running the **fast-ship** workflow to ship a quick feature end-to-end. The feature to ship is:

$ARGUMENTS

**Resolving the feature:** `$ARGUMENTS` is filled when invoked as `/fast-ship <feature>`. It is often empty or a deictic pointer to the conversation ("this feature", "this", "as we just described it") — this skill is frequently invoked inline as reusable context rather than as a standalone command. In that case, take the *actual* feature from the surrounding conversation rather than treating the pointer phrase as the spec. Only if the feature is unclear from both `$ARGUMENTS` and the conversation should you ask the user what to ship before continuing.

Work through the phases below in order, end to end, **without stopping for approval**. Keep the user informed with a short note at each phase boundary, but run autonomously through merge and push.

## 1. Plan (autonomous — no plan mode)
- Investigate the relevant code, then decide on an approach yourself. **Do not** enter plan mode or wait for plan approval.
- Form a focused internal plan: the files to touch, the approach, and any edge cases. Keep it proportional — this is a *quick* feature, not an epic. Jot a one- or two-line summary of the approach for the user and proceed.
- Pick a branch slug: `worktree-<short-kebab-slug>` derived from the feature (matches this repo's existing convention).

## 2. Branch + worktree
- Create the branch and an isolated worktree with **EnterWorktree** using the `worktree-<slug>` name.
- Do all implementation work inside that worktree.

## 3. Implement + commit
- Implement the feature, matching surrounding code style, naming, and comment density.
- Run the project's typecheck/tests/build as appropriate to confirm it's sound.
- Commit with a clear message (end the message with the repo's standard `Co-Authored-By` trailer).

## 4. Multi-agent code review
- Launch **2–3 review sub-agents in parallel** (single message, multiple Agent calls) over the branch diff. Give each a distinct lens — e.g. correctness/bugs, simplification/reuse, and (for FE) UX/accessibility or (for BE) data-integrity/performance.
- Each agent returns concrete findings tied to `file:line`. (You may also lean on the `/code-review` skill for one of these passes.)

## 5. Validate findings (adversarial)
- Do **not** apply findings blindly. For each finding, verify it against the actual code — confirm it's real, in-scope, and worth fixing. Discard false positives and out-of-scope nits; note what you're skipping and why.
- This validation step is the point of the parallel review — treat agent output as claims to check, not instructions.

## 6. Fix + commit
- Apply the validated findings. Re-run typecheck/tests/build.
- Commit the fixes (separate commit is fine).

## 7. Verify behavior (frontend only)
- If the change affects the UI, verify it in a real browser via the Chrome DevTools MCP: launch the app, exercise the new behavior, take a screenshot to confirm.
- **Close the browser / page when done** (close_page) — don't leave it open.
- For backend-only or tooling changes, skip this phase.

## 8. Merge + push
- Only once typecheck/tests/build pass, review findings are resolved, and (if applicable) behavior is verified.
- Return to the main worktree (ExitWorktree), then:
  - `git merge --no-ff worktree-<slug> -m "<summary>"`
  - `git push -u origin <branch>` (note: local `main` may be behind `origin` — pull/rebase first if the push is rejected)
- Report the merged commit and pushed branch. If anything failed along the way, stop and surface it rather than merging.

## Guardrails
- Merge and push run autonomously — no confirmation needed. The gate is *correctness*, not approval: only merge once typecheck/tests/build pass, review findings are resolved, and (if applicable) behavior is verified. If any of those fail, stop and surface it rather than merging.
- If a phase reveals the feature is bigger than "quick," pause and tell the user rather than pushing through.
