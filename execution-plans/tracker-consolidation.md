# Execution plan — tracker consolidation

**Status:** Phases 0–3 SHIPPED 2026-08-01. **Phase 4 specified but NOT landed** — a trial migration proved it
silently wrong twice and was reverted; see that section. Owner-directed, executed interactively — NOT daemon work.
**Owner:** Charles. **Scope:** repo-wide documentation + the daemon's work-selection path.
**Risk:** MEDIUM-HIGH on Phase 4 only — it changes `next-queue-item.sh`, the mechanism that decides what the
daemon works on. A bug there means working the wrong item, redoing shipped work, or — the real hazard —
offering an owner-gated money-path item that was never cleared. Phases 1–3 are docs-only and near-zero risk.

## Why this exists

On 2026-08-01 the same defect class surfaced **three times in one morning**:

| What | How it failed |
|---|---|
| `W21.vmgui-path` | Fixed + ticked in `SUITE_TODO` on 07-31, left `[ ]` in the plan → the resolver was offering already-shipped work |
| `resume-prompt.txt` | Told every daemon session the authorized items were "`W15.tu0` and `R13d`" — six grants out of date |
| `prove-exit-logging.sh` | False-failed ~4 runs in 6, so a real regression would have hidden in the noise |

Every one is **a secondary copy drifting from the truth.** That is the thing to fix — not "too many files."

## The criterion (applied honestly, not to justify the status quo)

The owner's instruction was explicit: *"Make sure there's actually a reason for these separate documents and
it's not just path determinacy."* So each document must earn its separateness against at least one of:

- **C1 — tooling binds to its path.** A script reads it; moving it breaks something real.
- **C2 — distinct lifecycle.** Created, updated and deleted on a different cadence than its neighbour.
- **C3 — distinct audience / load pattern.** Read in different sessions, so merging costs tokens on every
  unrelated change (the repo's standing token-efficiency directive).
- **C4 — distinct durability.** Committed policy vs gitignored runtime churn.
- **C5 — distinct mutability.** Append-only log vs edited state.

**A document meeting none of these should not exist separately.** Measurements below are from 2026-08-01.

## Verdicts

### KEEP — separateness earned, reason named

| Document | Evidence | Criterion |
|---|---|---|
| `CLAUDE.md` | 4 scripts bind it; read every session | C1, C3 |
| `AGENTS.md` | 3 scripts; **has a genuinely different audience** — non-Claude agents that never read `CLAUDE.md`. Not hypothetical: it carries a "Working the to-do list as an external agent (Codex et al.)" section and Codex has really worked in this repo | C1, C3 |
| `SPEC/*` | The cross-app contract; the one thing coupling the apps | C1, C3 |
| per-app `CLAUDE.md` (×3, 37–53K) | Token-efficiency directive: a change loads *one app* + one spec, not all three | C3 |
| `OWNER_AUTHORIZATIONS.md` | Permanent policy vs the plan's per-session churn; committed 2026-08-01 for exactly this reason | C2, C4 |
| `execution-plans/*` | Transient by design — deleted on ship (DEVONthink is an owner-stated exception) | C2 |
| `REVIEW.md` (14K) | Only 1 script binds it, but folding 14K of review method into the 16K always-loaded `CLAUDE.md` would nearly double what every unrelated change pays. Not read unless reviewing | C3 |
| `POTENTIAL_FEATURES.md` (×3, 72 items) | No tooling and 2 weeks stale — the weakest case here. Kept on C3: you read an app's wishlist while working *in that app*, and merging 287 lines into an already-3,567-line `SUITE_TODO` moves it the wrong way | C3 |
| `.maintenance/AUTONOMOUS_*_ARCHIVE.md` (433K) | Append-only history written by `compact-plan.sh`; keeping them out of the live plan is what stops session startup inflating | C1, C5 |

### FIX — separateness NOT earned, or the split is in the wrong place

| # | Problem | Evidence | Action |
|---|---|---|---|
| **F1** | **The item list is duplicated.** `SUITE_TODO` and the plan's WORK QUEUE both hold it | **100 shared items**; 21 with substantially duplicated prose; produced the `W21.vmgui-path` failure | Phase 4 — one list |
| **F2** | `.maintenance/ARCHIVE_NOTES_PROGRESS.md` (139K) is **dead** | **0 open / 57 done**, untouched since 07-16, zero tooling, superseded by `execution-plans/archive-notes/` | Phase 1 — retire |
| **F3** | `SUITE_TODO` conflates a live queue with its own archive | **46 open vs 139 done**, all retained in full text, in a 3,567-line file git already versions | Phase 2 — trim done items |
| **F4** | `CLAUDE.md` and `AGENTS.md` both explain GUI verification | 7 vs 8 mentions; the same topic maintained twice is how drift starts | Phase 3 — one canonical home |

**Net:** the doc *set* is largely justified — most splits have a real, nameable reason, which is the answer
to "is this just path determinacy?". The genuine defects are one duplicated **item list**, one **dead file**,
one file mixing **queue with archive**, and one **duplicated topic**.

## Phases

Ordered by risk, lowest first. Each is independently landable and independently revertible.

### Phase 0 — the guard ✅ DONE (`08fa6ed`)
`check-tracker-sync.sh` + `prove-tracker-sync.sh` (16 assertions), WARN-only in `health-gate.sh`. Makes F1's
drift loud *before* the risky fix, and doubles as Phase 4's equivalence oracle.

### Phase 1 — retire the dead file (F2) ✅ DONE (`92f0667`)
Move `ARCHIVE_NOTES_PROGRESS.md` to the gitignored `old/` per the repo's archive convention (recoverable, not
deleted — it is gitignored, so git does NOT already hold it). Drop its one stale mention in
`ArchiveNotes/KNOWN_ISSUES.md`. **Risk: none** — zero tooling, zero open items.

