# Owner Authorizations — itemized exceptions to the hold queue

**This file is the authoritative, version-controlled record of what the owner has explicitly cleared the
autonomous daemon to do on otherwise-gated paths — together with the hard constraints attached to each
grant.** It is deliberately *committed*, not kept in the gitignored maintenance plan: these are the
highest-stakes decisions in the repo (money paths, destructive deletes, the cross-app SPEC), and they need
history, review and recoverability like any other durable artifact. Moved out of
`.maintenance/AUTONOMOUS_PLAN.md` on 2026-08-01 for exactly that reason — it previously existed only as a
gitignored section on a single laptop, with no record of who granted what, when, or under which constraints.

## ⭐ READ FIRST — this file is now a RECORD, not a gate (owner, 2026-08-13)

**The per-item authorization requirement was lifted.** `Capture/`·`Net/`, finalize/manifest, file-writing
tag/output, money paths and `SPEC/tag-format.md` **no longer need an entry here** before the daemon may work
them. **Tier-2 is the gate** — adversarial review plus a functional test on scratch copies. The full policy,
including the only two things still owner-gated (a write to the real corpus; work only the owner can perform
or judge), is in [`AGENTS.md`](AGENTS.md) → §*Gating baseline*.

Owner's words: on the categories, *"I'm not sure why I need to authorize these kinds of things. The baseline
assumption that I need to do these authorizations should be changed as well."* On money, *"we don't need my
permission for spending money. The daemon only spends tiny amounts and the keys are capped."* On the SPEC,
*"nothing real has been created by these apps yet."*

**What this file is still for.** Two things, both durable:
1. **The existing grants below remain binding on the items they name.** A grant's ⛔ constraints were often a
   deliberate *design* choice, not a safety formality — `R13d`'s no-strip rule is the clearest case — and
   those choices survive the gate being lifted. Read the entry for an item you are about to work.
2. **A record of decisions with their reasoning**, marked discharged when the item ships rather than deleted,
   because the constraint history is why a later change is or isn't allowed to revisit that code.

**Do not re-impose the old gate** from a stale sentence in an older doc, and do not park an item as
owner-gated on the grounds that it touches one of the de-gated categories.

## How this file works

- ~~**The hold-queue categories still stand in general.** This file is the ONLY place that narrows them, and it
  does so **per item, never per category**. If an item is not listed here by tag, it is still hold-queue.
  A category is never authorized wholesale.~~ *(Superseded 2026-08-13 — see the banner above. An item not
  listed here is now governed by Tier-2, not by the hold queue.)*
- **An entry is a licence plus its limits.** The ⛔ constraints inside a grant are part of the grant, not
  advice. Read the entry before starting the item and obey it verbatim. If you cannot satisfy a constraint,
  STOP and flag it to Daemon Report — do not proceed on a narrower reading of it.
- **Entries are a permanent record.** When an authorized item ships, mark the entry discharged (with the
  commit) rather than deleting it: the constraint history is why a later change is or isn't allowed to
  revisit that code. This file is not a to-do list — `SUITE_TODO.md` is.
- **Granting is the owner's act alone.** No agent may add an entry here on its own judgement, and a general
  later directive does not silently reverse a specific earlier decision (see the `R13d` note below for a live
  example). The daemon's *structural* gate remains the plan's HOLD QUEUE, which physically parks an item
  outside the region `ops/autonomous/next-queue-item.sh` walks.
- **Where the pieces live:** the live work queue and hold queue are in `.maintenance/AUTONOMOUS_PLAN.md`
  (gitignored runtime state); the item list of record is `SUITE_TODO.md`; the grants are here.

## Grants

*(Granted across the 2026-07-28, 2026-07-29 and 2026-08-01 Daemon Report walkthroughs — each entry states
its own date. Verbatim as recorded when granted.)*

