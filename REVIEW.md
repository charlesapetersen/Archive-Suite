# Paced Lean Code Review — the reusable method

A **durable, resumable** way to code-review this monorepo **without burning a whole usage window at once**.
Reach for this whenever you'd otherwise "do a full code review" — do NOT fire one giant fan-out.

## Why this exists (the lesson)

A single monolithic review (`~15 finders × up to ~270 verifier agents`, the old
`.maintenance/suite-audit.workflow.js`) burned **~900k+ output tokens and hit the usage cap with 0 usable
output** — every agent died before synthesis. A full review must therefore be **chunked and paced**, not run
as one shot. (Memory: `overnight-jobs-queue`.)

## The method in one sentence

Review **one subsystem UNIT per session** with a **lean ~6-finder fan-out** (one finder per dimension), where
**each finding is refuted-by-default verified once** (not a multi-lens panel), then persist the unit's report
and mark it done — so a fresh session always resumes at the next unfinished unit.

## The three levers that keep it inside a window

1. **One unit per session.** ~90 Processor + ~38 Reader Swift files + companions → **10 units** (below). A
   session does ONE, commits its report, marks it done, exits. Usage caps reset ~every 5h; the next unit runs
   in the next window. Durable progress = `.maintenance/REVIEW_PROGRESS.md`.
2. **Lean fan-out.** ~6 dimension finders (not 15), and **single refute-verify** per finding (not a 3-lens
   panel). That's ~6 + (findings) agents/unit — the shape that completed cleanly before (~20 agents).
3. **Budget guard.** Resume sessions cap spend with `--max-budget-usd`; the workflow verifies findings as each
   dimension completes (pipeline, no barrier) so a slow finder never idles the rest.

## Review units (canonical, durable list)

Highest-risk first. Paths are repo-root-relative.

| # | Unit | Paths | Prime focus |
|---|------|-------|-------------|
| 1 | Processor/Capture | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/` | finalize/move, session state, actor isolation |
| 2 | Processor/Net | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/` | relay object format, Drive auth, transport, protocol |
| 3 | Processor/OCR | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/` | segmentation, PDF render/merge, file-safety, SPEC |
| 4 | Processor/Tagging+Models | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Tagging/ ArchiveProcessor/macOS/Sources/ArchiveProcessor/Models/` | tag/PDF SPEC, Keychain, settings |
| 5 | Processor/Views | `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Views/` | resource/perf, main-thread work, state desync |
| 6 | Android companion | `ArchiveProcessor/ArchiveCapture/` | capture path, wire protocol, lifecycle |
| 7 | iOS companion | `ArchiveProcessor/ArchiveCaptureiOS/` | capture path, wire protocol, OAuth token exchange |
| 8 | Reader/Core | `ArchiveReader/macOS/Sources/ArchiveReader/Core/` | **TagWriter / file-safety (PRIME)**, content index |
| 9 | Reader/Search | `ArchiveReader/macOS/Sources/ArchiveReader/Search/` | index correctness, Spotlight consistency |
| 10 | Reader/Views | `ArchiveReader/macOS/Sources/ArchiveReader/Views/` | resource/perf (large tables), inline-edit safety |

## How to run one unit

The workflow is `.claude/workflows/lean-review.js` (named workflow `lean-review`). From a session at the repo
root:

```
Workflow({ name: 'lean-review', args: {
  unit:  'Processor/Capture',
  paths: 'ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/',
  focusNote: 'finalize/move + drain-gate are the no-undo hotspots'   // optional
  // dimensions: [...]  // optional override; default = 6 dimensions in the script
}})
```

It fans out 6 dimension finders → refute-verifies each finding → returns
`{ unit, confirmed:[...], refuted:[...], raw_count }`. Confirmed findings are ranked high→low.

## The loop (what a session does)

1. Read `.maintenance/REVIEW_PROGRESS.md`; pick the **first unit not marked done** (create the file from the
   table above on first run).
2. Run `lean-review` for that unit (one `Workflow` call).
3. Write the report to `.maintenance/review/<unit>.md` (confirmed findings + the refuted list for audit).
4. **Triage confirmed findings:** fix small/clear ones now (own worktree, build-verify, Tier-2 where the
   change is no-undo — see root `CLAUDE.md` §"How we work"); append larger ones as fix items to the active
   backlog (`SUITE_TODO.md` or the overnight `.maintenance/OVERNIGHT_PLAN.md`).
5. Mark the unit **done** in `REVIEW_PROGRESS.md` (with the confirmed count) + commit. Exit.

Because the unit list is durable (this file) and progress is persisted, the review survives usage cutoffs,
context compaction, and session restarts — the next session just continues at the next unfinished unit.

## Guardrails

Findings that touch a no-undo path (`Capture/`·`Net/`, file-writing tag/output, finalize, actor isolation,
the tag/PDF SPEC) are **Tier-2**: the fix needs an adversarial re-review + a functional test on a scratch
copy, never the real corpus. A review that only *reads* is safe; only the *fixes* carry risk. Never `--force`
past a git safety refusal (memory `no-force-override-destructive-git`).

## Batch sizing — how much to run at once (learned 2026-07-09)

`.claude/workflows/review-sweep.js` reviews **several units in parallel** for when you have usage headroom.
But **do not sweep all ~10 units at once** — that fans out ~80 agents / ~3M tokens and **hits the session
usage cap mid-run** (finders run, verifiers die → raw, unverified findings; same failure mode as the retired
15-finder monolith). Safe sizing:
- **Default: the paced daemon**, one unit per fresh session (sustainable indefinitely; a usage cutoff just
  pauses it).
- **With headroom: `review-sweep` on ≤2–3 units at a time**, then triage before the next batch.
- A single window holds very roughly **~50–60 agents / ~2.5M output tokens** before the cap; size batches well
  under that and expect refute-verifiers to double the finder count.

## Relationship to other review tools

- `.claude/workflows/lean-review.js` + this doc = **the paced full-codebase review**, ONE unit per session
  (use for "review everything" / audits / overnight — the safe default).
- `.claude/workflows/review-sweep.js` = the **parallel multi-unit** variant for headroom bursts — **≤2–3
  units per run** (see Batch sizing above).
- `/code-review` skill = the **working-diff** reviewer (use for the change in front of you).
- `.maintenance/suite-audit.workflow.js` = the **retired monolith**, kept only as a cautionary reference of
  what NOT to run as one shot. Prefer `lean-review`, one unit at a time.
