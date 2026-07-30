# Paced Lean Code Review — the reusable method

A **durable, resumable** way to code-review this monorepo **without burning a whole usage window at once**.
Reach for this whenever you'd otherwise "do a full code review" — do NOT fire one giant fan-out.

> **⏸ STATUS: paced reviews are PAUSED for the autonomous daemon (owner directive, 2026-07-29).**
> `ops/autonomous/next-review-unit.sh` has a master switch (`REVIEW_ENABLED_DEFAULT=0`) that makes the WS11
> cadence always report "none due", so **no daemon session will start a review** — it drains bugs instead. The
> reason is supply, not doubt in the method: the owner-commissioned Codex full-suite review of 2026-07-29 filed
> **24 confirmed findings** as `SUITE_TODO.md` **Wave 23**, so the bottleneck is fixing, not finding.
> **Everything in this document remains current and correct** — it's the method to use when reviews resume, and
> the `lean-review` / `review-sweep` skills still work for an **owner-initiated** review at any time. See
> `ops/autonomous/README.md` §"Paced reviews are currently OFF" for how to turn the cadence back on.

## Why this exists (the lesson)

A single monolithic review (`~15 finders × up to ~270 verifier agents`, the old
`.maintenance/suite-audit.workflow.js`) burned **~900k+ output tokens and hit the usage cap with 0 usable
output** — every agent died before synthesis. A full review must therefore be **chunked and paced**, not run
as one shot. (Memory: `overnight-jobs-queue`.)

## The method in one sentence

Review **one subsystem UNIT per session** with a **lean ~6-finder fan-out** (one finder per dimension), where
**each finding is refuted-by-default verified once** (not a multi-lens panel), then persist the unit's report
and mark it done — so a fresh session always resumes at the next unfinished unit.

The finder + verifier agents are pinned to **Opus at max effort** (`model:'opus', effort:'max'` on the
`agent()` calls) — reviewing/judging is the hardest stage, where max effort pays off, and it shouldn't depend
on the launching session's effort. This raises per-agent token cost, so keep parallel sweeps ≤2–3 units (see
Batch sizing).

## The three levers that keep it inside a window

1. **One unit per session.** ~90 Processor + ~38 Reader + ~67 Notes Swift files + companions → **16 units**
   (below; iOS on hold). A session does ONE, commits its report, marks it done, exits. Usage caps reset ~every
   5h; the next unit runs in the next window. Durable progress = `.maintenance/REVIEW_PROGRESS.md`.
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
| ~~7~~ | ~~iOS companion~~ | **ON HOLD — skip** (maintain-only; see SUITE_TODO "Project focus") | — |
| 8 | Reader/Core | `ArchiveReader/macOS/Sources/ArchiveReader/Core/` | **TagWriter / file-safety (PRIME)**, content index |
| 9 | Reader/Search | `ArchiveReader/macOS/Sources/ArchiveReader/Search/` | index correctness, Spotlight consistency |
| 10 | Reader/Views | `ArchiveReader/macOS/Sources/ArchiveReader/Views/` | resource/perf (large tables), inline-edit safety, **render (blank/wrong pixels)** |
| 11 | Notes/Store+Tags | `ArchiveNotes/macOS/Sources/ArchiveNotes/Store/ ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesTagProjector.swift ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesTagVocabulary.swift` | **PRIME file-safety:** the shared `CoordinatedTagWriter` tag-write choke-point (+ the latent concurrent-write race, W15.tu3), atomic store writes / Trash-delete / asset name-reservation, front-matter + block codec integrity, **never writes the corpus** |
| 12 | Notes/Index+Org | `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/` | FTS5 correctness, prune-gate never-wipes (empty snapshot), OrganizationStore replication / delete-last-instance invariants, org-graph persistence, DB-vs-fixture shadowing |
| 13 | Notes/Core | `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/ ArchiveNotes/macOS/Sources/ArchiveNotes/Models/` | model/scope state, extract provenance + jump-to-source correctness, replication/delete guard at the VM layer, sort/filter determinism (tag projector itself is covered by unit 11) |
| 14 | Notes/Editor | `ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/` | Markdown⇄disk round-trip idempotency (no silent text loss), autosave/flush-on-switch race, force-quit flush, inline-image asset writes, TextKit 2 |
| 15 | Notes/Views | `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/` | resource/perf at 100k-note scale, **PDF-pane render (blank/wrong pixels — Notes has NO RenderProbe yet → live sighted loop)**, state desync |
| 16 | Notes/Zotero+Links+Paste | `ArchiveNotes/macOS/Sources/ArchiveNotes/Zotero/ ArchiveNotes/macOS/Sources/ArchiveNotes/Sources/` | Zotero client robustness over the real transport, durable-link resolution + re-grant + **path-traversal**, source-block paste / pasteboard codecs |