- **`W21.e2e-fu2` · `W17.stg1` · `W17.det1` — AUTHORIZED 2026-08-13, and then made moot the same hour.**
  Granted individually in the walkthrough that also lifted the gate itself, so they are the last three items
  ever to have needed a signature. Recorded because their **constraints are design decisions that still bind**:
  - `W21.e2e-fu2` — correct the READY line to publish `lanToken`. ⛔ The **file-relay READY line stays on
    `token`**; ship a regression proof that distinguishes the two credentials, since the whole defect was one
    credential standing in for the other.
  - `W17.stg1` — `schemaVersion` + fingerprint on the staging manifest. ⛔ **Manifest only — NO per-source
    content hash** (the owner's earlier decision, unchanged). ⛔ A corrupt or unknown-version manifest is
    **renamed** to `staging-manifest.corrupt-<ts>.json` and surfaced in a banner — **never auto-deleted, never
    silently continued**; silent-open is the bug being fixed. Prove in the `$0` `LIVECAPTURE_RECOVERYTEST`
    driver, scratch copies only. Prerequisite `W3.cap-r4` shipped 2026-08-02.
  - `W17.det1` — stranded-session detection. ⛔ **Pure logic only: no new SwiftUI, no banner, no Recovery
    screen.** Count goes on the existing status line / log. The at-launch banner is revisited only once this has
    been seen to fire — the point is to settle empirically whether stranded sessions occur before spending any
    design-review time on UI.
- **`W26.docs-spec` — AUTHORIZED to edit `SPEC/tag-format.md` (doc-only), 2026-08-11.** Correct the three
  places the shared contract still describes **Spotlight** as the Reader's tag-discovery mechanism, which
  `W26.walk2` removed: the API table's *"Spotlight view … Reader `ArchiveLibrary`"* row, the
  *"`kMDItemUserTags` is lossy/stale … used only to find files"* bullet, and the *"never build the write
  array from Spotlight"* clause in the write rules. **The tag VOCABULARY is untouched** — no token, facet,
  date rule, priority, colour or PDF-format change — so nothing either app *writes* or *parses* moves; only
  the reader-side API row, which is why this is doc-only.
  ⛔ **CONSTRAINT: this grant is exactly those three sites and their surrounding sentences.** It is not a
  standing licence over `SPEC/tag-format.md`; a further SPEC edit needs its own grant, as `W15.tu0` and
  `R13d` each did.
  **Why it was gated at all:** the API-table row is a line both apps must read identically, so under
  `CLAUDE.md` §*"The shared contract is the risk"* it lands with both apps together and Tier-2 applies.
  The item's own two bullets contradicted each other on that point (bullet 1 said it was not a
  shared-contract change, bullet 2 said it was); **bullet 2 is the binding reading**, and resolving the
  contradiction was part of the item. Offered to the owner as the `W15.tu0` shape on 2026-08-07 and
  **deferred in favour of splitting** `W26.docs` so it would stop being skipped at the head of the queue;
  granted on 2026-08-11 when he asked for the hold queue to be resolved. Normal Tier-2 gate still applies.
- **`W15.tu0` — AUTHORIZED to edit `SPEC/tag-format.md` (doc-only).** Add the paragraph recording that a
  `["A","A","B"]` tag array survives a `.tagNamesKey` write→read round-trip (i.e. macOS persists duplicate tag
  strings), beside the existing multiset rule. **No behaviour change, no code path altered** — the fact is
  already load-bearing and proven end-to-end by `W15.tu1`'s shipped test (`2f5c3ae`), so this only writes down
  what the suite already relies on. Also land tu0's scratch premise test. Normal Tier-2 gate still applies.
- **`R13d` — AUTHORIZED to remove the `ArchiveSuite` "Suite marker" row from `SPEC/tag-format.md`, WITH A HARD
  CONSTRAINT: do NOT strip existing stamps.** The owner chose the no-strip variant deliberately.
  - ✅ **CONSTRAINT REVERSED BY THE OWNER, 2026-08-13 — STRIPPING IS NOW AUTHORIZED.** Asked directly (the
    2026-08-01 note below says to ask, and that this question had become cheap), he chose the clean end state:
    `R13d` now **also removes `ArchiveSuite` stamps already written**, so the marker is gone everywhere and no
    inert-legacy carve-out survives. Rationale on record: only test material is affected, and the standing
    premise's own words are *"No inert-legacy carve-outs — rules that exist to avoid disturbing already-written
    app output are moot"* and *"Prefer the right end state to the compatible one."* Released from the HOLD
    QUEUE into the WORK QUEUE at the same time — it had been authorized-but-unqueued, i.e. unpickable AND
    uncounted, since 2026-07-16.
    ⛔ **Still binding:** scratch copies only, never a real store, and the strip is a real tag WRITE, so it is
    Tier-2 with a functional proof that a stripped note keeps every OTHER tag it had. The "NEVER add the marker
    to a strip list" line in the bullets below is what has been reversed — nothing else in this grant is.
  - ⚠️ **PREMISE PARTLY VOID (2026-08-01).** Every "the owner's real note `.md` files" justification below is
    written against notes that **do not exist** — see §STANDING PREMISE. The no-strip rule therefore protects
    test material, not research data, and is now a *preference on record* rather than a data-safety
    requirement. **Do NOT unilaterally start stripping**: it was an explicit, deliberate owner choice, and a
    later general directive about compatibility is not the same as him reversing a specific decision. If a
    clean design wants stripping, ASK — that question is now cheap to answer, where before it was not.
    Everything else in this grant stands as written.
  - Remove the marker from `NotesTagProjector`'s **managed set**, so stamps already written to the owner's real
    note `.md` files are left **INERT** — present, unmanaged, never touched again.
  - **NEVER** add the marker to any strip/cleanup list, and never run a projection whose effect is to delete
    `ArchiveSuite` from existing files. Stripping is a real tag WRITE across the owner's notes and is NOT
    authorized. If you believe stripping is required for correctness, STOP and flag to Daemon Report instead.
  - Required functional proof (Tier-2, scratch copies only, never the real store): project over a note that
    ALREADY carries `ArchiveSuite` and assert the tag is still present and byte-identical afterwards, and that
    no other managed subject was lost. A test that only proves "new notes get no marker" is INSUFFICIENT.
