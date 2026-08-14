---
name: user-test
description: Design and run a sub-agent user test of an API, CLI, library, or pattern — a conditions × degrees matrix of naive consumer agents whose transcripts reveal ergonomic differences at a glance. Invoke when the user types /user-test or asks to "user test" / "run a user test on" something. The goal is directional signal to inform next steps, not statistical significance.
argument-hint: [what to test and/or the direction question]
---

You are running a **user test**: naive sub-agents act as real consumers of an artifact (API, CLI, library, directory structure, docs, workflow pattern), and their behavior — not their opinions — reveals how the design holds up. The subject of the test is:

$ARGUMENTS

**Purpose calibration.** A user test informs *direction*, not publication. Prefer noisy-but-fast designs whose effects are readable at a glance over ceremony that chases significance. The design failure modes to actively avoid: testing the wrong thing, conditions with no behavioral contrast, unrealistic tasks, and priming (leaking the hypothesis or design rationale into subject prompts).

## 1. Gather — infer first, ask second

Three pieces of information are required before planning. Pull each from context when you can; `$ARGUMENTS` is often empty or deictic ("this", "the API we just built"), and the artifact is frequently whatever immediately precedes the invocation in the conversation.

1. **Artifact under test** — the thing consumers will touch (path, branch, docs, CLI).
2. **Direction question** — the one-sentence question the result should inform ("should the CLI favor flags or subcommands?", "is this library ready for agent consumers?").
3. **Conditions axis** — the alternatives being compared. A single-design usability probe has no axis; the matrix collapses to 1 × degrees.

Do not front-load an interview. Ask only for pieces you genuinely cannot infer, batched into the single plan confirmation below (AskUserQuestion, one call). Everything else — degrees, tasks, fixtures, measures, N, model — you decide and present as defaults.

## 2. Plan — one confirmation touchpoint

Design the matrix, then show the user a half-screen plan and get one confirm before running.

**Matrix = conditions × degrees.** Degrees are graded escalations of *the specific thing the conditions differ on* — never generic difficulty. (Pagination API: trivial single fetch → filtered multi-page walk → resumable cursor across restarts. A generic "big refactor" adds variance without adding contrast.) The design is read as a dose-response curve: a monotonic gap that widens with degree is a real effect at N=1 per cell; a scrambled pattern means noise or a confound — either way, glanceable.