### Phase 2 — separate the live queue from its archive (F3) ✅ DONE (`3483627`)
Move completed items out of `SUITE_TODO.md` into `SUITE_TODO_DONE.md` (committed — the completion notes cite
commits and are genuinely useful), leaving the live queue readable. **Do not delete them:** several closed
entries carry the reasoning for why a later change is or is not allowed to revisit that code.
**Risk: low** — but `check-tracker-sync.sh` and `next-queue-item.sh` read `SUITE_TODO`, so re-run both plus
`prove-tracker-sync.sh` and `prove-dep-gating.sh` after. **A `[x]` item that a `blocked-on` tag depends on
must still resolve** — that is the specific way this phase can break the resolver.

### Phase 3 — one canonical home per topic (F4) ✅ DONE (`92f0667`)
GUI verification lives in `AGENTS.md` (the operational detail is already there); `CLAUDE.md` keeps a one-line
pointer. **Risk: none.**

### Phase 4 — one item list (F1) — ATTEMPTED 2026-08-01, DELIBERATELY NOT LANDED

**Status: blocked on three findings a trial migration surfaced. The plan file was reverted; nothing shipped.**
Everything below the findings is still the right design — this is a specification now, not a proposal.

**The design insight that survives.** The plan's WORK QUEUE was never a *mirror* of `SUITE_TODO`: `SUITE_TODO`
groups by theme, the WORK QUEUE orders by priority. That is a genuine second job — which is *why* the
duplication exists — but it does not require copying each item's prose and checkbox. Target: the plan keeps the
**order** (a playlist of tags), `SUITE_TODO` owns **content and state** (the library), and the hold queue stays
positional. Nothing is left for the two files to disagree about.

**Safety property, unchanged:** an item is un-offerable because of *file position* — outside the region
`next-queue-item.sh` walks. Keep it positional. Note the scar tissue: on 2026-08-01 a `blocked-on` tag used as
a hold gate turned out to be a *timer*, because a completing item satisfied it. A bare `[hold]` tag is weaker
than position and is not sufficient alone.

#### What the trial migration proved (do not rediscover these)

1. **`awk -v` silently truncates a multi-line list.** Passing the tag list that way lost most of it: 30 of 35
   tags resolved as 6. Use a temp-file map. *Caught by the strangler diff, which is the entire argument for
   running one.*
2. **ORDER breaks when two entry styles are emitted in separate passes.** A queue mixing checkbox entries and
   tag references came out in the wrong order. The plan's order is the whole reason the region exists — getting
   it wrong is worse than the duplication being removed. Fix: one file-order pass handling both forms.
3. **`(blocked-on: …)` lives in the PLAN's item text, not in `SUITE_TODO`.** Converting to bare tags dropped
   the clauses, and **`W16.bat6` and `W21.vmgui` both flipped from `blocked` to `ok`.** W16.bat6 becoming
   actionable before W16.bat3 lands would have inverted a fix order the owner confirmed that same morning — a
   silent correctness failure on a money path, caused by a docs cleanup. Fix: let a tag reference carry its own
   `(blocked-on: …)`; a dependency **is** an ordering constraint, so it belongs with the order.

#### Also outstanding

- **74 done tags' state lives ONLY in the plan** and would vanish if the WORK QUEUE were stripped. Exactly
  **1** is currently depended on (`W16.bat3-owner-ok`, a hold-queue gate that stays in the plan), so the
  exposure is small — but it is luck, not a property. Either migrate them into `SUITE_TODO_DONE.md` or keep a
  compact completed-tags list in the plan.
- A **hold-gate test** is still owed: prove by test, not by reading, that an owner-gated item cannot be offered.

#### Sequence when resumed

1. One file-order pass emitting both entry forms; tag references may carry `(blocked-on: …)`.
2. Convert the plan's open entries to tag references; assert an **identical ordered queue** via the strangler
   diff before anything else. `check-tracker-sync.sh` is the oracle.
3. Resolve the 74 plan-only done tags.
4. Extend `prove-dep-gating.sh` for tag references, ordering, and the hold gate.
5. Only then reduce the plan's WORK QUEUE, leaving it genuine runtime state — run status, cursor, Session Log.
   The seam is *"does this change every session?"*, not *"is this for the daemon?"*

**Execution constraints:** interactively, daemon **down**. Never daemon work — it modifies the thing that
selects daemon work.

*Sequencing note (2026-08-01):* an earlier draft said to wait for the authorized W16 money-path items to land.
The owner chose to execute immediately, and that was right — the daemon is down and re-arming is his, so this
was the only window where nothing could pick up a half-migrated queue. Finding #3 vindicates the caution
differently: the danger was never a stranded item, it was a **silently reordered** one.

## Definition of done

Phases 0–3 are done. What remains is Phase 4 alone:

- One list of items; the plan holds no second copy.
- `check-tracker-sync.sh` still meaningful or deliberately retired with its reason recorded.
- `prove-dep-gating.sh`, `prove-tracker-sync.sh`, `prove-daemon.sh`, `prove-status.sh` all green.
- The hold gate demonstrably still blocks an owner-gated item — proven by a test, not by reading.
- `SUITE_TODO.md`, `CLAUDE.md` and `AGENTS.md` updated in the same commits; this plan deleted on completion.