- **`W3.cap-r1` — AUTHORIZED (granted 2026-07-29).** The tag/PDF-SPEC Capture fix at
  `LiveCaptureProcessor.swift:640/647/673`. Authorized because it is the highest-value Capture finding: today all
  three sites are `_ = try? MacOSTagger.applyTags(...)`, so a PDF can land byte-perfect, count as **filed**, have
  its **source photo trashed**, and carry no subject/date/priority tags at all — invisible to tag-driven triage in
  the Reader. It is the only way today's "filed" verdict can be silently wrong.
  - ⚠️ **HARD CONSTRAINT — both fixes MUST land in ONE commit.** (a) switch to the `colorIsAuthoritative` overload
    (so a segment whose subject is literally "Red"/"Purple" is not promoted to a Finder colour label) and (b) stop
    discarding the tag-write result. Both rewrite the SAME three lines, so shipping them separately means the
    second silently reverts part of the first. Do not split them, and do not "checkpoint" between them.
  - Owner decision already recorded in the item (2026-07-18): record a per-artifact `tagsApplied` and **warn in the
    finalize summary**, but the file still counts as filed — the bytes are safe and retagging is possible, so
    withholding "filed" (and thus retaining the source photo) over-corrects. Implement that, not a stricter rule.
  - Tier-2 unchanged: adversarially re-confirm the premise first, then a scratch-copy functional test. `Capture/`
    is a no-undo path.
- **`W19`-adjacent / dual-image: the `DurableLink` dual-path field — AUTHORIZED (granted 2026-07-29).** For the
  `SUITE_TODO` item "Reader/Notes: PDF + JPEG dual image reference", you MAY change
  `packages/ArchiveCore/Sources/ArchiveCore/Links/DurableLink.swift` to carry the resolved JPEG partner path
  alongside the PDF path. Justified by measurement, not preference: a read-only audit of all 102,516 PDFs found
  **80.1% of partners are "relocated"** (present under a differently-named collection folder) and only **10.5%**
  sit at the mirrored path — so the partner is genuinely NOT re-derivable and a citation must pin what was cited.
  - ~~**ADDITIVE ONLY.** The new field must be **optional**: every link written before this change must still parse
    to the same value it does today. Do not renumber, reorder or repurpose existing query items.~~
    ⚠️ **LIFTED 2026-08-01 — the premise is void.** This clause existed to protect links written by earlier
    builds; per §STANDING PREMISE there are none, and the owner has said transferability of existing outputs
    is not a concern. **You MAY change the link format outright** — renumber, reorder, repurpose — and pick the
    shape that is right rather than the shape that is compatible. Note in the commit that no compatibility was
    preserved *because there is nothing to be compatible with*. (The measurement that motivated the field is
    unaffected and still valid: 80.1% of PDF partners are relocated, only 10.5% sit at the mirrored path, so
    the partner genuinely is not re-derivable and a citation must still pin what was cited.)
  - **Shared-Core rule applies** (memory `shared-core-change-rebuild-all-apps`): `DurableLink` is consumed by
    Reader AND Notes, so build + test **all three** app test bundles plus `swift test` in `packages/ArchiveCore` —
    not just the app you are working in. A non-exhaustive switch elsewhere is exactly how W14.2 broke the Notes
    test bundle.
  - Round-trip proof required: old-format URL → parses unchanged; new-format URL → round-trips both paths; a
    malformed/absent JPEG field degrades to PDF-only rather than failing the whole link.
  - This grant covers the LINK FORMAT only. The rest of that feature (raised root, JPEGS index, sticky
    menu-driven switch) is ordinary non-hold-queue work — it needs no grant.
