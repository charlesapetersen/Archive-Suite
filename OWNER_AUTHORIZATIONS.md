# Owner Authorizations — itemized exceptions to the hold queue

**This file is the authoritative, version-controlled record of what the owner has explicitly cleared the
autonomous daemon to do on otherwise-gated paths — together with the hard constraints attached to each
grant.** It is deliberately *committed*, not kept in the gitignored maintenance plan: these are the
highest-stakes decisions in the repo (money paths, destructive deletes, the cross-app SPEC), and they need
history, review and recoverability like any other durable artifact. Moved out of
`.maintenance/AUTONOMOUS_PLAN.md` on 2026-08-01 for exactly that reason — it previously existed only as a
gitignored section on a single laptop, with no record of who granted what, when, or under which constraints.

## How this file works

- **The hold-queue categories still stand in general.** This file is the ONLY place that narrows them, and it
  does so **per item, never per category**. If an item is not listed here by tag, it is still hold-queue.
  A category is never authorized wholesale.
- **An entry is a licence plus its limits.** The ⛔ constraints inside a grant are part of the grant, not
  advice. Read the entry before starting the item and obey it verbatim. If you cannot satisfy a constraint,
  STOP and flag it to Morning Review — do not proceed on a narrower reading of it.
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

*(Granted across the 2026-07-28, 2026-07-29 and 2026-08-01 Morning Review walkthroughs — each entry states
its own date. Verbatim as recorded when granted.)*

- **`W15.tu0` — AUTHORIZED to edit `SPEC/tag-format.md` (doc-only).** Add the paragraph recording that a
  `["A","A","B"]` tag array survives a `.tagNamesKey` write→read round-trip (i.e. macOS persists duplicate tag
  strings), beside the existing multiset rule. **No behaviour change, no code path altered** — the fact is
  already load-bearing and proven end-to-end by `W15.tu1`'s shipped test (`2f5c3ae`), so this only writes down
  what the suite already relies on. Also land tu0's scratch premise test. Normal Tier-2 gate still applies.
- **`R13d` — AUTHORIZED to remove the `ArchiveSuite` "Suite marker" row from `SPEC/tag-format.md`, WITH A HARD
  CONSTRAINT: do NOT strip existing stamps.** The owner chose the no-strip variant deliberately.
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
    authorized. If you believe stripping is required for correctness, STOP and flag to Morning Review instead.
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
  **AUTHORIZED (granted 2026-08-01, morning-review walkthrough), AND SEQUENCED FIRST of the
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
  reach it: `W16.bat3-fu` (`performBatchOCR`'s *fifth* interrupted exit runs no tail at all). The grant is
  retained verbatim below as the record.
  **AUTHORIZED (granted 2026-08-01, morning-review walkthrough).** Set `batchPollInterrupted` in
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
- **`W16.bat5` — AUTHORIZED (granted 2026-08-01, morning-review walkthrough), WITH THE FIX DIRECTION CHOSEN BY
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
    Morning Review with your evidence; do not silently fall back to the rejected direction.
  - ⛔ **KEEP-ON-DOUBT governs, as with `W16.bat3`.** Retaining a stale journal is cheap; deleting a live one is
    not. Any uncertainty resolves to keeping it.
  - ⛔ **SCRATCH ONLY** — never the owner's real `pending_batch.json`. The journal path is still not redirectable
    under test (that is `W16.bat2-fu2`, a SEPARATE decision, NOT granted by this entry).
  - ⛔ **Must land with a regression test** built on W16.bat2's driver: prove the invariant holds with a submit
    in flight, i.e. a check that fails on today's snapshot behaviour and passes after. Tier-2 in full, premise
    re-confirmed by symbol first. **Does NOT authorize** `W16.bat2-fu2`, `W16.bat6`, or any other cancel-semantics
    change.
- **`W23.h1`, `W23.h2`, `W23.h3`, `W23.h4`, `W23.h5` — the five HIGH findings of the 2026-07-29 Codex full-suite
  review: ALL AUTHORIZED (granted 2026-07-29).** Each would normally be hold-queue (Capture/finalize,
  destructive delete, note-file writes). The owner authorized them **as a set, item by item** — they are the
  highest-value findings in the review and every one is a *silent* failure the operator cannot currently
  detect. Full specs in `SUITE_TODO.md` §Wave 23. **Nothing below narrows the standing rules; these are
  ADDITIONAL constraints on top of them:**
  - ⛔ **SCRATCH ONLY, always.** All five touch delete/trash/overwrite paths. Never point a test at the real
    corpus, the owner's real `~/Pictures/Archive Processor Live Capture`, or the real Notes store — use
    `ARCHIVEPROC_TEST_BACKUP_ROOT` / `mktemp` fixtures. This overrides finishing the item: if you cannot test
    it on a scratch copy, STOP and flag to Morning Review.
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