- **Degree 1 is the manipulation check**: every condition should pass it easily. A degree-1 failure is a broken fixture or task, not a finding.
- **Defaults**: 3 degrees; N=1 per cell, N=2 at the highest degree (where variance is largest). A 3×3 is ~9–12 agents.
- **Model**: a fixed instrument matched to the expected real consumer; when unknown, default one tier below frontier — weaker models are more sensitive to ergonomic warts, frontier models paper over them. **Variant**: when the question is "how far down the capability curve does the design hold up," use model-tier as the second axis instead of degrees.
- **Measures**: declare them in the plan, behavioral only, readable from transcripts — task completion, API misuse count, retries/dead ends, hallucinated surface (flags, endpoints, methods that don't exist), doc lookups. Never self-report ("did you find this API pleasant?" is worthless).
- **Predicted divergence**: one line per condition pair — what behavior you expect to differ. If you can't predict a divergence, the tasks lack contrast; redesign before running.

The plan shown to the user: the matrix grid, the concrete task per degree, model, N, measures, predicted divergence — plus any gap questions from step 1. One confirm, then run without further check-ins.

## 3. Fixtures — researcher side and subject side are separate

**The subject's working directory is visible to it in every tool call, so no path it touches may contain the words "user test", a condition label, or a degree number.** Keep the two sides apart:

*Researcher side* — lives at `user-test/<name>/` in the target repo, and **no subject ever sees this path**. It is scratch material, not product: add **`/user-test/`** to `.git/info/exclude` (never commit it, and don't touch the repo's `.gitignore`). Anchor it with the leading slash — an unanchored `user-test/` matches a directory of that name at *any* depth and will silently hide unrelated files, including the skill's own source directory.

```
user-test/<name>/
  plan.md              # the confirmed plan
  conditions/a/ b/ c/  # neutral labels — never new-api/ vs legacy/
  cells.md             # cell → sandbox path map: your key back to the runs
  results.md           # filled matrix + direction recommendation
```

*Subject side* — one sandbox per cell, **outside the target repo** and inside its own dedicated root that contains nothing else:

```
<sandboxes>/<opaque>/<task-slug>/     # e.g. /tmp/9f3a1c/orders-api/
```

The slug describes the *work*, never the condition or degree. **Put the uniqueness in the parent, not the project name**: a project directory carrying a hex suffix (`orders-api-3f9a`) reads as generated scratch space on its own — subjects have said so. The leaf should look like a project someone named. Record which cell is which in `cells.md`, never in the path.

**A subject can read upward.** Everything in every ancestor directory is one `ls ..` away, so the sandbox's whole parent chain is part of the fixture:

- **Never put a sandbox under your own working directory.** The session scratchpad is where your build scripts, logs, and debris live — including leftovers from unrelated earlier work that read exactly like answer keys. A sandbox nested under it hands subjects the experiment.
- **Never write build output to a subject-reachable path.** Redirecting a build script's stdout to a log is enough to republish `cells.md` inside the sandbox tree.
- **Give every cell its own parent.** N sibling directories with the same slug and identical creation times reveal the matrix by themselves, even with zero researcher files present.

Verify by listing every ancestor of a sandbox up to the filesystem root and confirming nothing there belongs to the experiment.

Building a sandbox: copy the **contents** of the condition dir into it, so the `a/`/`b/`/`c/` name never travels. A condition dir holds **only what a real consumer would see** — README/docs/`--help` output, the installable artifact, a realistic starting project state. No design notes, no rationale, no plan.

**No-tell checklist** — apply to every cell before running:
- **Path**: nothing in the subject's cwd or in any path handed to it contains `user-test`, a condition letter, or a degree. Prefer a neutral root: a path advertising `scratchpad`, `tmp-<session-uuid>`, or similar reads as disposable scaffolding on its own.
- **Never nest inside a host repo**: a sandbox placed inside an unrelated repo leaks through `git status`, through the host's `CLAUDE.md` contradicting the fixture's own conventions, and through version/tooling mismatches between the two. It also *corrupts git-touching tasks* — asked to commit, a subject either commits into the host repo or has to invent a policy. Give the sandbox its own fresh `git init`; an inherited history can name the fixtures.
- **Git identity**: a fresh `git init` inherits the *user's real name and email* into every fixture commit. Set a neutral author per sandbox (`git -c user.name=... -c user.email=...`). A subject reading `git log` on a supposedly third-party project must not find the person who staged the test listed as its author.
- **Spawning-session leak**: sub-agents inherit the launching session's working directory, its `CLAUDE.md`, and the user's identity — subjects have volunteered "this isn't the dotfiles repo" and cross-checked fixture authors against the user's real email. Worse, a sub-agent's shell starts in that inherited cwd, so a bare `git status` runs against **the real repo under test**: one subject reported exactly that before catching itself. Nothing inside the sandbox prevents this. Launch subjects from a session whose cwd is *not* the repo under test, and treat any inherited-context mention as a confound to report, not a finding.
- **Prompt**: the task statement + sandbox paths only; zero prose carried over from the design conversation.
- **Framing**: a work request ("add pagination to this service using the library in ./lib"), never an evaluation ("try out this API").
- **Awareness**: the subject is never told it is in a test, what the alternatives are, or what outcome is hoped for.
- **Contents**: no leaky names inside files either — fixture READMEs, package names, comments.

Workflow `label`s are progress-display only and never reach the subject, so keep those readable (`a-deg2`).

## 4. Run

- Prepare each cell's sandbox per section 3, then write the cell → path map to `cells.md`. Each subject works in its own dir, so no isolation machinery is needed. Only use worktree isolation when the task must genuinely run against the real repo tree — and then stage the fixture docs into a neutral directory outside `user-test/` and pass *that* path, both because untracked `user-test/` files don't appear in a worktree and because the path itself would be a tell.
- Fan out all cells with the Workflow tool (this skill is your opt-in): one `agent()` per cell, `model`/`effort` overrides per the plan, and a `schema` capturing the behavioral measures (completion, misuse events, retries, hallucinated surface, notable confusion) plus a short self-narration of what the subject did. Labels like `a-deg2` keep the grid readable in progress output.
- **When the design needs follow-up turns, use the Agent tool plus SendMessage instead.** Workflow's `agent()` is single-shot, so any measure that asks the subject something *after* the work — precisely so the question can't prime the work — cannot run inside a workflow. Spawn one Agent per cell and drive the later turns with SendMessage.
- The subject prompt: the work request, the sandbox path, and "when done, report what you built and any points where you were stuck or unsure." That last line harvests confusion signals without revealing the test. The Agent tool has no `cwd` parameter, so name the sandbox path explicitly and have the subject move there first.
- **Solve every cell yourself before launching.** Write a reference solution per cell and run it against the fixture. This is the cheapest gate in the method: it catches tasks that are impossible as staged, and failures that would be blamed on the variable under test but actually come from a fixture bug. When conditions are compared, solve each cell in *every* condition — a task or grader that only works in one condition manufactures the result.

## 5. Read and report

Grade openly yourself — no blind grading, no grader agents. Read each cell's output and transcript against the declared measures, then fill the grid.

- **Read the pattern, not the cells**: monotonic + widening → real effect; flat → no detectable difference at this power (also an answer); scrambled → noise or confound (say which you suspect and why).
- Write `results.md` and report to the user: the matrix as a compact grid (pass/partial/fail glyph + a 2–3 word behavior note per cell), a short **direction recommendation** answering the original question, and pointers to the sandbox paths in `cells.md` for anything surprising. Flag any deviation from the confirmed plan.