- **`W16.bat2-fu2` — ✅ DISCHARGED 2026-08-01** (`5424054` production + the contract commit that follows it;
  full record in `SUITE_TODO_DONE.md`). Every ⛔ below was met: the override is honoured only under
  `BATCHRESUME_TEST=1` with a usable absolute root; the fail-closed direction is checked against 9 near-miss
  flag values × 11 unusable roots; the DEFAULT deleter is run against a real journal file (neutering it to
  `{ }` now reddens 2 checks where it reddened 0); nothing ran against a real journal, because the
  destructive checks refuse to run unless the path is provably redirected; and `cancel()`'s semantics were
  not touched. The grant is retained verbatim below as the record. ⚠️ **Note for `W16.bat3`/`W16.bat5`:** the
  "the journal path is still not redirectable under test" clause in each of those grants has now been
  overtaken — it is redirectable, and `test-batch-resume.sh` redirects it. Their ⛔ SCRATCH-ONLY rule is
  unchanged and still absolute; what has changed is that satisfying it is no longer at odds with driving the
  real code.
  **AUTHORIZED (granted 2026-08-01, daemon-report walkthrough), AND SEQUENCED FIRST of the
  three W16 money-path items.** Give `pendingBatchURL`/`pendingRunURL` (`+Pipeline.swift:536`, `:571`) a test-only
  base-dir override on the existing `ARCHIVEPROC_TEST_BACKUP_ROOT` pattern, so the DEFAULT
  `makeBatchJournalDeleter` body can be run against a temp directory instead of being grep-verified. Authorized
  because it is the prerequisite for proving `W16.bat3` and `W16.bat5` against the real deleter rather than a
  stub — the owner explicitly put it ahead of both. It also closes a live hazard: with the path un-redirectable,
  any future un-seamed deletion in the cancel block means *running `test-batch-resume.sh` on the owner's machine
  deletes his real journal*.
  - ⛔ **FAIL CLOSED — this is the whole constraint, keep it verbatim.** The override is honoured **ONLY** under
    `BATCHRESUME_TEST=1` and must default to the REAL path on anything else: unset, empty, malformed, or
    unparseable. A mis-read env var here strands a paid batch rather than merely failing a test. No other trigger
    (no debug flag, no `#if DEBUG` alone, no "is this a test bundle" sniffing) may enable it.
  - ⛔ **Prove the fail-closed direction, not just the happy path.** The regression test must assert that with
    `BATCHRESUME_TEST` absent/garbage the resolved path is the real one — a test that only shows the override
    works when set would pass on an implementation that silently redirects in production.
  - ⛔ **Then prove the DEFAULT deleter body runs.** The point of the item: a check that fails if
    `makeBatchJournalDeleter`'s default is neutered to `{ }`. Today mutating it keeps all 213 checks green; after
    this, it must not.
  - ⛔ **SCRATCH ONLY**, and do not run `test-batch-resume.sh` against a real journal at any point while landing
    this. Tier-2 in full, premise re-confirmed by symbol first. **Does NOT authorize** any change to what
    `cancel()` deletes — that is `W16.bat3`/`W16.bat5`, granted separately below.