> **Views units (5, 10) — visual dimension.** View / PDF-render code fails in a way the other dimensions miss:
> it renders blank or wrong while every assertion and the accessibility tree still pass. Add a render-guard /
> snapshot check (`RenderProbe` / `DocumentRenderGuardTests`, headless — no launch/TCC) or drive `ops/gui/` for
> the live app. Reader has the guards today; Processor/Notes fall back to the live sighted loop. See
> [`ops/gui/README.md`](ops/gui/README.md).

**Scope (owner, 2026-07-09 — see SUITE_TODO "Project focus & ON-HOLD"):** the **iOS companion (unit 7) is
ON HOLD — skip it.** For **Processor/Net (unit 2)**, review the **LAN/USB** transmission surface
(`CaptureServer`, `CaptureReceiver`, `CaptureValidation`, `USBBridge`, `RelayObjectFormat` as a contract) but
**skip the cloud/Drive relay** (`DriveObjectStore`, `DriveClient`, `DriveAuth`, `FileRelayReceiver` cloud
path) — it's maintain-only. Everything else (Capture, OCR, Tagging, Views, **Android**, Reader) reviews as normal.

**Archive Notes units (11–16, added 2026-07-18).** Notes was built after the original 10-unit pass and had
**never been lean-reviewed** (it has strong W8 *unit* tests, but no adversarial cross-cutting review). All six
enter the cadence picker's tier-1 (never-reviewed) pool, taken in table order. Notes has no on-device/companion
surface and no HOLD carve-out; review all six as normal. The one caveat is the visual dimension on unit 15
(Notes/Views): Notes has **no headless `RenderProbe`** yet, so a blank/wrong PDF pane or thumbnail can only be
caught via the live sighted loop (`ops/gui/`), not a headless guard.

> **Cadence bookkeeping caveat (orthogonal, pre-existing).** `last-reviewed.tsv` currently records **only
> `Processor/Capture`** — the one-pass sweep's completed units (Net/OCR/Reader/…) predate the WS11 `--record`
> cadence and so also read as `last=never`. So the tier-1 pool is not "just Notes": the picker will reach the
> highest-in-table-order never-recorded unit (Processor/Net, then the high-churn OCR at ~48 unreviewed commits)
> **before** Notes. Notes is in the rotation regardless. If Notes should go FIRST, backfill the TSV for the
> genuinely-completed units (see `REVIEW_PROGRESS.md`) — an owner call, not done here.

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
   backlog (`SUITE_TODO.md` or the `.maintenance/AUTONOMOUS_PLAN.md`).
5. Mark the unit **done** in `REVIEW_PROGRESS.md` (with the confirmed count) + commit. Exit.

Because the unit list is durable (this file) and progress is persisted, the review survives usage cutoffs,
context compaction, and session restarts — the next session just continues at the next unfinished unit.

## Recurring cadence for a long unattended run (WS11, 2026-07-17)

`REVIEW_PROGRESS.md` above is a **one-pass** sweep (each unit → done, sweep ends). For a multi-week unattended
run the review must instead **recur and follow the churn** — re-review whatever code actually changed. The
autonomous daemon does this automatically:

- **`ops/autonomous/next-review-unit.sh`** is the deterministic picker. It tracks a **last-reviewed sha per
  unit** in `.maintenance/review/last-reviewed.tsv` (gitignored, primary-checkout — like the plan), and each
  time it's asked, names the unit with the most **unreviewed commits touching its paths**
  (`git rev-list <last-sha>..HEAD -- <paths>`; never-reviewed units sort first for initial coverage). It's
  **cadence-gated** (`AUTONOMOUS_REVIEW_EVERY`, default 20 commits since the last review of *any* unit) so
  review interleaves with feature work instead of starving it. `--status` shows every unit's backlog;
  `--record <unit>` stamps it reviewed at HEAD.
- The daemon's resume prompt (STEP 2.0) runs it every session: if a review is **due**, that session *is* the
  review — `lean-review` on the one named unit (read-only), confirmed findings appended as `[ ]` fix items
  (HIGH-on-irreversible → the needs-owner hold queue), then `--record` + commit. Proven by
  `ops/autonomous/tests/prove-review-cadence.sh`.

The unit table above stays the single source of truth; the picker embeds the same units (iOS still skipped)
and carries a "keep in sync" note.

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