- **`W16.bat3` — ✅ DISCHARGED 2026-08-02** (`53e43e2` + the tracker commit that follows it; full record in
  `SUITE_TODO_DONE.md`). Every ⛔ was met: keep-on-doubt was *verified*, not assumed — all four readers of
  `batchPollInterrupted` were traced first, and the change is deletion-reducing on every path and adds a
  delete to none; nothing ran against a real `pending_batch.json`, because the only two new checks that write
  at the shipped journal path sit behind the same `redirectIsInForce` verdict section 16 uses; the regression
  is measured rather than claimed (revert the two assignments and 4 of the 7 new checks redden, including the
  journal file disappearing during a whole cancelled `resumeBatch` — so the **resume path is covered end to
  end**, not only the fresh run); and the premise was re-confirmed by symbol, the file having indeed moved.
  `cancel()`'s semantics were not touched and neither `W16.bat5` nor `W16.bat6` was started. One adjacent
  defect the adversarial review surfaced was FILED rather than fixed, precisely because this grant does not
  reach it: `W16.bat3-fu` (`performBatchOCR`'s *fifth* interrupted exit runs no tail at all).
  ✅ **The one LOOSER consequence was reviewed with the owner 2026-08-02 and he chose to KEEP it as shipped.**
  Where the provider confirms every server-side cancellation, the journal used to be deleted twice (the run's
  tail and `cancel()`'s async task) and now only the second does it — so a quit in the window between them can
  strand a journal for an already-cancelled batch and offer a Resume that isn't needed. He was offered the
  tightening (restore the run-tail delete) and declined: it would put a delete back on a path this grant just
  removed one from. **Do not "fix" this later as if it were an oversight** — it is the keep-on-doubt trade,
  decided twice. The grant is retained verbatim below as the record.
  **AUTHORIZED (granted 2026-08-01, daemon-report walkthrough).** Set `batchPollInterrupted` in
  both `guard !Task.isCancelled` early-returns (`OCRProcessor+OCR.swift:689`, `:701`) so `performBatchOCR:661-664`
  stops deleting the paid-batch recovery journal on a cancelled poll. Authorized because today the operator is
  told *"the paid-batch journal was kept for recovery"* while the journal is deleted anyway — the message and the
  behaviour disagree on the only path in the app that spends real money, and a live server-side batch is left
  with no local record. Pre-existing on BOTH the fresh-run and resume paths. `W16.bat3-owner-ok` is ticked and the
  item now sits in the WORK QUEUE after `W16.cfg6`.
  - ⛔ **KEEP-ON-DOUBT is the governing rule.** Deleting the journal is the irreversible act; retaining a stale
    one costs a dismissed prompt. Whenever interruption is *possible* but unconfirmed, the journal SURVIVES. If a
    fix would make deletion happen in any case it does not happen today, that is out of scope — stop and flag it.
  - ⛔ **SCRATCH ONLY.** Never point a test, a driver or a manual run at the owner's real
    `pending_batch.json`. Note `test-batch-resume.sh`'s journal path is not yet redirectable — that is exactly
    `W16.bat2-fu2`, which is a SEPARATE owner decision and NOT authorized by this grant. Until it lands, do not
    run anything that could reach the real path.
  - ⛔ **Must land with a regression test, not just a build.** `W16.bat2`'s driver
    (`BatchCancelContract` / `BatchCancelWiringContract`, `d65e04f`+) is the stated precondition and the harness:
    add a check that fails on today's code and passes after. A `cancel()`-level assertion is INSUFFICIENT — one
    already passes today while the real path deletes. Cover the resume path too, not only the fresh run.
  - Tier-2 in full: re-confirm the premise by symbol (not line — the file has moved under W16.bat1/bat2), then
    adversarial self-review. **Does NOT authorize** any other change to cancel semantics, and does not authorize
    `W16.bat5` or `W16.bat6`.
- **`W16.bat5` — ✅ DISCHARGED 2026-08-02** (the commit that ships it; full record in `SUITE_TODO_DONE.md`).
  Every ⛔ was met. **The required direction was implemented, and the rejected one was not used even as a
  fallback:** the guard is the invariant "a submit is in flight ⇒ the journal survives", evaluated
  **synchronously inside `cancel()`** from the flag that already brackets the submit loop — the journal's
  own `submissionComplete`, written `false` before the first provider create request and flipped true after
  the last. Nothing is re-read after the cancellations, and there is no suspension point between the read
  and the decision, so no TOCTOU window remains; the guard proved implementable exactly as stated, so the
  STOP-and-flag clause was never reached. Keep-on-doubt holds in the strong sense — the change is
  deletion-**reducing** on every input and adds a delete to none, its only effect being that
  `confirmed && submissionInFlight` used to delete and now keeps. SCRATCH ONLY was met by construction:
  both contracts stub the deleter and operate on a temp fixture, so no check reaches the shipped journal
  path at all. The regression is built on W16.bat2's driver and **measured** on two mutants (call site
  neutered to `false` → 7 red; rule branch killed → 15 red), with a non-vacuity twin behind every named
  check. Neither `W16.bat2-fu2`, `W16.bat6` nor any other cancel-semantics change was touched.
  ✅ **The SUPERSET consequence was reviewed with the owner 2026-08-02 and he chose to KEEP it as shipped.**
  Reusing the journal's own `submissionComplete` (rather than adding a second bool that could drift) makes the
  guard a *superset* of "a create is happening right now": a journal whose submission was never recorded as
  finished reads as in-flight for the rest of its life, including across a resume — so some Stops that used to
  delete now keep, costing one extra **Dismiss** on the Resume banner. He was offered the narrowing (scope it
  to the literal submit window) and declined, on the asymmetry: a spurious Dismiss costs a click, a wrongly
  deleted journal costs a paid batch. **Do not narrow it later as if it were an oversight** — and do not
  introduce a second in-flight flag alongside `submissionComplete`; avoiding that drift is why it was reused.
  The grant is retained verbatim below as the record.
  **AUTHORIZED (granted 2026-08-01, daemon-report walkthrough), WITH THE FIX DIRECTION CHOSEN BY
  THE OWNER: the in-flight guard.** Stop mid-submit can delete the paid-batch journal while a later Gemini chunk
  is already billed: `cancel()` snapshots `chunkIds` once (`+Pipeline.swift:1639-1640`) while the submit loop may
  still be creating server-side chunks, so if every chunk in that stale snapshot confirms, the journal is deleted
  and the later, already-paid chunk's ID is recorded nowhere. `W16.bat5-owner-ok` is ticked and the item now sits
  in the WORK QUEUE after `W16.bat3`.
  - ⛔ **REQUIRED DIRECTION — refuse to delete the journal while a submit is in flight.** The owner considered and
    **rejected** the alternative (re-reading the journal's chunk IDs after the cancellations) on the grounds that
    it only *narrows* the window: a chunk created between the re-read and the delete still slips, so it stays a
    TOCTOU race. Implement the invariant instead — a flag set before the submit loop and cleared after it, with
    "a submit is in flight ⇒ the journal survives" as the property. **Do not ship the re-read as a substitute.**
    If on reading the code the in-flight guard turns out to be unimplementable as stated, STOP and flag to
    Daemon Report with your evidence; do not silently fall back to the rejected direction.
  - ⛔ **KEEP-ON-DOUBT governs, as with `W16.bat3`.** Retaining a stale journal is cheap; deleting a live one is
    not. Any uncertainty resolves to keeping it.
  - ⛔ **SCRATCH ONLY** — never the owner's real `pending_batch.json`. The journal path is still not redirectable
    under test (that is `W16.bat2-fu2`, a SEPARATE decision, NOT granted by this entry).
  - ⛔ **Must land with a regression test** built on W16.bat2's driver: prove the invariant holds with a submit
    in flight, i.e. a check that fails on today's snapshot behaviour and passes after. Tier-2 in full, premise
    re-confirmed by symbol first. **Does NOT authorize** `W16.bat2-fu2`, `W16.bat6`, or any other cancel-semantics
    change.
- **`W16.bat7` — ✅ DISCHARGED 2026-08-03** (`f417301` production + the contract/tracker commit that follows
  it; full record in `SUITE_TODO_DONE.md`). All four exits were fixed, as granted; the completion sweep was
  extracted so the one reachable exit could be DRIVEN, and `BatchPollPersistFailureContract` (driver section
  20) forces a real write failure and pins that the real journal FILE survives on disk — non-vacuity measured
  on three mutants. The grant's honesty clause got used in the direction it was written for: the item shipped
  saying the failing branch was reachable "only in a state that could not be constructed from the current call
  graph", the adversarial pass proved otherwise, and both the withdrawn claim and the separate money bug
  behind it (**`W16.bat8`, needs the owner**) are recorded rather than quietly dropped.
  Original grant, for the record — **AUTHORIZED (granted 2026-08-02, daemon-report walkthrough), ALL FOUR
  EXITS.**
  `pollBatchUntilComplete` assigns `batchPollInterrupted = false` on entry (`+OCR.swift:711`) and four exits
  then return without touching it again — `processBatchResults` in the Anthropic (`:766`) and Mistral (`:789`)
  arms, the `materialized` half of the Gemini arm's guard (`:875`), and `handleOCRResult` in the completion
  sweep (`:955`). The caller reads "the poll finished cleanly" and then retires
  (`retirePaidBatchJournalIfPollCompleted`) or deletes (`Self.deletePendingBatch()`) the paid batch's journal.
  **The owner was shown the honest scope and granted it anyway:** the daemon had already revised this HIGH→MED
  itself, because `W16.bat3-fu` closed the dominant trigger, leaving only `handleOCRResult`'s index-bounds
  guard as concretely reachable. It is defence-in-depth, not a live money leak. Granted on the standing
  precedent that **every change to what this path deletes has been granted item by item**, not because a rule
  compelled it. `W16.bat7` is moved out of the plan's HOLD QUEUE into the WORK QUEUE.
  - ⛔ **ALL FOUR EXITS — the narrow variant was OFFERED AND DECLINED.** The owner was given the option of
    fixing only `handleOCRResult`'s bounds guard (`:955`) and documenting the other three as safe-by-upstream,
    and he rejected it: leaving three exits dependent on something upstream happening to report is the exact
    coupling that broke in `W16.bat3-fu`. **Do not ship the narrow variant as a substitute or a first
    increment.** If one of the four turns out not to need the assignment, say so with evidence rather than
    silently omitting it.
  - ⛔ **DELETION-REDUCING ONLY.** Setting `batchPollInterrupted = true` before returning must only ever cause
    a journal to be KEPT. If any reader of that flag would be made to delete something it does not delete
    today, STOP and flag to Daemon Report. Keep-on-doubt governs, as with `W16.bat3` and `W16.bat5`.
  - ⛔ **SCRATCH ONLY** — never the owner's real `pending_batch.json`. ⚠️ Unlike the 2026-08-01 grants, the
    journal path **is** redirectable under test now (`W16.bat2-fu2`, `5424054`, and `test-batch-resume.sh`
    redirects it), so the regression must drive the **REAL** deleter against a temp fixture rather than a stub.
  - ⛔ **Must land with a measured regression test**, non-vacuity proven on mutants — a check that is already
    true before the code under test runs is worse than no check on a money path (the `W16.bat3-fu` lesson,
    `12f4ce9`). **Budget for extracting a seam:** forcing a real write failure to drive these exits needs one
    that does not exist yet. Tier-2 in full, premise re-confirmed **by symbol, not line number**, first.
  - **Does NOT authorize** `W16.bat5-fu` or any other change to `cancel()` semantics — that is the separate
    grant immediately below. Do not fold the two together; different sites, different trigger.
- **`W16.bat5-fu` — AUTHORIZED (granted 2026-08-02, daemon-report walkthrough), WITH THE FIX DIRECTION
  CHOSEN BY THE OWNER: let a post-Stop chunk ID still reach the journal.**
  ✅ **DISCHARGED 2026-08-03 — shipped in the required direction, every ⛔ met.** `cancel()` keeps the journal
  addressable by IDENTITY (`ClosedPaidBatchJournalAddress`: `submittedAt` + `runFingerprint`, never a
  snapshot to write back) and a late `recordSubmittedBatchChunk` appends its ID to the file through the
  production writer. The rejected quiesce variant was not shipped and Stop still returns instantly — measured
  in the contract, not argued. Additive only: four refusals (live journal, no file, another batch's journal, a
  legacy journal) mean the file can only ever GAIN an ID. Scratch only, `BatchClosedJournalAppendContract`
  (driver §22), 360 checks ALL PASS, non-vacuity measured on nine mutants. Kept as a permanent record; see
  `SUITE_TODO_DONE.md` for the full entry. This is the acknowledged
  **residual of the direction he chose for `W16.bat5` on 2026-08-01, not a defect in it.** `W16.bat5` stops
  `cancel()` deleting the journal when a submission was unfinished, so a mid-submit Stop now leaves a local
  record and a Resume banner. But the record is **short**: a chunk created between `cancel()`'s snapshot and
  the Stop is billed, and `cancel()` has nil'd `activePendingBatch` by the time that chunk's `onJobCreated`
  callback runs, so `recordSubmittedBatchChunk` → `persistPendingBatchMutation`'s missing-journal guard
  reports the interruption and returns `false` with the ID written nowhere. The operator is warned and
  `ArchiveProcessor/README.md` points them at the provider console, but the app can neither cancel nor
  collect that job. `W16.bat5-fu` is moved out of the plan's HOLD QUEUE into the WORK QUEUE.
  - ⛔ **REQUIRED DIRECTION — keep the journal addressable for append-only chunk recording past `cancel()`**
    (e.g. `cancel()` hands the callback a direct journal handle, or the callback writes a "created after
    cancellation" ID list straight to disk) so a late `onJobCreated` can still record its ID. The owner
    considered and **rejected** the alternative of not nilling `activePendingBatch` until in-flight submits
    quiesce: it makes Stop non-instant and a hung provider request would stall the teardown. **Do not ship
    the quiesce variant as a substitute.** If the required direction turns out to be unimplementable as
    stated, STOP and flag to Daemon Report with your evidence — do not silently fall back.
  - ⛔ **STOP MUST STAY INSTANT.** The whole point of rejecting the quiesce variant is that pressing Stop
    keeps returning immediately. Any design that makes `cancel()` await a provider request violates this
    grant even if it records the ID correctly.
  - ⛔ **ADDITIVE ONLY.** The journal may only ever GAIN an ID it would otherwise have lost. No path may start
    deleting, truncating or rewriting journal state that it does not touch today.
  - ⛔ **SCRATCH ONLY** — never the owner's real `pending_batch.json`; drive the real journal writer against a
    temp fixture (redirectable since `W16.bat2-fu2`). **Must land with a measured regression test** that
    fails on today's behaviour and passes after, non-vacuity proven on mutants. Tier-2 in full, premise
    re-confirmed by symbol first.
  - **Does NOT authorize** `W16.bat7`, `W16.bat6`, or any widening of `cancel()` beyond the append path above.
- **`W23.h1`, `W23.h2`, `W23.h3`, `W23.h4`, `W23.h5` — the five HIGH findings of the 2026-07-29 Codex full-suite
  review: ALL AUTHORIZED (granted 2026-07-29).** Each would normally be hold-queue (Capture/finalize,
  destructive delete, note-file writes). The owner authorized them **as a set, item by item** — they are the
  highest-value findings in the review and every one is a *silent* failure the operator cannot currently
  detect. Full specs in `SUITE_TODO.md` §Wave 23. **Nothing below narrows the standing rules; these are
  ADDITIONAL constraints on top of them:**
  - ⛔ **SCRATCH ONLY, always.** All five touch delete/trash/overwrite paths. Never point a test at the real
    corpus, the owner's real `~/Pictures/Archive Processor Live Capture`, or the real Notes store — use
    `ARCHIVEPROC_TEST_BACKUP_ROOT` / `mktemp` fixtures. This overrides finishing the item: if you cannot test
    it on a scratch copy, STOP and flag to Daemon Report.
  - ⛔ **Tier-2 in full, per item** — adversarial self-review **plus** a scratch functional test. A clean build
    is not sufficient. **Re-confirm the premise first:** the review is static and 5 commits stale, so verify
    the defect still exists (by symbol, not line) before changing anything. If a premise does not hold, mark
    the item refuted with your evidence and move on — do **not** invent a fix for a bug that isn't there.
  - ⛔ **One item per session.** Do not batch two HIGH items, and do not "while I'm here" an adjacent one.
  - **`W23.h1` (prune) — the fix must be CONSERVATIVE.** Requiring positive session identification means the
    function deletes *less*, never more. If you are unsure whether a folder is disposable, **leave it**.
    Route every reclaim through the file's existing `trashItem` helper (Finder → Put Back), never `removeItem`.
    A prune that is too timid is a cosmetic bug; a prune that is too eager destroys captures.
  - **`W23.h5` (placeholder PDF) — do NOT delete the placeholder page.** It deliberately preserves the 2-page
    archival contract and `PDFTextExtractor`'s `pageCount>=2` heuristic. Make it *detectable* and stop
    finalize from retiring the source; per the standing W3.cap-r1 decision, the file still counts as filed.
  - **`W23.h4` (Android delete) — no emulator/device is required** to fix the guard, but if you verify on the
    emulator, never against a real phone.
  - **`W23.h2`/`W23.h3` — ~~the Notes store is the owner's real research data.~~** ⚠️ **CORRECTED 2026-08-01:
    it is NOT.** Per §STANDING PREMISE the Notes store holds only test material — the owner has produced no
    notes he intends to keep. **Keep using the scratch store anyway** (it is correct hygiene and keeps these
    tests deterministic), but understand the stake honestly: a mistake here loses test fixtures, not
    research. Do not cite "the owner's real research data" as a reason to avoid a change — if a broad
    `NotesModel` refactor is the right answer, the cost of getting it wrong is now low, and structural change
    in Notes is *actively cheap right now* (see the DEVONthink hold above). Still prefer the
    serialization/verification seam plus its test as the smaller first move.
- **`W16.bat8` — AUTHORIZED (granted 2026-08-04, daemon-report walkthrough), WITH THE FIX DIRECTION CHOSEN BY
  THE OWNER: (a) the smallest root cause.** `dismissPendingRun()` must clear the **in-memory** interrupted-run
  manifest, not only the banner and the file. Today it clears the banner while the state the banner described
  lives on, and everything downstream is that lie propagating: `startProcessing`'s recovery guard reads DISK so
  it passes, the batch branch never assigns `activePendingRun`, and because `saveResultToPendingRun` routes to
  the paid-batch journal only when `activePendingRun == nil`, every batch result lands in the pending-RUN
  manifest while `batch.completedResults` stays empty — which is exactly what `resumeBatch` keys its
  skip-what-is-done logic off, so a relaunch mid-batch re-downloads and re-materializes chunks already paid for
  and already written. Filed 2026-08-03 from the W16.bat7 adversarial pass; **pre-existing**, covered by no
  earlier grant. Note the trigger: the chain starts from a manifest **write failure**, not a Stop — `cancel()`
  does clear `activePendingRun` — which is why this was graded MED rather than urgent, and why the owner
  sequenced it after Wave 23.
  - **Two alternatives were offered and NOT taken, and that is part of the grant.** (b) Make a live paid batch
    win inside `saveResultToPendingRun` — **declined**, because it changes *which durable file a paid result
    lands in*, the category every W16 money grant has been scoped item-by-item to control. (c) Additionally make
    the routing predicate positive rather than a nil-check — **declined**, so **`activePendingRun == nil` stays
    as the routing test**. Do not "improve" it while you are in there; if you come to believe the inferential
    predicate must go, that is a new item and a new ask.
  - ⛔ **SCRATCH COPIES ONLY — never a real journal.** Recorded honestly as belt-over-braces rather than
    load-bearing: the owner asked at grant time whether constraints were needed at all, since he is not using
    the app until the current work is done, and per `CLAUDE.md` §"There is no production material yet" the
    Processor has produced no files, so there may be no real journal to protect *today*. Kept anyway for two
    reasons — it costs nothing (`test-batch-resume.sh` already redirects the journal path, per the
    `W16.bat2-fu2` discharge note above, so this only writes down what the harness does), and **a grant is a
    permanent record while "I am not using the app now" expires.** Three entries in this file already carry
    ⚠️ PREMISE VOID annotations from licences written against conditions that stopped holding; dropping a
    constraint on a premise with a shelf life is the mirror image of that.
  - ⛔ **Full Tier-2 per item, and RE-CONFIRM THE PREMISE FIRST — by symbol, not line.** The write-up is from
    2026-08-03 and the tree has moved ~45 commits since, including `W16.bat7-fu`, which superseded the
    transport-seam approach entirely (`materializePaidBatchChunk` no longer exists). If the defect has moved or
    closed, **mark the item refuted with your evidence and move on — do not invent a fix for a bug that is not
    there.** This constraint protects the *work*, not the app, and is unaffected by whether anyone is using it.
  - ⛔ **One item per session.** Do not batch this with another money-path item and do not "while I'm here" an
    adjacent one in the batch code.
  - **Not data loss — money.** Results already written stay written; the cost is paying twice. Frame the fix
    and its proof around re-spend, and do not over-correct into withholding or deleting anything.

