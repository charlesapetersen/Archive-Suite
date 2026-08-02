# Archive Suite — completed items

Shipped work, moved out of [`SUITE_TODO.md`](SUITE_TODO.md) on 2026-08-01 so the live queue is readable
(`execution-plans/tracker-consolidation.md`, finding F3: 47 open items were buried among 160 done ones in a
single 3,580-line file).

**This is a record, not a to-do list. Nothing here is actionable.** It is kept rather than deleted for two
reasons: the completion notes cite the commits that shipped each item, and several carry the *reasoning* for
why a later change may or may not revisit that code.

⚠️ **`ops/autonomous/next-queue-item.sh` reads this file for dependency state.** A tag it cannot find reads as
NOT done, so an item archived here would otherwise permanently block anything declaring
`(blocked-on: <that tag>)` — the dead end `W3.cap-r4` once created for `W17.stg1`. Scanned for state only;
never a source of queue candidates. **Do not rename or move this file without updating that script.**

Grouped under the `SUITE_TODO.md` section each item was completed in.


## ⭐ TOP PRIORITY — pre-flight for a 2-week unattended run (owner, 2026-07-16)

- [x] **Autonomous 2-week unattended hardening** — `execution-plans/autonomous-2wk-hardening.md` — **DONE
  2026-07-16/17** (supervised sessions, each adversarially reviewed + prove-the-mechanism'd before install).
  All workstreams shipped: **WS1** crash-restart posture (launchd KeepAlive; reboot-survival out of scope) ·
  **WS2** disk-space guard (park+alert on low free) · **WS3** worktree reclamation (safe, no unpushed-work
  loss) · **WS4** per-item attempt cap (park a mis-sized item) · **WS5** `STATUS.md` check-in digest · **WS6**
  remote push alerts · **WS7** periodic build+test+coherence health gate (park on red) · **WS8** Morning-Review
  rotation (`compact-plan.sh` Pass 2) · **WS9** `blocked-on` dependency gating (`next-queue-item.sh`) · **WS10**
  needs-owner hold queue · **WS11** paced whole-project review cadence (`next-review-unit.sh`) · **WS12**
  keychain partition-list fix. Each with a committed regression harness (`ops/autonomous/tests/prove-*.sh`).
  Out of scope (owner): reboot/auto-login, cumulative-cost ceiling.
  - [x] **2-week-readiness refinements (2026-07-20).** Two multi-day-duration fixes found in a
    pre-flight audit: (1) **WS3 worktree GC widened** — Phase-1 removal now covers all `wt/*` slugs (was only
    `wt/autonomous*`), so improvised-slug worktrees' `build/DD` no longer strands unbounded; still safe (merged
    gate + plain remove ⇒ only fully-pushed+clean worktrees reclaimed); new regression harness
    `ops/autonomous/tests/prove-housekeeping.sh` (7-case matrix, runs the real `housekeeping()`). (2) **`IDLE_STOP`
    6 h → 72 h** so a long usage-cap outage (a weekly cap can exceed the ~5 h rolling window) reads as *waiting*,
    not *idle*, and doesn't auto-park a healthy multi-day run. NOT addressed (owner, deferred 2026-07-20):
    reboot/auto-login survival.
  **Owner actions to start a long run (standing, not blocking):** run `./ops/autonomous/fix-keychain-access.sh`
  once (DONE 2026-07-17: Gemini/Anthropic/Mistral partition-listed), then `./ops/autonomous/arm.sh` (the run is
  currently DOWN; `arm.sh` now defaults to launchd KeepAlive / crash-restart — use `arm.sh nohup` only if you
  want GUI-verify).


## ⚠️ Known-issues work — Wave 23 (Codex full-suite review; owner-commissioned 2026-07-29) — TOP OF THE DRAIN

- [x] **W23.h1 — launch-time `pruneEmptySessions` recursively HARD-deletes unrecognized content under the
  visible Live Capture root, including pending relay objects [M · HIGH · data loss · no undo].** ✅ FIXED —
  conservative positive-ID prune (`isReclaimableEmptySession` + `isSessionIdName`): only an ISO-8601-named,
  spent session with no recoverable data and no unrecognized content is reclaimed; `_relay` + its pending
  objects, HEIC-/`.jpeg`-only sessions, and unknown-content folders are all kept; every reclaim routes through
  `trashOrRemove` (Trash → Put Back), never `removeItem`. Regression: `LiveCaptureRecoveryTestDriver` Test 8 /
  `scripts/test-recovery.sh` ($0, no OCR/GUI). See `ArchiveProcessor/KNOWN_ISSUES.md`.
  `Capture/CaptureSession.swift` → `pruneEmptySessions(under:)`, called unconditionally from `init()` before
  recovery. **Re-verified 2026-07-29 against `62a10d1` and it is worse than the report says:**
  1. The function treats **every** child directory of `~/Pictures/Archive Processor Live Capture/` as an app
     session. It recognizes only a **top-level `.jpg`** (`hasPhoto`) or a `pdf|jpg|jpeg|json` file directly
     inside `_processed` (`hasProcessed`). Anything else → `try? fm.removeItem(at: folder)`, a **recursive
     permanent delete**. It never positively identifies the directory as an Archive Processor session.
  2. **The relay is a direct child of the pruned root.** `CaptureSession.relayDir(token:)` defaults to
     `backupRoot.appendingPathComponent("_relay")` + `/<token>/`. So `_relay/` contains *only a nested token
     directory* — no top-level `.jpg`, no `_processed` → it reads as empty and **every pending relay object is
     hard-deleted at the next launch.** That is precisely the crash-recovery case the relay exists to survive.
  3. ⚠️ **It contradicts the Recovery Core Directive declared in the same file.** `CaptureSession` defines a
     `trashItem` helper documented as *"the app never permanently deletes an irreplaceable capture"* — and
     prune bypasses it for a raw `removeItem`. **The fix must route through `trashItem`** so anything reclaimed
     stays Finder → Put Back recoverable.
  4. Extra gap found while verifying: the top-level check accepts only `jpg`, while `_processed` accepts
     `jpeg` too. A **HEIC-only or `.jpeg`-only** operator folder is therefore also deleted.
  **Fix:** (a) require **positive session identification** (session-id name shape and/or a session marker
  file) before a folder is ever a prune candidate; (b) **hard-exclude `_relay`** and any configured
  `liveRelayDir`/`LIVECAPTURE_RELAYDIR` path; (c) treat **unknown content as non-disposable** — never delete a
  folder containing files you don't recognize (HEIC, notes, nested recovery material, an unrecognized
  journal); (d) route every reclaim through `trashItem`, never `removeItem`; (e) widen the image-extension set
  to match `_processed`. Functional test on a scratch `ARCHIVEPROC_TEST_BACKUP_ROOT` covering all five cases
  (relay dir with pending objects, HEIC-only, `.jpeg`-only, unknown-journal, genuinely-empty session).
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift | M | **high** | none
- [x] **W23.h2 — two concurrent edits to the same Notes item silently overwrite each other [M · HIGH · silent
  data loss].** ✅ FIXED — `NoteStore.withItem(_:_:)` / `withTemplate(_:_:)` make the **transaction** the unit
  of serialization: load → mutate → save runs inside ONE actor-isolated call, and because `mutate` is
  **synchronous** there is no suspension point between the read and the write, so no other transaction can
  interleave (atomicity enforced by the type system, no new lock). Returns `ItemTransaction` (the item as
  written + its fresh ref) so callers index what landed instead of re-reading. All three read-modify-write
  call sites migrated — `NotesModel.mutateItem` (date / date-uncertain / quality / body),
  `NotesModel.renameTemplate`, `ExtractBuilder.append` (async asset copies stay OUTSIDE the transaction; a
  pre-flight existence check preserves the old error path). No raw `save`/`saveTemplate` survives outside
  `NoteStore`. **Premise measured before fixing — worse than reported:** 24 concurrent same-item appends left
  **1 survivor**, and a racing body edit / date edit / extract-append each vanished **entirely**. Tier-2:
  adversarial self-review + 9 scratch fixtures (`NotesItemTransactionTests`), the 4 RED cases now GREEN
  (24/24 survive); Notes suite **530 tests / 63 suites pass**; 0 new warnings. Two residuals recorded in
  `ArchiveNotes/KNOWN_ISSUES.md` — a transiently stale FTS index row (→ **W23.h2-fu** below) and two-window
  body co-editing still last-writer-wins on the body *text* (inherent); **neither is data loss.**
  `Core/NotesModel.swift` (the body/date/quality edit paths), `Store/NoteStore.swift`,
  `Core/ExtractBuilder.swift` → `append`. Every edit is a **load-whole-item → mutate → save-whole-item** pair
  of separate actor calls. `NoteStore` serializes each *individual* call but **not the read-modify-write
  transaction**; `NotesModel` is `@MainActor` but **reentrant at every `await`**. Two tasks can both load the
  same old item, apply different edits, and save in either order — the later whole-item save silently drops
  the other's body, metadata, or source blocks. Reachable via: two windows on one item; body autosave racing
  a metadata edit; `ExtractBuilder.append` racing an ordinary mutation.
  **Fix:** make the transaction the unit of serialization — a per-item lock/serialized executor inside
  `NoteStore` that spans load→mutate→save (a `withItem(id) { mutate }` closure API), or optimistic
  concurrency (compare-and-swap on a revision/mtime, retry on conflict). Do **not** just add another `await`.
  **Not covered by W15.tu3/tu4** — those are Finder-tag metadata lost-updates, a different seam. Existing
  editor tests cover cross-item selection/autosave races, not two edits to one item; add a deterministic
  same-item race fixture. | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Core/NotesModel,Store/NoteStore,Core/ExtractBuilder}.swift | M | **high** | none
- [x] **W23.h3 — confirming a STALE folder-removal alert trashes a note that still has a valid membership
  [S–M · HIGH · destructive].** ✅ FIXED `8d68e13` (checkpoint 1/2) — the last-instance verdict is now taken
  from **the membership the removal actually applied to**, never from a bare count.
  **Premise re-confirmed empirically before fixing** and the reported two-window repro reproduced exactly: with
  note B filed only in F1, open the alert on `(B, F1)`, let the other window MOVE B from F1 to F2, then confirm
  — `membershipCount(item:) <= 1` still reads 1 (F2 exists), so the stale pair was called "last instance",
  `forceRemoveLastMembership(B, F1)` was a silent no-op, and the note was trashed **with a perfectly valid F2
  membership**. The RED fixture also showed the F2 membership row *surviving* the trash, so the organization
  graph was left pointing at a trashed note.
  Three parts: (a) `OrganizationStore.removeMembership` verifies the specific `(item, folder)` pair exists
  **first** and returns a new `.notPresent` outcome when it does not — that check is what makes the count
  meaningful, since with the pair proven present `count == 1` provably means *this* pair is the only one; it
  also closes a second, quieter lie (a stale pair with ≥2 memberships used to delete nothing and still answer
  `.removed`). (b) New `removeConfirmedLastMembership` **replaces** `forceRemoveLastMembership`, collapsing the
  confirm path into ONE store call returning `.deletedLastInstance` / `.unlinkedNotLast` / `.notPresent`:
  `NotesIndex` is an actor, so the caller's `await` between "was it the last instance?" and an unconditional
  force-remove was itself a suspension point the other window could interleave at (`@MainActor` is reentrant
  there) — the same bug one step later. Deciding *inside* the store *after* the removal closes that window, so a
  membership that appears while the DB write is in flight downgrades the outcome to `.unlinkedNotLast` and the
  file is **kept**; only `.deletedLastInstance` licenses the trash, and the unverified force-remove helper is
  gone so no caller can reintroduce it. (c) `NotesNavigationModel` treats `.notPresent` as a no-op + resync in
  both the quiet-remove and confirm paths, never as a last instance. Every failure mode now errs toward
  **keeping** the note. The batched folder-delete path was re-checked and has **no twin defect** (it already
  intersects the confirmed set with the FRESH orphan set from `deleteFolder`).
  Tier-2 (destructive seam), **scratch fixtures only** — never the owner's real store: adversarial self-review +
  1 nav-level race fixture (the RED repro above, now GREEN, asserting both that the note dir survives *and*
  that the valid F2 membership does) + 6 store-level cases covering both stale-pair variants and all three
  confirmed outcomes. Full Notes suite **540 tests / 64 suites + 189 XCTest pass**; build clean, **0 new
  warnings**. | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationStore,Core/NotesNavigationModel}.swift | S–M | **high** | none
- [x] **W23.h3-fu — a replicate can still slip a live membership onto a note already on its way to the Trash
  [S · LOW–MED · residual of W23.h3].** ✅ **DONE** — guard `f40cf47`, tests + trackers in this commit.
  Premise re-confirmed by symbol first. The guard was lifted from the preserved prototype, not redesigned,
  but three things about it had to change because they postdate it. (1) It guarded only `addMembership`;
  **`moveMembership` shipped later (W23.m13) and mints a membership too**, so a stale drag stranded one the
  same way — and worse, `move` reported **no failure at all**, so the UI said the note had moved while it went
  to the Trash. Nothing is lost by refusing it: a guarded item provably has zero memberships, so there is no
  source row to move. (2) The prototype **defined the mechanism but never wired it** — no caller ever opened a
  window. It is now held by `NotesModel.trashItems`, the hard-delete *primitive*, so both existing callers and
  any future one inherit it, and nested one level wider by each caller (`confirmDeletion`,
  `deleteFolderDeletingStranded`) so the window opens the instant the zero-memberships verdict lands rather
  than one `await` later. **That nesting is why it counts instead of flagging** — a `Bool` would let the inner
  `end` unguard while the outer window is still open. (3) It minted a second error type; the store has since
  grown `OrganizationError` for exactly this, so `itemBeingDeleted` is a case there. `replicate` now prefers
  the store's own sentence, because this change introduces a refusal a user can actually provoke.
  **Deterministic, as the item required:** the production window is sub-millisecond, so racing a confirm
  against a replicate would pass on a green run whether or not it ever landed inside the gap. A DEBUG-only
  `NotesModel.hardDeleteWindowHookForTesting` (same shape as `NotesIndex.executeForTesting`, W23.m13) is
  awaited **inside** the open window before anything is trashed, and two tests assert `isHardDeleting` from
  within the hook so a green result can't come from a replicate that never ran. **10 new tests**
  (`HardDeleteWindowTests`), scratch stores only. **Non-vacuity by 4 neuters, each reddening a disjoint set:**
  no `addMembership` guard → 5 RED, the finding test showing the exact original symptom (a live membership in
  memory *and* SQLite pointing at a trashed note); no `moveMembership` guard → 2 RED with the silent-success
  variant; refcount degraded to a flag → only the nesting test; no `defer`-ed `end` → only the balance test,
  which fails twice over because a note the disk **refused** to trash then stayed un-fileable all session.
  All reverted before shipping. **703/703** Notes tests (was 693) + 189 XCTest, clean build, 0 new warnings.
  Notes-internal — no ArchiveCore type, no SPEC change → shared-core rebuild rule N/A. No new view code; the
  only visible effect is the existing sidebar status line, asserted headlessly → nothing for the VM lane.
  **Stated plainly rather than glossed:** the two *caller-level* windows survive no neuter and cannot — the
  statements between the verdict and `trashItems`' first line are all synchronous, so no test can interleave
  there; they are defense-in-depth against a future `await` in that stretch, and what the tests pin is the
  primitive's window. Original finding follows. Filed 2026-07-30 while closing W23.h3 (`ae0e6eb`); **not** covered by
  that fix. `NotesNavigationModel.confirmDeletion` gets `.deletedLastInstance` from
  `OrganizationStore.removeConfirmedLastMembership` and then `await model.trashItems([id])`. Both are
  `@MainActor`, but **`@MainActor` is reentrant at every `await`** — the same mechanism W23.h3 itself turned on —
  so another window's drag-to-folder can run `addMembership(item:folder:)` in the gap between the verdict and
  the trash. The note is still trashed (correctly: at verdict time it genuinely had zero memberships), leaving a
  **membership row pointing at a trashed note** — the same dangling-org-graph symptom W23.h3's RED fixture
  caught, in a much smaller window. Strictly narrower than W23.h3: the trash is recoverable (§5) and the window
  is sub-millisecond, which is why it did not block that item.
  **Fix (design already prototyped — do not redesign from scratch):** a hard-delete guard on `OrganizationStore`
  — a `[UUID: Int]` refcount with `beginHardDelete` / `endHardDelete` / `isHardDeleting`, held across the whole
  confirmed delete via `defer`, with `addMembership` **refusing** a guarded item (`MembershipError
  .itemBeingDeleted`). The refcount (not a Bool) is what lets nested/overlapping guards compose. A working
  version of exactly this exists in the preserved WIP at gitignored
  `old/w23h3-stray-worktrees-20260730/suite-wt-20260730-074048-10923.patch` (an abandoned W23.h3 attempt whose
  core fix was superseded by `8d68e13`, but whose guard is additive to it) — **lift the guard, re-verify it, and
  make sure the caller balances every `begin` with an `end` on every exit path**, including the error path where
  `trashItems` fails. Needs a deterministic fixture that replicates into the gap. Tier-2 (destructive seam,
  scratch fixtures only, never the real store). | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationStore,Core/NotesNavigationModel}.swift | S | low–med | none
- [x] **W23.h4 — Android permanently deletes an un-uploaded capture with no confirmation and no upload-job
  cancel [M · HIGH · data loss · Android].** ✅ **DONE** (policy layer `9281fcb`, wiring + trackers in this
  commit). **Premise re-confirmed by symbol before fixing** (the review was 5 commits stale): `deleteItem(id)`
  ran `runCatching { items[i].file.delete() }; items.removeAt(i)` unconditionally on the third tap of the
  select → arm → delete gesture, and never touched `uploadJobs`. The upload coroutine opens the file itself
  (`item.file.readBytes()` in its own IO context), so a delete winning that race left `ok=false` and **no Mac
  copy could ever exist** — while the resulting `FAILED` state write landed on an item already gone from the
  model, so nothing surfaced the loss. iOS has had this guard since 2026-07-09; Android had none.
  All three prescribed parts landed, with the policy pulled into pure `CaptureModels.kt` seams so it is
  provable on the JVM with no device: (a) `requiresDeleteConfirmation(item)` gates an `AlertDialog` on
  anything the Mac hasn't confirmed — including an UPLOADED page with a pending metadata resend — and is
  deliberately the SAME predicate `pendingReportCount` counts (which now delegates to it), so the two can't
  drift; an already-confirmed page still deletes on the third tap. (b) `retireCapture` **cancel-AND-JOINs**
  the item's upload before the bytes go away; the `uploadJobs[id]` read and the `cancel()` share one
  main-thread turn (`viewModelScope` is `Main.immediate`), so no replacement job can slip into the gap, and a
  delete that ends up keeping the photo re-queues it via `prepareDeferredResend`. (c) the dialog's primary
  action is the **recoverable retire** — copy to Pictures/Archive Capture through the existing `PhoneBackup`,
  delete the local file only once that copy is confirmed written, and **KEEP the photo** if it fails
  (`KEPT_RETIRE_FAILED`); "Delete permanently" stays available for a genuinely bad shot.
  Tier-2, scratch only (JVM temp files — the tests cannot see a corpus, a session or the gallery):
  adversarial self-review (it caught a duplicate re-send on the keep path, fixed) + `CaptureDeletePolicyTest`,
  8 new cases. The cancel-and-join case is proven **non-vacuous** — swapping `cancelAndJoin()` for a bare
  `cancel()` turns it RED, GREEN with the join. Android unit suite **25/25**; `assembleDebug` +
  `testDebugUnitTest` BUILD SUCCESSFUL, **0 warnings**. No device/emulator needed or used. Full write-up:
  `ArchiveProcessor/KNOWN_ISSUES.md`. W23.m1 is a separate finding on the same file and stays open.
  | files: ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/{ui/CaptureScreen,capture/{CaptureViewModel,CaptureModels}}.kt + app/src/test/.../CaptureDeletePolicyTest.kt | M | **high** | none
- [x] **W23.h5 — a placeholder-only PDF counts as successfully archived, and finalize then retires the source
  image [M · HIGH · data loss · tag/PDF SPEC-adjacent].** ✅ FIXED — the placeholder substitution is now an
  explicit, propagated outcome instead of a silent success. `PDFGenerator.generate` returns
  `ImagePageOutcome` (`.embedded`/`.placeholder`, `@discardableResult` so the five Process Files call sites
  are untouched — their `try?` swallowing stays W23.m5); `writeSegmentFiles` records the affected **source
  URLs** on the new `StagedSegment.placeholderSources` (a `nil` outcome — threw but still left a file —
  counts as placeholder, so unknown resolves toward keeping the photo); and `finalize` runs its deletion set
  through the new pure `sourcesSafeToRetire(...)`, AND-ing the new gate with the existing filed gate. Per the
  owner's constraint the **placeholder page stays** and the file **still counts as filed** — only the source
  deletion is withheld, and **per page**, so a sibling that embedded fine is still retired. Newly VISIBLE
  where it was silent: `Phase.succeededPlaceholderImage` → amber `ItemState.succeededPlaceholderImage` (row
  explanation + retry/rotate actions) and a finalize-summary warning naming how many photos were kept and
  why. Legacy manifests (no `placeholderSources`) behave exactly as before; the rotation-review regeneration
  path replaces the whole segment, so the flag self-heals on a successful retry. Tier-2: `test-recovery.sh`
  Tests 9–11 (detect · gate · wiring end-to-end) → **45/45 ALL PASS**, both halves proven non-vacuous by
  neutering (gate off → 5 RED; detection off → 2 RED; the regression cases stay GREEN in both);
  `test-merge-safety.sh` + `test-output-file-safety.sh` clean; build clean, **0 new warnings**. $0 — no OCR,
  network, device or GUI. Full write-up: `ArchiveProcessor/KNOWN_ISSUES.md`.
  Original finding — `OCR/PDFGenerator.swift` → `generate(...)`;
  `Capture/LiveCaptureProcessor.swift` (filed-set + finalize); `Capture/CaptureSession.swift`.
  **Re-verified verbatim 2026-07-29:** when `makeImagePage` returns nil, `generate` inserts
  `makePlaceholderImagePage(note: "Original image could not be embedded (…)")` and **returns normally** — a
  successfully-written 2-page PDF whose image page contains **no scan**. Live Capture treats the PDF's
  existence as a complete page, includes it in the filed set, and **finalization moves the corresponding raw
  capture to Trash / drops it from the active session.** A source that becomes unreadable after OCR, or is
  regenerated from a cached OCR result after its bytes go corrupt/unsupported, therefore yields an apparently
  filed archival document with no image — **and the recovery source is retired.** Output-content validity is
  never established.
  ⚠️ The placeholder itself is deliberate (it keeps the 2-page contract + `PDFTextExtractor`'s `pageCount>=2`
  heuristic valid) — **do not delete it.** The defect is that it is **indistinguishable from success** to
  every caller.
  **Fix:** make placeholder-substitution an explicit, propagated outcome — have `generate` return/throw a
  result that says *"image page is a placeholder"*, thread it to the filed-set decision, and make finalize
  **never retire a source whose PDF carries a placeholder image page** (surface it instead, as W3.cap-r1 does
  for tags: still count the bytes, but do not destroy the original). **Not covered by W17.stg1** (that is
  staging-manifest integrity, not per-PDF content validity); the closed immutable-generation proposal does not
  address malformed bytes.
  💡 **PRIOR ART EXISTS — read it before designing the fix (found 2026-07-29).** A 2026-07-17 Codex worktree,
  removed on 2026-07-29 but preserved, already implements essentially the fix described above: a
  `PDFGenerator.generateRequiringEmbeddedImage()` overload plus `PDFError.imageEmbeddingFailed(URL)`, which
  **keeps** the deliberate placeholder for Process Files but makes the **Live Capture** path *throw* instead of
  emitting a placeholder-only PDF that finalize would treat as grounds to retire the raw source. Two copies,
  neither on `main`: branch **`wt/codex-processor-bugfixes-20260712`** and the patch series
  `old/codex-processor-fixes-20260717/` (gitignored). ⚠️ It is **76 commits behind** and predates W16.cfg1–cfg5,
  which rewrote these files — **re-derive against current `main`, do not merge or cherry-pick it blind.** Treat
  it as a design reference that a second author already reached the same conclusion, not as a tested patch.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/{OCR/PDFGenerator,Capture/LiveCaptureProcessor,Capture/CaptureSession}.swift | M | **high** | none
- [x] **W23.m1 — re-pairing Capture leaves an upload owned by the OLD Mac; the phone copy is deleted on the
  wrong acknowledgement [M · MED · misroute · Android].** ✅ FIXED — endpoint identity is now **generational**,
  exactly as prescribed (policy layer `f8d35fa`). Premise re-confirmed by symbol first, against `b31aa03`:
  `enqueueUpload` captures `val c = client` for the whole send, `disconnect()` touched neither `uploadJobs`
  nor `inFlightUploads`, so a re-pair left `resumeUploads()`'s re-enqueue a **no-op** (the stale in-flight id)
  while the orphaned coroutine kept uploading to the old Mac — and any `ok` it returned ran the unconditional
  confirm path (`UPLOADED` → `sentCount` → `delay(650); removeConfirmed`), deleting the phone's copy of a page
  the newly paired Mac never received. `trySendSegmentComplete` had the same hole (`endedSegments.remove` on
  any `ok`), so the new Mac never heard of the document at all.
  New pure layer in `CaptureModels.kt`: **`PairingGeneration`** (a token rotated by every pair *and* unpair via
  `retirePreviousPairing()`, which also cancels the outstanding upload/segment jobs — best-effort, since a POST
  already on the wire finishes, which is precisely why the *generation check* is what makes this safe);
  **`OutstandingSends<K>`** (the in-flight guard, generation-stamped — `claim` still refuses a second send for
  a key **even across a re-pair**, preserving W23.h4's one-coroutine-per-file invariant that the delete join
  depends on, and `release` frees only the caller's OWN claim so a dead send can't free the live one's); and
  **`sendAck(ok, tokenIsCurrent)`** — the ownership rule in ONE place, shared by both kinds of send so they
  can't drift, with staleness outranking success. The upload handler bails out **before** `setState(UPLOADED)`
  (so a crash in that window can't persist a false confirmation either) and its `finally` returns the page to
  the queue via `markSendableAgain` (PENDING, marker cleared, heartbeat re-counted) for the endpoint paired
  now. Absent a re-pair the decisions are bit-for-bit the old ones.
  Tier-2, scratch only (JVM temp files): `CapturePairingGenerationTest`, 8 cases incl. a coroutine driver that
  runs the shipped objects through the real misroute sequence and asserts the phone copy survives, the page
  re-queues, and the NEW Mac then receives it; **non-vacuous** — dropping `sendAck`'s staleness arm turns 4 of
  the 8 RED, the driver among them. Android **33/33** (was 25), `assembleDebug` + `testDebugUnitTest` clean,
  **0 warnings**, no device/emulator. Full write-up: `ArchiveProcessor/KNOWN_ISSUES.md`.
  **iOS twin recorded as PARKED, not fixed** (verified still present by symbol:
  `ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift` `disconnect()` nils `endpoint`/`client` and leaves
  `inFlightUploads` + the upload task alone). Also deliberately left alone: the display-only status heartbeat
  can still deliver one conflated count to the Mac just unpaired from (no bytes, no deletion licensed).
  | files: ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/{CaptureViewModel,CaptureModels}.kt + app/src/test/.../CapturePairingGenerationTest.kt | M | med | none
- [x] **W23.m2 — Reader cannot display or find page 3+ of Processor's intentional merged-PDF format
  [M · MED · CROSS-APP].** ✅ DONE `2689739` (model + find seam) + this commit (functional gate). Premise
  re-confirmed by symbol first — all three defects were live: `imagePage`/`textPage` were `page(at: 0)`/
  `page(at: 1)`, `next()`/`previous()` stepped file URLs, and `DocumentFindScanner` had a literal
  `default: break` on page index ≥ 2. Fixed with a **page-pair** model: new pure `Core/DocumentPagePairs`
  (pair `p` = PDF page `2p` image + `2p+1` OCR text) is the ONE home for that arithmetic, shared by the
  viewer and the find scanner so they can't drift; `pairCount` rounds **up** so a merge of a 2-page doc and a
  bare scan doesn't lose the trailing scan. `DocumentViewerModel` publishes `pair` — cycling walks pairs then
  files (backwards lands on the previous document's LAST pair), `canGoNext`/`canGoPrevious` gate the buttons,
  `positionLabel` adds "· page 2 of 4" only when there is more than one pair (single-pair documents keep the
  original string), and `DocumentFindScanner.pairMatchCounts` buckets every page so `FindNavigator` addresses
  a match by `(doc, pair, pane)` and `applyCurrentMatch` moves the viewer to it. Both viewers now key their
  panes on `pageIdentity` (index+pair) — **required, not cosmetic**: `PDFPaneView`'s reuse fallback compares
  `page.string`, which is nil for both an old and a new *image* page, so a file-index-only `.id` would leave
  the previous scan on screen; `PreviewSheet` had no `.id` at all, so that latent cycling bug is closed too.
  No SPEC change — the SPEC already documented the interleaved variant and the no-2-page-assumption rule;
  this is Reader conforming. `copyArchivePageLink` now names the pair on screen instead of a hardcoded page 1
  (so making pairs reachable doesn't create a NEW wrongness); the focused-pane refinement stays **W23.m4**.
  Tier-2: adversarial self-review (clamped `setPair` for a short/failed load, guarded every `page(at:)`,
  checked `index(for:)`'s NSNotFound path, kept keyboard focus off a non-existent text pane) + 25 functional
  tests on **scratch `mktemp` PDFs only** — 11 new `DocumentViewerPagePairTests` driving the real model over
  real on-disk PDFs, incl. a **pixel render guard** (pair 1's image page rasterizes non-blank AND differs from
  pair 0's, so a non-nil-but-blank `PDFPage` can't pass) and find end-to-end onto page 5. **Non-vacuous, per
  half:** neutering the display half → 4 test cases RED; neutering the find half back to `default: break` →
  3 RED. Reader unit suite **230 tests, 1 failure** = the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot`
  environment artifact (queued as `W20.deeplink-isolation`), unrelated. Clean build, **0 new warnings**, and
  **15/15 Reader UITests pass in the headless Tart VM** (incl. the 5 `ViewerUITests`) — off the owner's screen.
  Full write-up: `ArchiveReader/KNOWN_ISSUES.md`.
  Original report: Processor merges multi-page documents as `image1, text1, image2, text2, …`
  (`OCR/PDFGenerator.swift` merge path; `OCR/OCRProcessor+Tagging.swift` transfers Finder tags to the merged
  PDF), but Reader exposes **only PDF pages 0 and 1**: `Views/DocumentViewerModel.swift` hard-pairs two pages,
  next/previous move between **selected file URLs** rather than internal page pairs, and
  `Core/DocumentFind.swift` **explicitly discards every match on PDF page index ≥ 2**. So for any merged
  document with 2+ source pages, later scans and their OCR text are unreachable in Reader — even though
  Reader's full-text index already extracts all pages.
  **Fix:** teach Reader the interleaved image/text **page-pair** model — derive pair count from
  `pageCount / 2`, make next/previous walk pairs within a document before moving to the next file, and let
  Find return matches on any text page (mapping match → pair). **`SPEC/tag-format.md` says consumers must not
  hard-assume two pages** — this is that assumption. Distinct from **W18** (switching between PDF and
  separately exported JPEG references). | files: ArchiveReader/macOS/Sources/ArchiveReader/{Views/DocumentViewerModel,Core/DocumentFind}.swift | M | med | none
- [x] **W23.m3 — Notes inline-image resolution escapes the item directory and reads another item's asset
  [S–M · MED · provenance corruption].** ✅ DONE `6e72d33` (resolver + its tests) + this commit (wiring +
  read-seam gate). Premise re-confirmed by symbol first, and both defects were live: `ItemAssetStore.resolveAsset`
  and `ScratchAssetStore.resolveAsset` each did `appendingPathComponent(relativePath)` + `fileExists`, and a
  scratch fixture proved `../<OTHER_UUID>/assets/private.png` really did return the other item's bytes.
  Fixed with a new single choke point, `Editor/AssetPathResolver.swift`, returning a typed `AssetResolution`
  (`resolved` / `missing` / `outOfBounds`) instead of a bare optional URL, behind **two** gates: (1) syntactic —
  `assets/`-rooted, no `..`, not absolute/`~`/remote, which catches the reported traversal with no disk access;
  (2) canonical containment — `resolvingSymlinksInPath()` + **component-wise** ancestry, which catches a symlink
  *inside* `assets/` (invisible to every string check, since `fileExists` follows symlinks and
  `standardizedFileURL` does not resolve them) and the `assets-elsewhere/` string-prefix trap. `resolved` carries
  the **canonical** URL, so the byte read follows the already-resolved target (a later symlink swap at the
  original path can't redirect it) — and that canonical URL is exactly the cache key **W23.m11** now needs.
  `EditorAssetStore` requires `resolve` (both stores wired); `resolveAsset` survives as a protocol-extension
  convenience so a refusal reads as nil on the copy/extract path — an extract embeds no foreign bytes, which is
  the provenance half of the finding (`snapshotMarkdown` re-keys assets by *bare filename*). The renderer shows
  a refused reference as a distinct **"Blocked"** placeholder (vs "Missing"), rel-path preserved, so serializing
  never rewrites the note body. Tier-2 gate, scratch fixtures only: **19 new tests** (`AssetPathResolverTests`
  11 + `InlineImageReadSeamTests` 8) — every escape case first asserts the bytes ARE reachable under the old
  rule, so each test documents the hole it closes; 559/559 `ArchiveNotesTests` green, no new warnings.
  Consequence recorded in `ArchiveNotes/KNOWN_ISSUES.md`: a hand-authored ref *outside* `assets/` (item-root, or
  `Assets/` mis-cased) now renders Blocked rather than loading — deliberate per this item's fix spec, and
  recoverable (move the file into `assets/`; nothing is rewritten).
  `Editor/MarkdownBridge.swift`, `Editor/InlineImageAttachment.swift`,
  `Core/NotePassageSource.swift` → `ItemAssetStore.resolveAsset`. Markdown image paths are passed **unchanged**
  to `resolveAsset`, which appends the value to the item directory and only checks that the result **exists**
  — no `assets/` restriction, no component-boundary check, no canonical/symlink containment check. A raw or
  synced note containing `![](../OTHER_UUID/assets/private.png)` renders **another note's image**; more `..`
  components leave `items/` wherever the sandbox grant permits. Copy/extract code can then snapshot those
  bytes into a different item — **corrupting provenance**, not just the visual boundary.
  **Fix:** resolve then **canonically contain** — reject any path escaping `<item>/assets/` after
  `resolvingSymlinksInPath` + component check; return a typed "out of bounds" result the renderer shows as a
  broken image. Existing Notes asset items cover async write failure + same-name write reservation; the
  path-traversal tests protect the **write** seam — this is the **read** seam. Add read-seam tests.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Editor/MarkdownBridge,Editor/InlineImageAttachment,Core/NotePassageSource}.swift | S–M | med | none
- [x] **W23.m4 — Reader page-level durable links are broken at command, creation AND reveal time
  [M · MED · shipped-contract regression].** ✅ DONE `b6093bb` (the three fixes) + `e150234` (18 functional
  tests) + this commit (GUI proof + trackers). Premise re-confirmed by symbol first — all three were live:
  the command's `.disabled(doc == nil || nav == nil)` against a document window that publishes only its
  viewer; `page = imagePageIndex(pair:) + 1` regardless of the focused pane; and `pendingRevealPage`
  written in `revealAndSelect` and **read nowhere** (its only other mentions cleared it).
  Fixed as one seam, since fixing any one alone leaves the feature broken: new `Core/ArchiveLinkTarget.swift`
  carries the root + marker as one `Sendable` value published as a **focused value** by every window that
  shows a document, with an app-level `ArchiveLinkContext` (one `@StateObject`, injected into both scenes)
  ferrying it out of the navigation window — which stays the single writer (`attach(linkContext:)` + a
  `rootStore.objectWillChange` sink), so a root switch can't leave a document window citing the old archive;
  `DocumentViewerModel.focusedPageNumber` cites the **focused** pane's page (degrading to the pair's image
  page when that pane holds none); and `goToPDFPage(_:)` + an additive optional `DocumentSelection.initialPage`
  + `openViewerRequest`/`openViewerSelection` (counter+payload, in the shape of `requestScroll`, since
  `openWindow` is an Environment action only a View holds) make reveal open the viewer ON the cited page
  before clearing the pending state. A link with **no** page still just selects and scrolls.
  Tier-2: adversarial self-review (clamped/out-of-range pages, a cited text page that no longer exists, a
  marker-less root clearing rather than staling the target, no link at all with no document loaded) + **18
  functional tests** (`DocumentPageLinkTests`) driving the real models over real `mktemp` scratch PDFs, incl.
  the full copy → parse → reopen → re-cite round trip and the whole URL → router → nav path. **Non-vacuous,
  per defect:** restoring the image-page-always rule → 3 cases RED; removing the reveal request and pinning
  `goToPDFPage` to pair 0 → 7 RED (the three absence tests correctly stay GREEN). Reader unit suite
  **248 tests, 1 failure** = the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot` environment artifact
  (`W20.deeplink-isolation`), unrelated. Clean build, **0 new warnings**. The menu-enablement half is the one
  thing no unit test can see, so it is covered by a new `ViewerUITests` case that opens a document window and
  asserts the Document-menu item is present AND enabled with only the viewer focused: **16/16 Reader UITests
  pass in the headless Tart VM** (off the owner's screen). That needed `make-gui-fixture.sh` to write a
  `.archive-suite-root.json` marker — without one no durable link exists, so every archive-link command stays
  disabled and the GUI lane could not test them at all.
  Full write-up: `ArchiveReader/KNOWN_ISSUES.md`.
  Original report: three independent defects break the feature end to end:
  1. **Unreachable command.** "Copy Archive Link to This Page" (`ArchiveReaderCommands.swift`) requires both a
     focused `NavigationModel` **and** `DocumentViewerModel`. The full document window
     (`Views/DocumentWindowView.swift`) publishes **only the viewer**, so the command is disabled exactly where
     the user reads a document; it may only be reachable inside the navigation window's `PreviewSheet`.
  2. **Wrong page written.** Direct invocation always writes `page=1` regardless of the focused text/image pane.
  3. **Reveal drops the page.** An incoming link stores `page` in `pendingRevealPage`
     (`Views/NavigationModel.swift`), then **clears it after selecting a row** without ever opening the viewer
     or navigating to that page.
  **Fix all three together** (fixing one alone leaves the feature broken): give the command a viewer-only
  focus path, pass the actually-focused pane's page, and make reveal open the viewer + navigate before
  clearing `pendingRevealPage`. `execution-plans/archive-notes/00-overview.md` §"reveal" is the **shipped
  contract** requiring the page be passed to reveal — this is an implementation regression against it. Not
  W20 (test isolation), not W18 (dual reference).
  | files: ArchiveReader/macOS/Sources/ArchiveReader/{ArchiveReaderCommands,Views/NavigationWindowView,Views/PreviewSheet,Views/DocumentWindowView,Views/DocumentViewerModel,Views/NavigationModel}.swift | M | med | none
- [x] **W23.m5 — Process Files reports Finder tags as applied after silently discarding tag-write failures
  [M · MED · tag/PDF SPEC].** ✅ DONE `ff792a9` (the seam + all 13 sites + surfacing) + `088df94` (the $0
  functional test) + `4cf1fb7` (re-key to the input file) + this commit (adversarial-review fixes +
  trackers) — **W23.h5-fu folded in**, as its entry required. Every Process Files tag write now goes
  through one seam, `OCRProcessor.writeOutputTags`, which RETURNS whether the write landed; the run
  records the verdict against the INPUT file and the "Done." status line + batch log say so. Reuses
  W3.cap-r1's mechanism rather than adding a second warning channel. 13 sites, not the 9 recorded:
  `+Tagging` ×6, `+OCR` ×2, `+Pipeline` ×1 as filed, plus the 4 in `+ReviewFlows` (reclassification ×3 +
  the copy-source restore after rotation regen) — leaving those unrouted would have made the new summary
  trustworthy and wrong. The file still counts as processed (the owner's 2026-07-18 decision); only the
  silence was the bug. Keyed by SOURCE because `organizeOutput` MOVES **and RENUMBERS** every output
  (`00003 Box 12.pdf`), so an output name recorded during the run names a file that no longer exists by
  summary time. Self-healing: a later successful re-write clears the entry, but a step that ATTEMPTS no
  write (a post-run `retryOne`, which regenerates the PDF and does not re-tag it) does not.
  Tier-2: `scripts/test-processfiles-tagwarn.sh` + `ProcessFilesTagWarningTestDriver`, 35 $0 checks
  (`chflags uchg` makes the tagger genuinely fail; a real production site proves the WIRING; the summary
  copy, merge bookkeeping and the h5-fu placeholder path are all driven end to end). Proven non-vacuous
  by four separate neuters, each turning exactly the expected checks RED. Six sibling regressions green.
  Build clean, 0 new warnings. Residual colour-detection finding filed as **W23.m5-fu**.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor{,+Tagging,+OCR,+Pipeline,+ReviewFlows}.swift, Capture/ProcessFilesTagWarningTestDriver.swift, scripts/test-processfiles-tagwarn.sh | M | med | none
- [x] **W23.m5-fu — two read-append-rewrite tag sites still infer the Finder colour from the tag text
  [XS–S · LOW · misfile].** ✅ DONE this commit (checkpoint `5342d2b` code+tests). Found 2026-07-31 while fixing W23.m5 (the audit of the sites it rewrote, not
  a new review). `applyCapturePriorityTags` and `exportOriginalImages` both READ a PDF's tags back off
  disk and re-apply them as a raw `[String]`, so `MacOSTagger` runs its Red/Purple DETECTION over the
  array — the same defect W3.cap-r1 fixed on the Live Capture staging path and KNOWN_ISSUES #5 fixed on
  the batch merge path. A document whose subject tag is literally "Red" (the Red Scare, the Red Cross)
  therefore gets Finder label 6 on the rewrite and loses "Red" as a searchable subject; the Reader reads
  a red label as a **box** photo, so an ordinary document is mis-parsed as archival structure.
  **Deliberately left in W23.m5** (which is about discarded write failures, and passed these two sites
  through unchanged so it could not alter what anyone writes) — and the fix is NOT simply flipping
  `colorIsAuthoritative`: with `appColor: nil` that would STRIP the label from every genuine box/folder
  PDF. Do what `performDocumentMerging` already does: derive the colour from the job's
  `classification` (`.boxLabel` → "Red", `.folderLabel` → "Purple", else nil) and pass it explicitly.
  Both sites iterate `jobs`, so the classification is already in hand. Test: extend
  `scripts/test-processfiles-tagwarn.sh` — a "Red"-subject document keeps the tag and takes no label
  through a rewrite; a box PDF still reads label 6 afterwards.
  **Shipped exactly that, via one seam.** New `OCRProcessor.authoritativeColor(for:)` states the rule in
  one place — box → Red, folder → Purple, anything else → no colour — and both sites now pass its result
  with `colorIsAuthoritative: true`. The `forJob:` overload coalesces `job.classification ??
  job.result?.classification`: every writer keeps the two in sync, but a failed re-OCR can blank the
  result's copy, and falling back to "no colour" is precisely the strip this item warned about. Checked
  the invariant that makes classification trustworthy here rather than assuming it: `preGroupedPriorities`
  is cleared whenever the boundary count mismatches, so a phone priority implies
  `applyPreGroupedClassifications` ran (it sets BOTH fields) and every such job carries a classification.
  Copy-source mode is untouched by construction — `applyTags` passes names through verbatim and never
  writes a label there, so the colour argument is dead in that mode.
  **One correction to this entry's own text, found by driving it:** the subject tag "Red" was **not**
  lost. Detection moves it to the front of the array and re-adds it, so it stayed searchable; the defect
  is the Finder **label** alone (and the Reader's box mis-read that follows from it). The neutered run
  confirms it — with the old code restored, "…and 'Red' is still a searchable subject tag" PASSES while
  only the label checks go RED.
  Tier-2, scratch only: 12 new checks in `ProcessFilesTagWarningTestDriver` (**47 total, ALL PASS**),
  synthetic files in a temp dir — no corpus, no OCR, no network, no GUI, $0. Both REAL production
  functions are driven (`applyCapturePriorityTags`, `exportOriginalImages`), not just the seam, and both
  directions are covered on both sites: a "Red"-subject document takes no label, a box PDF keeps label 6,
  a folder's exported image keeps label 3. **Non-vacuous by two neuters, each reddening exactly the
  expected pair:** restoring detection at both sites → the two "subject Red must not become a label"
  checks RED (this IS the premise re-confirmation, since that is the pre-fix code); the naive
  `appColor: nil` variant → the two "a genuine box/folder KEEPS its label" checks RED. Build clean, 0 new
  warnings; seven sibling regressions green (merge-safety, collection-organize, recovery, batch-resume,
  multipage-reocr, segment-json, output-file-safety). Processor-internal — nothing in ArchiveCore
  changed, so the all-three-app rebuild rule is N/A; no view code, nothing for the VM lane to see.
  **Adjacent finding, filed then fixed the next session: W23.m5-fu2** (below) — the reclassification re-tag in
  `+ReviewFlows` strips the literal words "Red"/"Purple"/"Box"/"Folder" from the tag array, which for a
  document whose SUBJECT is one of those words really does delete it. Different site, different
  mechanism, out of this item's two-site scope.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+Tagging.swift, Capture/ProcessFilesTagWarningTestDriver.swift | XS–S | low | W23.m5
- [x] **W23.m5-fu2 — reclassifying a document DELETES a subject tag that happens to be a structure word
  [XS · LOW · tag loss].** ✅ DONE this commit (checkpoint `7a0043c` = the rule + its checks). Found
  2026-07-31 while fixing W23.m5-fu (audit of the neighbouring rewrite sites, not a new review).
  `OCRProcessor+ReviewFlows` re-tags an output whenever the operator changes its classification, and
  rebuilt the array with `existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" ||
  $0 == "Folder" }` before appending the new classification's words. The intent is right — drop the OLD
  structure tags so they can be replaced — but the filter matched on the literal word, so a document
  whose genuine subject tag is "Red" (Red Scare/Red Cross), "Box" (a ballot box file) or "Folder" lost
  it from both the file and `jobs[].appliedTags`, and it never came back. Tag loss, not misfile — the
  mirror image of m5-fu.
  Two new seams beside `authoritativeColor(for:)`: **`structureTag(for:)`** (box→"Box", folder→"Folder",
  else nil — the companion of the colour, so between them they are the complete set a classification
  contributes and therefore the complete set a *re*-classification may take back) and
  **`reclassifiedTags(_:from:to:)`** — remove ONE occurrence of each word the app added for the OLD
  classification, then add exactly one of each for the NEW one in the fresh `GeneratedTags` shape
  (subject word first, colour last). One app copy in, one app copy out, so box → folder → box neither
  piles up duplicates nor eats the operator's own tag.
  **Three things the item did not say, each checked rather than assumed:** (1) **there are THREE sites,
  not two** — `applyReviewEdits`, `updateClassification` and `applyDocumentReviewEdits`, the last of
  which also re-added unguarded, so it could double a word. (2) **The strip fix alone would have
  re-introduced W23.m5-fu's misfile.** All three called `tagOutput` with the DEFAULT
  `colorIsAuthoritative: false`, so `MacOSTagger`'s raw-array detection ran over the array; the item's
  claim that "the Finder LABEL is correct here" held *only because* the strip deleted the operator's
  "Red" first. The moment a subject "Red" survives, detection promotes it back to Finder label 6 — which
  the Reader reads as a box photo. So both halves ship together, exactly as in m5-fu: every site now also
  passes `appColor: authoritativeColor(for: newClassification), colorIsAuthoritative: true`. (3) **which
  field the strip reads matters** — all three read `jobs[].classification` alone, so a page carrying its
  classification only on `result` would have had nothing stripped and kept the app's own "Box"/"Red"
  forever (the same tag rot, other direction). New `taggedClassification(of:)` coalesces both fields, as
  `authoritativeColor(forJob:)` already did.
  **Tier-2, scratch only** (synthetic files in a temp dir; no corpus, no OCR, no network, no GUI, $0):
  27 new checks in `ProcessFilesTagWarningTestDriver` (§8a the rule, §8b all three REAL production
  functions against real files on disk), **74 total ALL PASS**. **Non-vacuous by three neuters, each
  reddening exactly the predicted set and nothing else**: the literal-word `removeAll` restored → 10 RED
  (this is also the premise re-confirmation, being the pre-fix code); `colorIsAuthoritative: false` →
  3 RED, proving the colour half is load-bearing; `taggedClassification` de-coalesced → 2 RED.
  `grep NEUTER` clean before shipping. Build clean, 0 new warnings; six sibling regressions green
  (merge-safety, collection-organize, recovery, batch-resume, multipage-reocr, output-file-safety).
  Processor-internal — nothing in ArchiveCore changed, so the all-three-app rebuild rule is N/A; no view
  code, nothing for the VM lane to see. `applyReviewEdits` / `applyDocumentReviewEdits` went from
  `private` to internal so the headless driver can exercise the real sites; the UI still reaches them
  only through `confirmCollectionReview` / `confirmDocumentReview`.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+ReviewFlows.swift, OCR/OCRProcessor+Tagging.swift, Capture/ProcessFilesTagWarningTestDriver.swift | XS | low | none
- [x] **W23.m6 — Reader can emit durable links carrying a root GUID that was never persisted
  [S–M · MED · broken citations · SHARED CORE].** ✅ DONE `fa8bc02` (ArchiveCore) + `1e0af47` (Reader) + this
  commit (all-three-app rebuild, GUI proof, trackers) — **W23.l3 folded in.** `read` now reports absence *only* for ENOENT
  (new `.unreadable` otherwise), `ensure` throws `.readOnly` (carrying the `provisional` marker) instead of
  returning an in-memory GUID, and first-time creation re-checks/writes/confirms inside **one** write claim.
  Reader mints only from a **durable** identity — `RootFolderStore.rootMarker` is derived from the new
  `Core/RootMarkerState.swift`, so every link path refuses together — and degrades **visibly** with four
  distinguishable reasons instead of "Choose an archive folder first." on an open folder. 5 ArchiveCore + 8
  Reader functional tests, each defect proven live by neutering (the concurrency fixture reproduces l3: 8
  racers, 8 GUIDs, one on disk, 3/3 runs). All three apps rebuilt (shared-core rule). `packages/ArchiveCore/.../Links/RootMarker.swift` →
  `read` / `ensure`; `ArchiveReader/.../Search/RootFolderStore.swift`; `Views/NavigationModel.swift`.
  `RootMarker.read` converts **every** non-ENOENT, non-decoding read failure into "marker absent", and
  `ensure` returns its **newly generated in-memory marker after any write failure or failed confirmation**.
  Reader accepts that as a normal `rootMarker` and mints archive links from it. On a read-only root, disk-full,
  permission failure, or transient marker I/O error, copied links carry a GUID that **changes after relaunch
  and can never resolve** — and a transient read error on an *existing* marker can be mistaken for absence
  before a replacement write. The declared `RootMarkerError.readOnly` is **never used**.
  **Fix:** distinguish *absent* from *unreadable* (propagate the real error; use `.readOnly`), and make
  `ensure` return a **provisional/non-durable** marker that Reader must **refuse to mint links from** —
  degrade visibly instead. ⚠️ **Shared-Core rule** (memory `shared-core-change-rebuild-all-apps`):
  `RootMarker` is ArchiveCore — build+test **all three** app bundles plus `swift test` in
  `packages/ArchiveCore`. Historical W4 material calls read-only operation "degraded" but no live task makes
  Reader distinguish transient from durable. | files: packages/ArchiveCore/Sources/ArchiveCore/Links/RootMarker.swift, ArchiveReader/macOS/Sources/ArchiveReader/{Search/RootFolderStore,Views/NavigationModel}.swift | S–M | med | none
- [x] **W23.m7 — Mac tag-card Apply/Skip begins finalization before proving the manifest decision is durable
  [S–M · MED · manifest/finalize].** ✅ DONE `1723331` (the fix) + `0bd8fcc` (18 headless checks) + this
  commit (trackers). Premise re-confirmed by symbol first and it was live, both halves: `_ = writeManifest()`
  at both sites, and `liveProcessor.segmentResolved` called BEFORE that write. Fixed by the neighbouring
  roll-back pattern, re-derived against current `main` (the Codex prior art was read for shape, not
  cherry-picked): both functions now stage the decision, write, and on failure restore
  `macTags`/`resolvedGroupIds` and return `false` — so memory matches disk and the card (derived from the
  in-memory resolved set) stays up with everything typed still in it. Live processing is told through one new
  choke point, `notifySegmentResolved`, reached only after the write succeeds, because that step bakes
  `macTags` into staged output. Failure channel: one shared `CaptureSession.tagDecisionNotDurableMessage`
  drives both the session status line and a new inline red row in the card, so Save/Skip can never again look
  like a no-op. The headless auto-skip loop now stops on a refused write (it would otherwise spin forever on a
  card that rolls itself back). Tier-2: adversarial self-review (found + fixed a stale-`persistFailure`
  carry-over onto the next card; confirmed `.atomic` means a failed write leaves the previous manifest intact,
  so rollback really does restore agreement; no `await` inside either function, so no reentrancy window) +
  **18 functional checks** in `ManifestPersistenceTestDriver` over a real scratch session manifest
  (`ARCHIVEPROC_TEST_BACKUP_ROOT`, synthetic pages; no corpus, no OCR, no network, no GUI, $0), including a
  fresh `CaptureSession()` restore after both the refusal and the retry, and — the ordering proof — a
  notification hook that reads the real `manifest.json` from inside the notification itself. **Non-vacuous per
  half:** restoring the old call order → 5 RED; swallowing the write failure as before → 10 RED; both neuters
  reverted. 86/86 ALL PASS; `test-recovery.sh` 45/45, `test-network-session.sh` 7/7, `test-filerelay.sh` 10/10
  (that last one runnable again — see `682bc7f`); build clean, 0 new warnings. **B9 entry updated** as this
  item asks. Residual, deliberately not widened: `removePhoto`/`removePhotoIfSafe`/`clear`/`clearFiled` still
  discard their `writeManifest` result — they trash photos, and restore skips manifest entries whose file is
  absent, so those degrade safely rather than silently losing a decision. Original report below.
  `Capture/CaptureSession.swift` (Apply/Skip), `Views/LiveCaptureView.swift`.
  Apply/Skip mutates `macTags` + `resolvedGroupIds`, schedules `liveProcessor.segmentResolved`, and
  **discards the `Bool` result of `writeManifest`**. The card vanishes immediately (it is derived from the
  in-memory resolved set) and the UI has **no failure channel**. If the manifest replacement fails and the app
  then crashes, recovery reloads the **old unresolved** state: stage-for-later loses the operator's decision,
  and live processing may already have baked/staged output from volatile tags while relaunch resurfaces the
  group as unresolved — recovered state inconsistent with the produced artifact, and possibly a second
  decision prompt. **Neighbouring sender controls already roll memory back when their manifest write fails —
  follow that pattern.** The "fixed" B9 known issue claimed Apply/Skip persistence but did not handle this
  ignored failure; update that entry.
  💡 **PRIOR ART EXISTS (found 2026-07-29 by symbol-auditing the preserved Codex branch).** Commit `3ea3221`
  *"fix(capture): persist completion before acknowledgment"* on branch **`wt/codex-processor-bugfixes-20260712`**
  (patches: `old/codex-processor-fixes-20260717/`, both off `main`) converts the discarded `writeManifest()`
  calls in `CaptureSession.swift` into checked ones **with memory rollback** — e.g.
  `guard writeManifest() else { let restoredManifest = writeManifest(); … }`,
  `if changed || newlyCompleted, !writeManifest() { … }` — in exactly the completion-set / tag-card region this
  item names. That is the "follow the neighbouring roll-back pattern" fix, already drafted. ⚠️ 76 commits
  behind and never build-verified here: **re-derive against current `main`, don't cherry-pick.**
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/{Capture/CaptureSession,Views/LiveCaptureView}.swift | S–M | med | none
- [x] **W23.m8 — Android's crash-durable `SessionStore` silently ignores current-manifest publication failure
  [M · MED · metadata loss · Android].** ✅ **DONE 2026-07-30** (`5d2c14a` data layer + completing commit;
  Processor `KNOWN_ISSUES.md` "✅ FIXED (W23.m8)"). `save` now returns whether THIS snapshot is durable, a
  set-before-write `session.stale` flag makes that knowledge survive the process that discovered it (the
  loss lands on the NEXT launch, and a first-ever publish failure leaves no manifest to carry the signal),
  and against a stale manifest the recovery sweep adopts pages `needsReview` — kept, visible and counted,
  but refused at `enqueueUpload` until the operator classifies them via the ordinary tag sheet, because a
  default Document group is a classification nobody chose and the Mac's half of that has no undo. En route:
  `File.createTempFile` sat outside `ManifestFileWriter.replace`'s `try`. 24 new headless JVM checks over
  scratch temp dirs; all five mechanisms neuter-proven (11/3/1/2/1 RED); 56/56 pass.
  `data/ManifestFileWriter.kt`, `data/SessionStore.kt`,
  `capture/CaptureViewModel.kt`. `ManifestFileWriter` **reports** replacement failure, but `SessionStore.save`
  returns **no result**, ignores that Boolean, and swallows exceptions — so the writer cannot tell the view
  model that the current snapshot was never committed. After an I/O failure + app termination, a new raw JPEG
  absent from the old manifest is **re-adopted into a fresh default Document group**, losing box/folder
  classification, group boundaries, priority/date/tags, replacement provenance and segment-completion state;
  known files can return with stale metadata.
  **Fix:** propagate the failure up through `SessionStore.save` to the view model, surface it, and **prevent
  lossy orphan adoption** when the current manifest is known-stale. The existing Android manifest fix
  preserves the *previous valid* manifest on failed replacement — it does not propagate failure of the *new*
  snapshot. | files: ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/{data/ManifestFileWriter,data/SessionStore,capture/CaptureViewModel}.kt | M | med | none
- [x] **W23.m9 — Reader and Notes indexers report successful completion after SQLite failures, and can
  poison the DB handle until restart [M · MED · CROSS-APP].** ✅ **DONE 2026-07-30** (checkpoints `d24b8da`
  half-open recovery + `4ee909a` Reader propagation, then this completing commit). Both modes, both apps.
  **Premise re-confirmed by experiment first:** `sqlite3_open_v2` is lazy, so a 1 KiB garbage file opens
  with `SQLITE_OK` and dies on the first PRAGMA with rc=26 "file is not a database" — the exact half-open
  window. (2) `open()` is now **all-or-nothing** in `ContentIndex` and `NotesIndex`: the PRAGMA/migration/
  schema half runs inside a `do`, whose `catch` releases the handle and clears `db` before rethrowing, so
  the next `open()` re-reads the file. Teardown goes through one `discardHandle()` using
  **`sqlite3_close_v2`**, not `sqlite3_close`: close_v2 never returns BUSY, so clearing `db` can't strand a
  live connection holding the file lock — not theoretical, under the neutered build the stranded handle kept
  the `-shm` sidecar locked and even *replacing* the bad file failed. It reaches further in Notes, whose
  same file holds the app-owned `folders`/`memberships` tables, not just the disposable FTS cache.
  (1) Each driver now publishes a typed `Failure` — `.unavailable(detail:)` / `.incomplete(rows:)` — mapped
  from a pass's `Outcome` in ONE place (`finish`), and `.ok` **clears** it so a transient corruption doesn't
  leave a permanent warning. Reader's five query paths + Notes' two go through `openForQuery()`, which
  records the failure instead of returning a bare empty result (empty ≡ "no matches" to a user); Reader
  shows an amber status-bar line + tooltip carrying the SQLite reason (`ar.status.indexFailure`), Notes
  mirrors to `NotesModel.indexFailure` → the sidebar `statusMessage` banner. Notes' `isIndexReady`
  deliberately still flips on failure — it is the *settled* signal `awaitSettled()`/`bootstrap()` resume
  off, so gating it on health would hang the app before first paint; the health claim is `indexFailure`.
  Fell out: a failed open now **stops** the pass instead of extracting the whole library to discard it batch
  by batch. `pruneIfSettled`'s `try?` deliberately stays (a failed open makes the diff empty → deletes
  nothing), noted in place. Tier-2, scratch only (garbage sqlite3 files + real scratch `.md` notes; no
  corpus, no network, $0): **16 new headless tests** (Reader 3+7, Notes 4+9 → 23; 7 recovery + 16
  propagation), incl. the full arc corrupt → unavailable → replace the file → pass succeeds → failure
  cleared AND the row actually written, and the end-to-end Notes shape (real notes on disk + dead index →
  settled but NOT presented as healthy). **Non-vacuous per mechanism, by neutering:** dropping
  `discardHandle()` → Reader 2/3 + Notes 3/4 RED ("no such table: items"/"folders", "an error was expected
  but none was thrown"); restoring `try?` in `launch`/`openForQuery` → Reader 4/7 + Notes 4/9 RED, each on
  its own mechanism. All reverted. Reader 266/266 but for the known `DeepLinkTests.testRevealAndSelectNoRoot`
  environment flake (W20.deeplink-isolation); Notes **572/572**; clean builds, 0 new warnings, write-surface
  lint clean. `ContentIndexer` gained an `init(url:)` seam (app path is now `convenience init()`). Residual
  filed as **W23.m9-fu** (LOW). Write-ups: `ArchiveReader/KNOWN_ISSUES.md`, `ArchiveNotes/KNOWN_ISSUES.md`.
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Search/{ContentIndexer,ContentIndex}.swift, ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/NotesIndexer,Index/NotesIndex,Core/NotesModel}.swift | M | med | none
- [x] **W23.m9-fu — Notes' *model-level* search still can't report an unavailable index [XS–S · LOW].**
  Residual of W23.m9, filed 2026-07-30. `NotesModel.search(_:)`/`summary(for:)` query the shared
  `NotesIndex` **directly** rather than through `NotesIndexer`'s wrappers, so they never attempt an open and
  never set a `Failure`: after the banner is dismissed, a session whose index died at launch answers every
  search with `[]` and says nothing more. Not a re-open of m9 — the launch-time failure *is* surfaced (the
  build reports it and the sidebar shows it), so this is residual visibility for the rest of the session,
  plus the missed chance to recover if the bad file is replaced while the app runs. Fix: route those two
  through the same `openForQuery()` seam the indexer uses (or share one health-aware accessor), and let the
  banner re-arm. Notes `Core/NotesModel.swift`, `Index/NotesIndexer.swift`. | Tier-1 | XS–S | LOW
  — ✅ **DONE 2026-07-31** (checkpoint `cc9fb59` code+tests): both model-level reads go through one
  `NotesModel.openIndexForQuery()`, which delegates to `NotesIndexer.openForQuery()` (now internal) so the
  driver stays the single owner of index health, and opens directly under the same all-or-nothing contract
  for a model injected with a bare index — the report must not depend on which initializer ran.
  **One correction to the item's text:** `NotesModel` has no `summary(for:)`; its second direct read is
  `reloadItems()` → `allSummaries()`, the note-list projection, so that is the second path routed.
  Three things the item didn't name, each measured rather than assumed. (1) **Re-arming the banner is not
  the same as reporting once** — `adoptIndexFailure` now re-posts the line on every read that hits a
  degraded index, so a dismissed banner comes back instead of leaving the next empty result unexplained;
  the `@Published indexFailure` assignment is change-guarded because a 150 ms-debounced search would
  otherwise republish an identical value per keystroke. (2) **Retraction had to be added with it** — a
  recovering index otherwise leaves a now-false "unavailable" banner up for the rest of the session; the
  model records the line it posted and clears *only* that one, since `statusMessage` is shared with every
  other degradation. (3) **A failed `reloadItems` must not publish its empty read** — `allSummaries()`
  answers `[]` for an unopenable index exactly as for an empty one, so publishing it erased the visible
  library on the strength of a query that never ran; a *successful* read still publishes whatever it found,
  empty included. Writes (`upsertBatch`/`deleteItems`) were deliberately left out of the seam: they already
  throw and are reported, and an accessor that can return nil would turn that loud failure into a silent
  skip. **Tier-1, scratch only** (garbage/empty sqlite3 files + real `.md` notes in per-test temp dirs; no
  real store, no corpus, no network, $0): 11 new tests (`NotesModelIndexHealthTests`). **Non-vacuous,
  measured twice over:** against the pre-fix code the 6 report/recover assertions were RED and the 5
  must-not-over-report guards GREEN (blank query, healthy-empty index, healthy `reloadItems`, driver-less
  search, index-less model); then 3 neuters each reddened exactly one predicted assertion and nothing else
  (A unconditional retraction → the trash-failure line is swallowed; B no retraction → the false banner
  stays up; C publish the failed read → the library is erased). All reverted; `grep NEUTER` clean.
  **714/714** Notes + 189 XCTest, clean build, 0 new warnings. No ArchiveCore type and no SPEC change →
  Reader/Processor untouched, so the shared-core all-three-app rebuild rule is N/A. No new view code — the
  only visible surface is the existing `an.sidebar.status` line, and no GUI fixture can produce a corrupt
  index, so there is nothing for the VM lane to see (same as m9). Residual filed as **W23.m9-fu2** (below).
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Core/NotesModel,Index/NotesIndexer}.swift
- [x] **W23.m9-fu2 — a repaired index becomes queryable again but stays EMPTY until the next launch
  [XS–S · LOW].** ✅ DONE — code in checkpoint `45b3854`, tests + trackers in this commit. The `unavailable → open`
  **edge** now schedules `repopulateIndexAfterRecovery()`, which is `buildIndexFromDisk()` verbatim — so a
  repaired index is refilled the same way a fresh one is, and a search moments later answers from real rows
  instead of an empty file. **Edge, not state, is the whole point:** the item was *filed* rather than fixed
  because the obvious version walks the store once per keystroke of a 150 ms-debounced search; triggering on
  the transition walks it once per recovery. (`.incomplete` deliberately stays out — unlike `.unavailable`
  it is not cleared by a successful open, so triggering on it would be state-triggered by the back door.)
  It also runs **off the read's critical path** (the read that notices returns its still-empty result at
  once; the rows land on a later read, as after any launch build) and **one at a time** (the pass re-enters
  the accessor via `reloadItems()`, and a flapping file would otherwise stack rebuilds). Reusing
  `buildIndexFromDisk()` rather than a bespoke path is deliberate: the two cannot drift, its upserts are
  mtime-skipped (a volume that returns with its rows intact costs one directory walk and no writes), and it
  repairs the *partial* index a mid-pass failure leaves, which an "only rebuild when it reads empty" shortcut
  would skip. Read-only w.r.t. the note store; prunes nothing — asserted, not merely claimed. The second half
  of the item's own objection is accepted on purpose: the pass **does** bump `isIndexReady`/`indexGeneration`,
  which is the behaviour change this item was split out to make deliberately — the token means "a build
  settled", and one did, and `isIndexReady` only ever goes true, so the hidden `an.status.indexReady` probe
  cannot regress to "building" under a test. No driver / no store is a no-op (nothing to walk). **Tier-1,
  scratch only** (garbage/empty sqlite3 files + real `.md` notes in per-test temp dirs; no real store, no
  corpus, no network, $0): 10 new tests (`NotesIndexRepopulationTests`). **Non-vacuous, measured four
  ways:** neutering the whole fix reddened 4 of 10 (refilled-on-a-later-read, `reloadItems` republish,
  exactly-one-rebuild, ready-token-advances) while all 6 guards stayed green; then three targeted neuters
  each reddened exactly ONE predicted test and nothing else — **state-triggered** (schedule on every
  successful open) reddened only "searching a healthy index never schedules a rebuild"; **inline-blocking**
  (await the rebuild on the read) reddened only the off-the-critical-path assertion; and **schedule-before-
  checking-`opened`** reddened only "a read over a still-dead index schedules no rebuild" — the case where
  a file that never comes back would walk the store on every keystroke. All reverted; source `git diff`
  empty against the checkpoint and `grep NEUTER` clean. **724/724** Notes (was 714), clean build, 0 new warnings. No
  ArchiveCore type and no SPEC change → Reader/Processor untouched, so the shared-core all-three-app rebuild
  rule is N/A. No new view code, and no GUI fixture can corrupt an index mid-session, so there is nothing for
  the VM lane to see (same as m9/m9-fu) — the one GUI-adjacent surface, the `an.status.indexReady` probe, is
  argued above and held by a headless test. **W23.m10-fu stays open**: same shape, but a different subsystem
  (`OrganizationStore`'s mirror) with its own retry seam — pairing them was a suggestion, not a dependency.
  | files: ArchiveNotes/macOS/{Sources/ArchiveNotes/Core/NotesModel.swift, Tests/ArchiveNotesTests/NotesIndexRepopulationTests.swift}
  *Original finding:* residual of W23.m9-fu, filed 2026-07-31 (`cc9fb59`). A read that re-opens an index which
  had been reported unavailable now retracts the false banner and hands back a live handle — but nothing
  repopulates it: rows are rebuilt only by `buildIndexFromDisk()` at launch (or one at a time by a later
  mutation's `upsertBatch`). So in the rare window where the bad file is repaired mid-session (operator
  replaces it, a sync client heals it, the volume returns), search goes back to answering `[]` with nothing
  said. Not a re-open of m9-fu: a dead index is now reported on *every* model-level read, and the
  retraction is correct — the "unavailable" claim really is false once the file opens. **Filed rather than
  fixed deliberately:** the obvious fix (kick `buildIndexFromDisk()` on the `.unavailable`→healthy
  transition) starts a full disk walk from a keystroke and bumps `isIndexReady`/`indexGeneration`
  mid-session, which the XCUITest `an.status.indexReady` probe reads — a behaviour change that deserves its
  own item rather than riding along on a LOW visibility fix. Same shape as **W23.m10-fu** (a recovered
  volume doesn't re-mirror until the next organization mutation), and worth doing with it. Notes
  `Core/NotesModel.swift`, `Index/NotesIndexer.swift`. | Tier-1 | XS–S | LOW
- [x] **W23.m10 — `organization.json` export failure is reported as a successful organization change
  [S · MED · durable-mirror rot].** `Index/OrganizationFile.swift`, `Index/OrganizationStore.swift`.
  `organization.json` is documented as **the authoritative durable mirror** that survives DB wipes and
  computer moves — but its export function returns `Void` and **suppresses both encode and atomic-write
  failures**, and every organization mutation commits SQLite/in-memory **first** then calls that nonthrowing
  exporter. On a full, read-only or unavailable Notes volume the UI reports folder / membership /
  template-assignment changes as successful while the mirror stays **stale** — and a later DB loss or
  migration restores obsolete organization state.
  **Fix:** make the exporter `throws`, propagate to the mutation's result, and surface failure (the mutation
  is not "done" until its durable mirror is). The existing DB-first shadowing note is about which source wins
  at startup/under test — not export failure after an interactive mutation.
  — ✅ **DONE** (checkpoint `0b9ded1`): the exporter throws, and the failure is now something the app both
  knows and says. **Premise re-confirmed by experiment first:** an atomic write into a missing directory
  throws, into a read-only directory throws **and leaves the previous bytes in place** — so the mirror does
  not go missing, it goes quietly *wrong* — and the old `try?` shape returned normally having written
  nothing. `OrganizationFile.export` now `throws`; `OrganizationStore` publishes
  `mirrorFailure` (`.writeFailed(detail:)` / `.noStoreRoot`) + `isMirrorStale`, cleared by any later
  successful export — correct because the export is **whole-graph, not incremental**, so one working write
  re-syncs the mirror *including* the changes whose own exports failed (proven, not assumed).
  **The load-bearing decision:** this is observable STATE, not a `throws` out of each mutation, and the
  reasoning is recorded in code so it isn't "simplified" back. The export is the LAST step, so by the time it
  can fail the change HAS committed — throwing would make ~17 call sites report "Couldn't create the folder"
  about a folder that exists and skip the `rebuild()` that shows it (a worse lie than the silence), and three
  existing callers use `try?` (`clearDanglingAssignments`, `deleteTemplate`, `move`'s source removal), so a
  thrown error would be swallowed on exactly the paths at issue. It is also the synchronous post-`await` seam
  **W23.m13** needs. `NotesModel.adoptMirrorFailure()` surfaces it on the existing sidebar status line (the
  W23.m9 `adoptIndexFailure` idiom), called LAST on all 17 organization-mutating paths in `NotesModel` +
  `NotesNavigationModel`, so a real degradation outranks that path's own status text and no caller loses its
  return value or its UI update. No trash/delete decision changed — mirror *atomicity* stays W23.m13.
  Tier-2, scratch only (`temporaryDirectory` fixtures; no corpus, no network, $0): **9 new headless tests**
  covering the seam, a healthy volume, the stale-mirror divergence read back off disk, whole-graph recovery,
  no-store-root, **each of the 9 mutation kinds attributed individually**, and the façade + navigation
  surfaces. The DB is deliberately placed OUTSIDE the store root so a read-only root breaks the mirror write
  and nothing else (co-located, SQLite couldn't write its journal and the mutation would fail *before* the
  export — testing the wrong thing). **Non-vacuous per mechanism, by neutering:** restoring `try?` → 6/9 RED
  incl. all 9 mutation cases; dropping `adoptMirrorFailure` → the 2 UI-surface tests RED; dropping the
  success-clear → the recovery test RED, each with the healthy-path checks correctly staying GREEN. All
  neuters reverted. Notes **581/581**; clean build, 0 new warnings. No ArchiveCore/SPEC change → Reader and
  Processor untouched, shared-core rebuild rule N/A. No new view code (the `an.sidebar.status` line already
  existed and is GUI-covered), so nothing for the VM lane. Residual filed as **W23.m10-fu** (LOW).
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationFile,Index/OrganizationStore,Core/NotesModel,Core/NotesNavigationModel}.swift | S | med | none
- [x] **W23.m10-fu — a recovered volume doesn't re-mirror until the next organization mutation
  [XS · LOW].** Residual of W23.m10, filed 2026-07-30. `mirrorFailure` is cleared by the next *successful
  export*, and the only thing that exports is a mutation — so if the disk frees up (or the volume comes back)
  and the operator never touches folders again, `organization.json` stays stale for the rest of the session
  with nothing on screen saying so once the status line has been tap-dismissed. Not a re-open of m10: the
  failure IS reported when it happens, and any later organization change self-heals the whole mirror. Fix:
  retry the export opportunistically while `isMirrorStale` (on app activate / periodically / before
  terminate), or make the sidebar line sticky while stale rather than dismissible. Notes
  `Index/OrganizationStore.swift`, `Core/NotesModel.swift`. | Tier-1 | XS | LOW
  — ✅ **DONE** (checkpoints `bd2ac11` = code, `7a5cf04` = tests). `OrganizationStore.retryStaleMirrorExport()`
  re-runs the same **whole-graph** export — so one working write recovers everything that missed the mirror,
  with no queue of changes to replay — and `NotesModel` hangs it off **app activation** and **app terminate**.
  Those two, not a timer: activation is the moment correlated with the volume having come back, terminate is
  the last moment the file can be written before the next launch inherits it (the DB wins at startup, so
  nothing else re-syncs it), and this app does no background polling. **Three guards, each a way the obvious
  implementation goes wrong.** (1) It runs **only while stale**, so no app switch rewrites a healthy
  `organization.json` — the whole reason it is safe to hang off something that frequent. (2) It requires the
  graph to have **finished loading**: `load` assigns `storeRoot` before it awaits the DB, and a speculative
  export in that window would put a half-built forest in the user's file. (3) The stale line is **re-posted**
  on every activation while the volume is still bad (the m9-fu "a dismissed banner comes back" idiom) and
  **retracted** when the mirror heals — narrowly, only if the line still showing is the one this model posted,
  since `statusMessage` is shared. Retraction had to ship *with* the retry: before it, `mirrorFailure` could
  only stop being true via a mutation, so nothing could leave a false claim on screen. **Reentrancy checked,
  not assumed:** the trigger is a synchronous notification, so it can land on the main actor while a mutation
  is suspended at its `await` (`@MainActor` is reentrant) — but every mutation in the store commits DB
  transaction → memory → export with **no suspension between the last two**, so the only state a retry can
  observe mid-mutation is the consistent *pre-mutation* graph, which that mutation's own export supersedes a
  moment later (and if it throws instead, the pre-mutation graph was the right thing to have written). Noted
  next to the convention it depends on. The observers live in a small non-isolated box so they are removed
  when the model dies — a `@MainActor` type's `deinit` cannot touch its own token array. Tier-1 but gated
  like Tier-2 (it writes a durable file), scratch only (`temporaryDirectory` fixtures + a `0555` root, index
  deliberately outside it; never the real store, no corpus, no network, $0): **9 new tests**
  (`OrganizationMirrorRetryTests`), including sentinel bytes to prove a healthy mirror is *not* rewritten.
  **Non-vacuous by 4 neuters, each reddening exactly the predicted tests and nothing else:** dropping the
  stale-only guard → the 2 "healthy mirror untouched" tests; dropping the loaded-graph guard → the no-root
  test; unwiring the triggers → the 4 notification tests; dropping the retraction → the recovery test only
  (the "don't swallow another subsystem's line" test correctly stayed green). All reverted, `grep NEUTER`
  clean. A 5th measurement corrected a *comment* rather than code: `queue: .main` also runs inline when the
  post is already on the main queue, so the doc no longer claims a behavioural difference it doesn't have —
  `queue: nil` is kept for the documented synchronous-delivery guarantee the terminate leg rests on.
  **733/733** Notes (was 724), clean build, **0 new warnings**. Notes-internal — no ArchiveCore type and no
  SPEC change → the shared-core all-three-app rebuild rule is N/A. No new view code (the `an.sidebar.status`
  line already existed and is GUI-covered) and no GUI fixture can make a volume read-only mid-session, so
  there is nothing for the VM lane to see — same argument as m10/m9-fu2.
  | files: ArchiveNotes/macOS/{Sources/ArchiveNotes/Index/OrganizationStore.swift,
  Sources/ArchiveNotes/Core/NotesModel.swift, Tests/ArchiveNotesTests/OrganizationMirrorRetryTests.swift}
- [x] **W23.m11 — the app-wide inline-image cache can display another note's same-named image
  [S · MED · wrong content shown].** ✅ DONE this commit. Premise re-confirmed by symbol first and it was
  live: `MarkdownBridge.swift:248` passed `cacheKey: ref.path` into the **static** (app-wide)
  `thumbnailCache`, so two notes each owning their own `assets/x.png` — ordinary, and explicitly supported
  by the store — shared one entry, and note B displayed note A's image without ever opening B's file.
  Fixed by deriving the key from the **resolved canonical URL** *inside* `loadThumbnail`, which no longer
  accepts a caller-supplied key at all: a caller-named key is how the coarse key got used, so the seam is
  gone rather than merely used correctly. **Two deliberate deviations from this item's fix sketch, both
  documented at the symbol:** (1) *no separate item UUID* — the resolved URL already spells out
  `…/items/<uuid>/assets/<name>` (`NoteStore.itemDir`), so the item is in the key by construction, and two
  items can only collide by literally sharing the file, where one shared entry is the correct answer (a test
  pins that a same-item symlink and its target share one); adding a UUID would only split it in two.
  (2) *no per-item invalidation* — an asset path is **write-once** in this app (`writeReservedAsset` throws
  rather than overwrite, `importAsset` disambiguates, UUIDs are never reissued), so a purge would have had
  no caller. `maxPixels` **is** in the key, closing the same aliasing bug one size-shift away. Normalization
  is string-only, so a cache hit still costs zero disk I/O. **8 new tests** (`InlineImageCacheKeyTests`),
  each non-vacuous: note B renders its own blue pixels after A warmed the cache with red under the same
  relative path; a red sentinel planted under the *exact* pre-fix key is asserted to be a live hit and then
  shown to be ignored by the render; the hit path is proven by serving a warm entry with the file's bytes
  replaced by garbage. 589/589 `ArchiveNotesTests` green, no new warnings. Residual filed as **W23.m11-fu**
  (LOW). Write-up: `ArchiveNotes/KNOWN_ISSUES.md`.
- [x] **W23.m11-fu — an inline image replaced OUTSIDE the app keeps showing its old thumbnail
  [XS · LOW · stale display].** Residual of W23.m11, filed 2026-07-30. Cache entries never expired, which is
  sound for every in-app writer (asset paths are write-once — see m11), but the Notes store root can live in
  a synced folder, and a sync client rewriting bytes at an existing `items/<uuid>/assets/<name>` left the
  editor showing the previous thumbnail until the entry was evicted or the app restarted. **Display only** —
  the file on disk, the note body, and the copy/extract path (which reads bytes fresh) were all correct,
  which is why this was LOW and not a re-open.
  ✅ **DONE this commit** (checkpoint `136453b` = the code). Took the first option: `cacheKey` folds in the
  file's **version** — size + nanosecond `st_mtimespec` from one `stat(2)` — so a stale entry is never looked
  up again. Nothing expires and nothing is purged; it ages out of a bounded cache under a name nothing asks
  for. `cacheKey` returns **nil** for a file that cannot be stat'ed, so a vanished asset has no cache identity
  and is read (and fails) rather than answered out of memory; `cached: false` skips the stat entirely.
  **The item said "measure first". Measuring reversed a design choice and demoted the objection:**
  (1) **`stat(2)`, not `URL.resourceValues`** — `URL` caches resource values on its backing `NSURL`, so
  rewriting a file 100→250 bytes between two calls *on the same `URL` value* read back **unchanged on both
  fields**; the idiomatic Foundation call would have defeated the fix silently (`FileManager
  .attributesOfItem` is honest but ~437 µs vs ~15 µs). (2) **A hit got cheaper, not dearer** — the ~15 µs
  `stat` *replaces* a `standardizedFileURL` that cost ~53 µs and itself touched the file system (12.8 µs on a
  path that does not exist, 52.7 µs on one that does), so key construction goes ~76 µs → ~17 µs; the premise
  behind the objection ("a hit does no disk I/O") was not true to begin with. The decode a hit avoids is
  ~3,200 µs. (3) **Nanosecond mtime is sharp enough** — 20 back-to-back same-size rewrites of one file gave
  20 distinct versions on APFS; the only rewrite still invisible is same-length *and* same-timestamp, which
  needs a coarser-timestamp volume (SMB) and still recovers on eviction/relaunch as before.
  The other option (purge on an observed external change) was rejected with a reason, not skipped: the store
  observes nothing — Notes has **no file-system watcher**, as W23.m9-fu2 records for the index — so that is a
  new subsystem, not a key change. **Tier-1, scratch only** (temp-dir stores; never the real Notes store, no
  corpus, no network, $0): **5 new tests** in `InlineImageCacheKeyTests`, each first showing the stale entry
  is *still live in the cache*, so what they prove is the keying and not an eviction. One existing test was
  changed rather than deleted — `repeatRenderStillHitsTheCache` proved a hit by replacing the bytes with
  garbage, which is now a different file; it pins the mtime to a whole second (restorable exactly), swaps in
  **same-length** garbage and restores that timestamp, keeping its intent and documenting the granularity.
  **Non-vacuous by 4 neuters, each predicted in advance and each reddening exactly the predicted set:**
  drop the version → the 3 detectors; drop the nil-on-missing contract → the 1 vanished-asset assertion; drop
  the path → the 2 tests pinning m11's own result; invalidate on *every* call → the cache-hit guards (which
  is what proves those guards aren't vacuous). All reverted; source diff clean, `grep NEUTER` empty.
  **738/738** Notes green (was 733), clean build, **0 new warnings**. Notes-internal — no ArchiveCore type,
  no SPEC change → the shared-core all-three-app rebuild rule is N/A. GUI: the visible effect *is* the decoded
  pixels, asserted headlessly at attachment level (as in m11), and no GUI fixture can rewrite a file behind
  the app's back → nothing for the VM lane to see. Write-up: `ArchiveNotes/KNOWN_ISSUES.md` (folded into the
  m11 entry, whose now-false "no disk I/O on the hit path" cost claim is corrected there).
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/InlineImageAttachment.swift | Tier-1 | XS | LOW
- [x] **W23.m12 — a FAILED move-to-Trash still removes the surviving note from the index [S · MED · note
  disappears].** `Core/NotesModel.swift` → `trashItems`. It **logged** each `NoteStore.delete` failure but then
  deleted **every requested ID** from `NotesIndex` and reloaded the list. A note whose directory is still on
  disk therefore vanished from **All Notes for the rest of the run** — there is no watcher to restore it, and
  the full disk rebuild runs only at bootstrap. This **contradicted the method's own stated safety invariant**
  that a trash failure leaves the note on disk *and discoverable* under All Notes.
  ✅ **DONE 2026-07-30** (checkpoint `8e15b59` fix + tests/docs in the completing commit): a row is dropped
  only once its note is **provably absent**, decided by asking the disk (new read-only `NoteStore.itemExists`)
  rather than by classifying the error — because `delete` *also* throws when the directory was already gone
  (`StoreError.notFound`), where keeping the row would strand a phantom note that opens on nothing. A refused
  note keeps its row (still under All Notes, 0 memberships) and the sidebar status line says where it is;
  `trashItems` returns the survivors. Same seam, opposite direction: a failing `NotesIndex.deleteItems` is no
  longer swallowed by a bare `try?`. 9 new scratch tests (`NotesTrashFailureTests`) over a real
  store+index+indexer, with a **per-item** `UF_IMMUTABLE` refusal so one note in a batch fails while its
  sibling trashes normally; both real callers covered; non-vacuity measured by 3 neuters (pre-fix → the 4
  finding tests RED; over-correct → only the already-absent guard RED; `try?` → only the index-write test RED).
  598/598 Notes green, 0 new warnings.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift | S | med | none
- [x] **W23.m13 — several multi-step Notes organization operations leave partial state after a failure
  [M · MED · fault atomicity] (blocked-on: W23.m10).** `Index/OrganizationStore.swift`,
  `Core/NotesModel.swift`, `Core/NotesNavigationModel.swift`. The Notes façade **claims organization mutations
  are atomic**, but three span independent awaited writes with no transaction or rollback:
  - `deleteFolder` mutates each child **in memory** before its individual DB update, then separately deletes
    memberships, assignments and the folder — a later SQLite failure leaves a partially reparented/deleted
    graph in memory **and** on disk.
  - `deleteTemplate` clears **every** folder assignment before attempting to move the template to Trash — if
    Trash fails the template survives but its assignments are gone.
  - `move` adds the target membership first then **suppresses source-removal failure** — the UI reports a move
    while the item is actually **replicated in both folders**.
  **Fix:** wrap each in a real SQLite transaction (or an explicit compensating rollback), and only mutate
  in-memory state after the durable write commits. Blocked-on W23.m10 because that item makes the export leg
  of these same mutations failable — do the error-propagation seam once. No active item covers this.
  ✅ **DONE 2026-07-30** (checkpoint `59fc57c` = the three fixes; completing commit = tests + trackers): all
  three are now real SQLite transactions, and **no in-memory state moves until the disk says it committed.**
  `NotesIndex` gains `deleteFolderGraph` / `moveMembership` / `deleteTemplateAssignments` — whole methods, not
  exposed BEGIN/COMMIT, because this actor's invariant is *no suspension between BEGIN and COMMIT* and
  `OrganizationStore` is `@MainActor` (reentrant at every await). `deleteFolder` builds the reparented children
  as copies and applies them after the commit; the folder-delete await count drops 4 → 1. `move` goes through
  a new `OrganizationStore.moveMembership` that keeps **both** properties the old add-then-`try?`-remove order
  existed for (the insert precedes the delete *inside* the transaction, so the item is never member-less and
  MOVE can't trip the §3.6 guard) while making a failure total — and `NotesNavigationModel.move` now says
  "it's still where it was", which only the rollback makes an honest thing to say. `deleteTemplate` **trashes
  first** and clears assignments only once that succeeded (the reverse of its old order): a refused trash now
  changes nothing, and the opposite failure leaves only a dangling assignment, which `TemplateResolution`
  already skips and `effectiveTemplate` lazily clears. The measured surprise worth recording: the DB-side loss
  was **silent, not loud** — memory was *also* unchanged (the throw skipped its own cleanup) while the
  memberships were already gone from SQLite, and `load()` prefers the DB, so the next launch adopted the lossy
  half and orphaned those notes with no §3.6 prompt ever shown. 16 new scratch tests
  (`OrganizationAtomicityTests`) with **real SQLite fault injection** — a `BEFORE DELETE … RAISE(ABORT)`
  trigger, targeted by row where a batch needs the first delete to succeed and the second to fail (an
  all-rows refusal cannot tell a rollback from a half-applied batch); 2 assert the fixture's own honesty.
  Non-vacuity measured by 4 neuters, each reddening a disjoint set: pre-fix `deleteFolder` → the 3 folder
  tests (7 assertions); pre-fix `move` → the 2 move-failure tests (5); pre-fix `deleteTemplate` order → the
  template test (assignments go to `[]` while the template survives); non-transactional batch clear → the
  batch test. All neuters reverted (`git diff` empty). 614/614 Notes green, clean build, 0 new warnings.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationStore,Index/NotesIndex,Core/NotesModel,Core/NotesNavigationModel}.swift | M | med | none
- [x] **W23.m14 — resolving a missing Reader link synchronously scans the whole archive on the main actor
  [S–M · MED · UI freeze].** `Links/ReaderLinkResolver.swift`. The resolver is `@MainActor`; when an exact
  relative path is missing, `resolve` **synchronously enumerates every descendant** of the granted Reader root
  looking for a matching basename. Clicking **one** broken or moved source link therefore freezes all Notes UI
  for the duration of a **100k–150k-file** archive walk, with **no cancellation**. (The basename fallback is
  intended behaviour — doing it synchronously on the UI actor is the defect.)
  **Fix:** move the fallback off the main actor into a cancellable async task with progress + a bound, and
  keep the resolver's fast exact-path hit synchronous. Notes W9 C6 covers Notes-index scale, not Reader-root
  fallback scanning.
  ✅ **DONE 2026-07-30** (checkpoint `71cb722` = the split + the popover; completing commit = tests +
  trackers). Premise re-confirmed by symbol first. Resolution is now two stages: `resolveExact` keeps the
  cheap answers (unknown root, containment refusal, exact hit) synchronous on the main actor and returns
  `.needsBasenameSearch` **instead of** searching, and `nonisolated static scanForBasename` does the walk on
  the cooperative pool. **The synchronous full-walk API is gone rather than deprecated** — the defect was not
  that one call site was slow, it was that the resolver *offered* a main-actor walk over a 100k–150k-file
  archive, so `resolve` is async-only and a future caller cannot re-introduce the freeze.
  **A search that did not finish is never reported as absence:** the new `.searchIncomplete(scanned:)` case
  covers cancellation, the entry bound, and an unwalkable root, and the popover says the file "may still be
  there" instead of "not found". The bound is `1_000_000` entries — an order of magnitude clear of the real
  corpus (~102k PDFs + JPEG partners + folders), because it exists to stop a pathological mount, not to cap a
  legitimate archive. A root that **doesn't exist** still reports `.notFound` (nothing can be under it), which
  is what keeps the shipped W8-S9 computer-move contract intact — a distinction the E2E suite caught.
  Cancellation is checked every 64 entries; the popover cancels on dismiss/re-show and shows a live
  "N items checked" readout, generation-scoped so a finished search's straggler ticks can't inflate the next
  one's count. **10 new tests** (`ReaderLinkScanTests`), scratch temp trees only, `readerRootBookmarks`
  snapshot/restored so host defaults are left byte-identical. **Non-vacuity measured by 3 neuters, each
  reddening a disjoint set:** pre-fix main-actor walk → 4 tests; unfinished-search-reported-as-`notFound` →
  the 2 honesty tests; `@MainActor` scanner → the 2 off-actor tests. The off-actor proof is structural, not
  timing-based — the raw progress callback runs on the scanning thread, so `Thread.isMainThread` inside it
  answers the question directly. **624/624** `ArchiveNotesTests` green, clean build, 0 new warnings. Notes-only
  — no ArchiveCore type touched, so the shared-core rebuild rule is N/A. VM UITest lane re-run: the same 4
  pre-existing failures as the 19:44 baseline (G3/G6/G8/G11, already tabled in `ArchiveNotes/KNOWN_ISSUES.md`),
  no regression. Containment still uses `standardizedFileURL` **on purpose** — W23.l1 (blocked-on this item)
  is the symlink-containment fix and stays a clean one-line change on this seam, now unblocked.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Links/ReaderLinkResolver.swift | S–M | med | none
- [x] **W23.m15 — deleting the Inbox or Extracts system folder is permanent and creates ghost memberships
  forever [S–M · MED].** ✅ **DONE 2026-07-31** (checkpoint `cf03fe1` = the three Swift refusal layers,
  the by-id restore and 13 tests; completing commit = the SQL foreign key, its migration and the
  trackers). Rename/Delete are disabled
  on a system folder in the sidebar, refused with a readable sentence by `NotesModel` (and refused
  *before* `deleteFolderDeletingStranded` trashes anything), and refused by `OrganizationStore` as the
  backstop; `load` restores a missing system folder **by id** on every path — a no-op for a healthy
  store, never clobbers a rename, and revives the memberships the deleted folder stranded;
  `addMembership`/`moveMembership` refuse an unknown folder, and `memberships.folder_id` is now a real
  FOREIGN KEY with an in-place migration that carries a legacy DB's ghost rows across rather than
  deleting durable data to satisfy a constraint added after the fact. **NO ACTION, not ON DELETE
  CASCADE** — a cascade would let any stray folder-row delete silently empty the folder. Two claims the
  tests corrected: an `INSERT OR REPLACE` on `folders` is *survivable* under NO ACTION (SQLite checks an
  immediate FK at statement end, so delete-then-reinsert of the same key nets to zero), so the
  `updateFolder` rewrite is justified by non-upsert semantics rather than that hazard; and
  `replaceOrganization`'s delete order **is** load-bearing (children before parents). 20 new tests
  (`SystemFolderIntegrityTests`), scratch fixtures only; 644/644 green; non-vacuity proven by 6 neuters,
  each reddening a disjoint set. Residual **W23.m15-fu** (LOW) filed in the LOW section.
  `Views/NotesFolderTreeView.swift`, `Index/OrganizationStore.swift`,
  `Core/NotesModel.swift`, `Index/NotesIndex.swift`. Every folder — **including the fixed-ID Inbox and
  Extracts** — gets Rename and Delete actions, and `deleteFolder` accepts those IDs. System folders are
  reseeded **only when the entire folder table is empty**, so deleting one is **permanent**. Worse, new notes
  and extracts keep filing memberships under the deleted fixed IDs: `addMembership` **does not verify the
  folder exists** and SQLite declares **no foreign key** — so the graph accumulates memberships to a folder
  that can never appear in the tree or be restored by normal startup.
  **Fix:** (a) refuse Rename/Delete on the two system folder IDs in both the UI *and* `deleteFolder`
  (defence in depth); (b) reseed a missing system folder at startup by **ID**, not only on an empty table;
  (c) make `addMembership` reject a nonexistent folder, and add the FK/constraint.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Views/NotesFolderTreeView,Index/OrganizationStore,Core/NotesModel,Index/NotesIndex}.swift | S–M | med | none
- [x] **W23.l1 — the Notes Reader-link containment check is bypassable through a symlink [S · LOW · scope
  bypass] (blocked-on: W23.m14).** ✅ **DONE 2026-07-31** (checkpoint `2f13d25` = the exact-path stage + 8
  tests; completing commit = the basename walk, its 2 tests and the trackers). Premise re-confirmed on a
  scratch tree before anything changed: the old rule really did accept the escape — `standardizedFileURL`
  normalizes `..` lexically and does **not** resolve symlinks, while `fileExists` **does** follow them, so
  `<root>/alias.pdf` → a PDF outside the granted Reader root came back `.resolved`. Containment now goes
  through one seam, **`ReaderRootContainment`**: `canonical()` = `resolvingSymlinksInPath().standardizedFileURL`
  applied to **both sides** (so a root reached through a symlinked ancestor, or the `/var` ↔ `/private/var`
  alias, still contains its own files) and `isContained()` compares **path components** (so `…/root-extra/x.pdf`
  is not "under" `…/root`). Both doors are closed, not just the one in the finding: the **basename walk** was
  the other one — the enumerator lists a symlink as an ordinary entry, so an escaping twin could still be
  offered as `.renamedCandidate`; it is now skipped, and *skipped* rather than stopped, so a genuine copy
  further on is still found and absence is still established (`.exhausted` → `.notFound`, never
  `.searchIncomplete`). `.resolved` still carries the URL the link named, not its canonical form — that is the
  spelling the granted root's security scope covers, and containment is proven by then. `ReaderPreviewPopover`
  needed **no change**: it presents whatever the resolver decides, and the resolver is the seam. Kept honest in
  the other direction — an in-root symlink still resolves, a root under a symlinked ancestor still resolves its
  files, and a **dangling** symlink is not an escape (there is nothing to escape to): it falls through to the
  basename search like any other missing file. **10 new tests** (`ReaderLinkContainmentTests`), scratch temp
  trees only, `readerRootBookmarks` snapshot/restored so host defaults are left byte-identical; **every escape
  case first asserts the pre-fix rule accepted the fixture**, so none can pass vacuously (the W23.m3
  `AssetPathResolverTests` pattern). One fixture correction worth recording: a root that IS a symlink cannot be
  registered at all — security-scoped `bookmarkData` refuses one — so that guarantee is proven at the predicate
  level and the end-to-end test uses the shape that does occur, a symlinked *ancestor*. **654/654**
  `ArchiveNotesTests` green, clean build, 0 new warnings. Notes-only; no ArchiveCore type touched, so the
  shared-core rebuild rule is N/A. No view or interaction code changed, so no VM UITest run was needed.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Links/ReaderLinkResolver,Views/ReaderPreviewPopover}.swift | S | low | none
- [x] **W23.l2 — a cancelled prune task can still defeat the two-emission absence gate [S · LOW · residual
  race] (blocked-on: W23.m9).** ✅ DONE `ad5e5cb` (Reader) + this commit (Notes + trackers).
  **Premise re-confirmed empirically first, and the first probe refuted itself** — which is the useful part.
  Replaying the pre-fix shape under the real concurrency runtime showed back-to-back emissions are actually
  **safe** (task A dies at its first cancellation check, never having started); the race needs A genuinely
  mid-flight, which is the real case since `allPaths()` over a large index takes real time. Parked past A's
  last check, all four questions confirmed: A observed `Task.isCancelled == true` and ran its hops anyway; a
  superseded A overwrote state a newer emission had just written; that stale stash deleted a path after only
  ONE current absence; and in the other interleaving A deleted a path the newest snapshot said was present.
  **Fix = a prune epoch, with two load-bearing halves:** `commitPruneDecision` does read-decide-write in ONE
  main-actor hop (a split read-then-write is the window the newer emission interleaved through, so the
  generation check alone would not have closed it), and the row delete re-checks the epoch — skipping a
  superseded delete costs only another two-emission cycle, while deleting wrongly costs search hits until a
  reindex. `resetPruneState` bumps the epoch too, or an in-flight task from the OLD root re-stashes its
  absences over the cleared state. Reader also gained a pure `pruneDecision` mirroring Notes', which moves the
  empty-snapshot guarantee inside the decision (no reachable behaviour change — `NavigationModel` already
  refuses to call with an empty set — it just can't be lost to a future caller). **Notes' half is preventive
  and labelled as such:** `pruneIfSettled` there still has no production caller, but it is a fork of the
  Reader file and both were fixed together so the day one is wired it inherits the gate, not the race.
  **16 new tests** (Reader `ContentIndexerPruneRaceTests` 10, Notes `NotesIndexerPruneRaceTests` 6), scratch
  sqlite / scratch store only. Both race interleavings are driven **deterministically through the epoch seam**
  rather than by trying to win a real race, and each re-implements the PRE-FIX ungated logic against the same
  fixture and asserts it produced the harmful outcome, so none can pass vacuously; plus a guard that
  `pruneIfSettled` really opens a new epoch (so a future edit can't silently drop it), the reset case, and
  four end-to-end passes over a real index and the real driver — awaited via `inFlightPruneTask`, not slept
  on — since the refactor moved the delete after the state write. Clean builds, 0 new warnings; Notes
  **660/660**, Reader green apart from the known `DeepLinkTests.testRevealAndSelectNoRoot` host-defaults flake
  (tracked as W20.deeplink-isolation). No ArchiveCore type touched → shared-core rebuild rule N/A; no view or
  interaction code → no VM UITest run needed. Original finding follows.
  Reader `Search/ContentIndexer.swift`, Notes `Index/NotesIndexer.swift`.
  Starting a prune cancels the prior detached task, but **cancellation is cooperative**: after the old task's
  final cancellation check it can still read `pendingPrune`, delete rows, and later overwrite pending state in
  separate main-actor hops. A newer emission can interleave in that window, so an old task compares against
  **stale absence state** and deletes after what is effectively only **one** current consecutive absence. The
  source files are safe (these are disposable indexes) but search results can vanish until reindexing.
  **Fix:** add the missing **post-cancellation generation gate** — stamp each prune task with a generation and
  make every write (row delete + `pendingPrune` update) a no-op if the generation is no longer current.
  W6.1b and the Notes prune work are marked fixed by cancellation + a two-emission gate; this is a **residual
  race in that fix**, not a duplicate. ⚠️ Codex confirmed the missing gate **by inspection only** — it did not
  run a deterministic race fixture; re-confirm, ideally with one.
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndexer.swift, ArchiveNotes/macOS/Sources/ArchiveNotes/Index/NotesIndexer.swift | S | low | none
- [x] **W23.l3 — concurrent first-time root-marker creation can orphan newly copied links [S · LOW · SHARED
  CORE].** ✅ DONE `fa8bc02` + this commit — folded into **W23.m6** as this
  entry anticipated. The absence check moved *inside* the write claim and a racer that finds a winner adopts
  it. Codex's inspection-only finding is now reproduced by a deterministic fixture:
  `RootMarkerDurabilityTests.concurrentFirstTimeEnsureAgreesWithWhatLandedOnDisk` — with the old ordering,
  8 concurrent callers were handed 8 different GUIDs while one landed on disk (RED 3 runs out of 3). `packages/ArchiveCore/.../Links/RootMarker.swift` → `ensure`. It checks for absence **before**
  entering write coordination, generates a UUID, then blindly writes it. Two processes can both observe
  absence and serialize writes of **different** markers: process A can re-read and return A before process B
  writes B as the final disk value — so A-based links get copied even though the root ultimately identifies as
  **B**. Sequential idempotency + the final re-read do **not** close this cross-process check-then-write race.
  **Fix:** do the absence check **inside** the write coordination and create exclusively
  (`O_EXCL`-equivalent / coordinated read-then-write in one critical section); on losing the race, adopt the
  winner's marker. ⚠️ Shared-Core rule: build+test all three apps + `swift test` in `packages/ArchiveCore`.
  W15's per-path serialization is Finder-tag writes and in-process callers only. Natural companion to
  **W23.m6** (same file) — if m6 lands first, fold this in.
  | files: packages/ArchiveCore/Sources/ArchiveCore/Links/RootMarker.swift | S | low | none
- [x] **W23.l4 — Notes accepts impossible day-precision calendar dates [XS–S · LOW].**
  ✅ DONE `dee05ab` (the calendar) + this commit (the three seams + trackers). **The finding named two seams;
  there are three.** `ZoteroAutoFill.mappedDate()` carried the identical independent `1…31` check, and it
  matters more there: `AutoFillPlan.apply` writes `date`/`date_precision` straight onto the item, so
  `Item.normalizedDate` never sees it — a CSL record saying `date-parts: [[1968, 2, 31]]` was the one path
  where nothing downstream could catch the day. All three now ask one new `GregorianDay`.
  **`Calendar` is the wrong tool here, measured not assumed.** `DateComponents.isValidDate(in:)` — identically
  for `.gregorian` and `.iso8601`, both ICU Julian→Gregorian hybrids — calls `1500-02-29` **valid** (a Julian
  leap year), so it would not have closed the bug before the cutover, and calls `1582-10-10` **invalid** (ICU
  deletes the ten cutover days), so it would have silently rejected a real date off an early-modern document.
  `Calendar.current` is additionally locale-dependent. `GregorianDay` is therefore plain arithmetic, and
  February takes 29 days when the year is a leap year under **either reckoning that could have produced the
  date** — proleptic Gregorian, or Julian before 1582. The 1582 boundary is a stated trade-off: regions on the
  old calendar into the 20th century did have `1900-02-29`, but honoring that re-admits the likeliest modern
  typo. **Coarsen, never clamp:** `2026-02-31` ⟹ `2026-02` at month precision, which states what is known,
  where clamping to Feb 28 would assert a day the source never said. That reuses the downgrade rule
  `normalizedDate` already had for a missing component, so no new behavior category. ArchiveCore's shared
  `sortDateKey` was **not** touched (per the item's constraint) → shared-core rebuild rule N/A.
  **The month menu, not the "Set" button, was the live path**: the picker commits on selection, so choosing
  February with 31 already typed reached the store with no button to intercept — so the compose rule refuses
  the day and an inline orange note (`an.detail.date.dayWarning`) says *"February 2026 has 28 days — the day is
  ignored."*, and the day row's Set goes dead only for a day that month cannot have (its old cases, incl. no
  month chosen, still commit). The view's field rules moved into a pure `DateFieldEntry` so they are testable
  without a window; the view is now just `@State` + bindings, and no UITest is needed for the logic.
  **+33 tests, Notes 693/693, clean build, 0 new warnings.** `GregorianDayTests` (month lengths, century/400,
  day 0/32, month 0/13, the pre-cutover carve-out, the cutover gap, and two equivalence sweeps against
  Foundation over the post-1582 range where Foundation is trustworthy); `DateFieldEntryTests` (incl. the
  month-menu path and a cross-product proving a live Set and a shown warning are mutually exclusive);
  `FrontMatterDateWriteTests` +4 driving the real model → `NoteStore` → front-matter path on a scratch store,
  incl. every real month-end surviving at day precision; `ZoteroAutoFillTests` +3 through `apply()`. Every
  impossible-day case also re-runs the pre-fix predicate and asserts it said yes, so none can pass vacuously.
  Read path deliberately untouched: a `date:` a human hand-edited into a note file is their data, and its sort
  key is harmless (`20260231` lands between Feb 28 and Mar 1).
  **GUI (off the owner's screen, `ops/gui/vm-gui-runner.sh notes both`):** Notes UITests in the Tart VM =
  **12 executed, 8 passed, 4 failures — exactly the tabled deterministic G3/G6/G8/G11** (`ArchiveNotes/
  KNOWN_ISSUES.md`), so no regression; the sighted VNC capture shows the app launching and drawing (list +
  Date column) with this change in the build. **Stated plainly: no UITest drives the metadata strip**, so the
  new warning row's pixels were not eyeballed — its logic is what `DateFieldEntryTests` pins, and a 10-second
  owner check is in Morning Review. Also found: `vm-gui-runner.sh` reports `VM 'archive-gui-runner' not found`
  when `tart` merely isn't on a non-login shell's PATH — a misdiagnosis worth folding into W21.vmgui-a's
  "make it LOUD" work (`export PATH=/opt/homebrew/bin:$PATH` first). Original finding follows.
  `Views/NoteMetadataInspector.swift`, `Store/Item.swift`. The UI and normalization logic validate month as
  1…12 and day as 1…31 **independently**, never validating the combination against a calendar — so
  `2026-02-31` is persisted as a day-precision date and receives a normal chronological sort key.
  **Fix:** validate the (year, month, day) triple against `Calendar` before accepting/normalizing; reject or
  clamp with a visible message. ⚠️ Sort keys come from ArchiveCore's shared
  `DocumentTags.sortDateKey(year:month:day:decade:)` — **validate at the input seam, do not change the shared
  sort formula.** No current Notes date-validation item covers impossible combinations.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Views/NoteMetadataInspector,Store/Item}.swift | XS–S | low | none
- [x] **W23.h5-fu — Process Files still can't tell a placeholder PDF from a real one (the signal now exists;
  nothing there reads it) [XS–S · LOW].** ✅ DONE inside **W23.m5** exactly as this entry required —
  `ff792a9` (all five `generate` call sites now capture `ImagePageOutcome`, surfaced through W23.m5's
  per-run warning channel, not a second one) + `4cf1fb7` (keyed to the source photo, which is the page
  to re-run) + this commit (trackers). The multi-page re-OCR assembly reports a placeholder if ANY page
  fell back; the merged-PDF case keeps the warning against the photo it came from; a regen that embeds
  the scan clears it. Covered by `scripts/test-processfiles-tagwarn.sh` (a real `PDFGenerator` run on a
  decodable vs. an undecodable image drives the record end to end; the PDF is still written with both
  pages and the source image is confirmed untouched). Original finding below.
  Found 2026-07-30 while fixing W23.h5.
  *(The `blocked-on` was added 2026-07-31: the prose below already said "do this inside W23.m5", but with no
  machine-readable dependency `next-queue-item.sh` offered h5-fu as actionable AHEAD of m5 — which would have
  produced exactly the second warning channel this item forbids.)* `PDFGenerator.generate` now
  returns `ImagePageOutcome`, but the change was kept `@discardableResult` so the **five Process Files call
  sites** (`OCRProcessor+{OCR,Pipeline,Tagging,ReviewFlows}`) compile untouched — they still treat "didn't
  throw" as full success and will happily report a scan-less PDF as a clean result. **Deliberately NOT data
  loss, which is why this is LOW and not a re-open:** unlike Live Capture, that path never trashes the source
  image (checked by symbol — no `trashItem`/`removeItem` on a source URL in the OCR pipeline; source cleanup
  goes through `OutputFileSafety`'s verified-move transaction, which relocates rather than destroys). So the
  gap is **operator visibility**, not recoverability. **Do this inside W23.m5**, which already rewrites those
  exact call sites for the `tagsApplied` warning — surface "image not embedded" through the same per-artifact
  warning channel rather than adding a second one. Cheap there, wasteful as its own pass.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+{OCR,Pipeline,Tagging,ReviewFlows}.swift | XS–S | low | W23.h5


## Provider expansion — Wave 13 (Processor; daemon-buildable) — queued 2026-07-16

- [x] **W13.oai-1 — native provider wiring.** Append `case openai` to `LLMProvider` (append-only), add
  `LLMModel.openaiModels` + the model-family param adapter (`max_completion_tokens`/no-`temperature`/
  `reasoning_effort`), route `.openai` through the reused `OpenAICompatibleClient` at the ~6–8 switch sites.
  ⚠️ Model IDs + pricing = clearly-marked `// VERIFY` placeholders (a wrong price is a silent estimator bug →
  Morning Review). | files: Models/ProviderModels.swift, OCR/OCRProcessor+OCR.swift, OCR/LLMTextClient.swift,
  OCR/LLMRotationDetector.swift, Models/KeychainHelper.swift | M | low | none
  — ✅ shipped: `.openai = "OpenAI"` appended; `openaiModels` (all IDs/pricing `// VERIFY`); param adapter
  (`OpenAICompatibleClient.openAI(model:apiKey:)` → `max_completion_tokens` for reasoning models, gateway path
  byte-identical); `.openai` arms added to all **12** exhaustive `LLMProvider` switches (OCR/classify/text route
  via the factory; batch/cancel/rotation defensive-`nil` since `supportsBatch=false`; CostEstimator image-tokens
  placeholder + rotation `nil`). Additive + opt-in — default provider unchanged. KeychainHelper needed no change
  (account = `provider.rawValue`). Build clean, 0 new warnings. **Live OCR + model-ID/pricing verification =
  keyed/owner tail → Morning Review** (Processor has no unit target; smoke needs a live key). ProviderKeySpec /
  onboarding / validation / CostEstimator rows = W13.oai-2; gateway preset + docs = W13.oai-3.
- [x] **W13.oai-2 — onboarding + validation + cost.** `ProviderKeySpec.openai` (+ `onboardable`),
  `KeyValidator.validateOpenAI` (`GET /v1/models`), `ThinkingLevel → reasoning_effort`, `CostEstimator` rows
  (placeholder-priced per above). | files: Models/ProviderKeySpec.swift, OCR/KeyValidator.swift, Models/CostEstimator.swift | S | low | none
  — ✅ shipped: `ProviderKeySpec.openai` added to `onboardable` (guided wizard now offers OpenAI: platform.openai.com
  deep links, `sk-` precheck, no-free-tier cost/card notes, API-not-trained privacy note; URLs/wording `// VERIFY`
  → keyed tail). `KeyValidator.validateOpenAI` (cheap `GET /v1/models` Bearer → 200 works / 401·403 invalidKey /
  429 rateLimited / 5xx providerBusy; mirrors `validateMistral`; documents that /v1/models 200s even with no
  credits → live smoke surfaces insufficient-quota). `ThinkingLevel.openAIReasoningEffort` (low/high) wired through
  the `openAI(model:apiKey:thinkingLevel:)` factory, **gated on `supportsThinking`** so `reasoning_effort` is sent
  only to reasoning models; threaded at the OCR + tagging-text call sites (classification stays reasoning-free).
  Settings gained an **OpenAI manual key field** (generic `keyField` helper, Save/Validated chips) + guided-button/
  help wording; `ContentView.hasAnyKey` counts an OpenAI key. `CostEstimator` `.openai` arms already landed in
  oai-1. Additive + opt-in — default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **GUI visual (Settings OpenAI row + wizard) + live OCR smoke = keyed/owner tail → Morning Review** (GUI blocked
  this run by the Keychain "Always Allow" seed still being unset under the stable dev cert).
- [x] **W13.oai-3 — gateway "OpenAI" preset + docs.** One-click preset prefilling base URL/model/cost (note:
  custom base URL covers Azure OpenAI / proxies); update CLAUDE.md provider list + README. | files: Views/SettingsView.swift, docs | S | low | none
  — ✅ shipped (code `d866924`; docs/tracker this commit): a **"Fill in OpenAI preset"** button in the
  API-Gateway settings section (`Views/SettingsView.swift` → new `applyOpenAIGatewayPreset()`) prefills the
  public OpenAI endpoint (`https://api.openai.com/v1`), the default model, a display name, and the `.openai`
  cost profile — reading the model ID + pricing from the single source of truth `LLMModel.openaiModels`
  (now the verified GPT-5 gen from `3be8c3d`), so a later pricing/ID edit flows through automatically. It fills
  the cheapest **non-reasoning** model (`gpt-5.4-mini`): the gateway path sends plain `max_tokens`, which OpenAI
  reasoning models reject — the param adapter lives only on the native `.openai` path — so reasoning models go
  via Direct API. A
  HelpButton notes a custom base URL covers **Azure OpenAI / OpenAI-compatible proxies** and that the key goes
  in the Gateway key field. Docs in this commit: Processor **CLAUDE.md** (OpenAI added to the built-in
  provider/model list + the preset note), **README** (4th provider row + table + preset + batch/key-field
  accuracy), **POTENTIAL_FEATURES** (retired the first-class-OpenAI wishlist item). **Plan
  `execution-plans/openai-chatgpt-provider.md` DELETED** — all daemon-buildable OpenAI sub-tasks (W13.oai-1/2/3)
  shipped. Additive + opt-in; default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **Keyed/owner tail → Morning Review:** the live-key 2-image OCR smoke through gateway + native `.openai`
  (final model-ID confirmation) + OpenAI Batch API (Phase 4); GUI visual (preset button + field fill) deferred
  (GUI off this run).
- [x] **W13.cli-1 — client + config + additive threading.** `472f850` (config) + `9778572` (client) + `02471bb`
  (threading) + `44730bc` (tests) — `Models/LocalAgentConfig.swift` (Codable/Sendable, append-only
  `LocalAgentTool` claude/gemini/codex, no key) + `OCR/LocalAgentClient.swift` (ocr + textCompletion via
  `Process`: no shell, prompt on stdin not argv, absolute-path binary not `$PATH`, temp-JPEG-by-path,
  concurrent-drain + SIGTERM→SIGKILL timeout, friendly errors never raw stderr; `claude` validated, gemini/codex
  `// VERIFY`) + `localAgent: LocalAgentConfig?` (default nil) threaded into `PendingRun` + `SessionProcessingConfig`
  beside gateway. Tests: committed fake-CLI stub + `localagent-mechanism-test.swift` (standalone $0, **14/14 PASS
  this session** — subprocess plumbing + resume-safety Codable semantics) + in-app `LocalAgentTestDriver` (real
  client + real PendingRun round-trip; RUN via `test-localagent.sh` **deferred → Morning Review**, GUI-off). Tier-2
  gate met unattended (adversarial review + headless functional proof + build clean, 0 warnings). | M | med | none
- [x] **W13.cli-2 — validator + Settings.** `a2be2c7` (checkpoint 1/2: validator+probe) + this commit
  (checkpoint 2/2: Settings). `OCR/LocalAgentValidator.swift` — CLI analog of `KeyValidator`: `detectAndVerify`
  does resolve-binary → `--version` liveness → 1-token round-trip and maps to a plain-English `Status`
  (`cliNotFound`/`cliNotLoggedIn`/`cliEntitlementMissing` + reused `rateLimited`/`offline`/`providerBusy`);
  pure `classify` code→Status. `LocalAgentClient` gained public `probe()`+`ProbeOutcome` (prompt-only round-trip,
  no image ⇒ zero corpus surface) + `cli_entitlement_missing` in the shared error taxonomy (never raw stderr;
  preserves the `fail`→`cli_exit_3`/`notlogged`→`cli_not_logged_in` invariants). Settings: a 3-way **OCR backend**
  picker (Direct API / API Gateway / **Local CLI Agent**) over a `backendMode` binding that centralizes the
  `useLocalAgent` XOR `useGateway` invariant; tool picker + path/model fields + a **Detect & Verify** button
  (wired to the validator) + `?` help; additive `DefaultsKeys`. Additive + opt-in; default backend unchanged.
  **Tier-2** gate met unattended: build clean 0 new warnings + `$0`/no-key/no-GUI `scripts/localagent-validator-test.swift`
  (**27/27 PASS** — exhausts the code taxonomy incl. entitlement + drives the real fake CLI e2e) + adversarial
  self-review. **Interim state (until W13.cli-4 wires the pipeline):** selecting Local Agent mode *persists* the
  config but the pipeline still routes Direct/Gateway (config inert, same as cli-1's threaded-but-unconsumed
  carrier). Live Detect+Verify round-trip + visual gray-out + the cost-pane "subscription" branch (cli-3) →
  GUI/Morning Review. | M | low | none
- [x] **W13.cli-3 — wizard + cost pane + pacing.** `03e65ec` (pacing) + `971c9fd` (wizard) + `584eb32`
  (cost pane). **PACING:** `LocalAgentClient` wraps `invoke()` in a dedicated `RequestLimiter(limit: 2)` (the
  subprocess path bypasses `NetworkSession`'s HTTP limiter) + `parseUsageWindowReset()` reads a reset instant
  out of a CLI rate-limit message (relative / bare-Retry-After / absolute "resets 3pm", with a
  window-size-vs-wait guard + next-occurrence rollover) into `lastUsageWindowResetAt`; the finer per-run 1–2
  cap + OCR-loop honoring land in cli-4. **WIZARD:** `LocalAgentSpec` (claude + gemini; Codex stays on the
  Settings tool picker) + `LocalAgentWizard` (mirrors `ProviderKeyWizard`) wired into Settings via a "Set up
  (guided)…" button + sheet. **COST:** "Included in your subscription — usage limits apply" branch in the
  SettingsView pinned pane + the OCRView Files-tab card (display-only — Local Agent isn't an `LLMProvider`, no
  `CostEstimator` math change). **Tier-2 gate met unattended:** build clean 0 new warnings +
  `scripts/localagent-pacing-test.swift` **18/18 PASS** ($0/no-key/no-GUI: parser table incl.
  guards/rollover/nil + the `RequestLimiter(2)` ceiling holds & every acquire is released) + adversarial
  self-review. **Keyed/GUI tail → Morning Review:** live wizard Detect+Verify + cost-pane/wizard visual (a
  GUI launch this session hit the blocking Keychain modal — owner "Always Allow" seed still needed) +
  install-link/wording verify. | S | low | none
- [x] **W13.cli-4 — pipeline wiring.** `4ee2475` (ckpt1: seams) + `23166b9` (ckpt2: thread+populate) + this
  doc-sync commit. `LocalAgentConfig.fromDefaults` + `currentLocalAgent` mirror; client-construction seams
  (`LLMTextClient.complete`, `performOCRCall`, `classifyViaLLM`) prefer `localAgent` (localAgent > gateway >
  direct); threaded the companion `localAgent:` beside every `gatewayConfig` (TagGenerator, CollectionSegmenter,
  the OCRProcessor OCR/Tagging/Pipeline/ReviewFlows sites, multi-page re-OCR, LiveCaptureProcessor, OCRView,
  ToolsView, `SessionProcessingConfig.fromDefaults`). **Batch + LLM-rotation skipped when active** (OCRView forces
  batchMode=false + defensive dispatch/history guards; `detectRotation` → local Vision). **Resume-safe:** the
  production `PendingRun` persists `localAgent` and both fresh-run + resume paths restore `currentLocalAgent`
  (self-review caught both were missing). `test-smoke.sh` gains a `[3.5]` **fake-CLI** section (runs the $0
  standalone tests + real-CLI probe with graceful skip). Build clean, 0 new warnings; Tier-2 gate met unattended
  (adversarial self-review + `localagent-wiring-test.swift` 18/18 + `localagent-mechanism-test.swift` 14/14).
  Plan `execution-plans/local-agent-cli-provider.md` DELETED (shipped). **Keyed/owner tail → below.** | M | med | none


## Known-issues work — Wave 14 (cross-app; owner-requested 2026-07-16)

- [x] **W14.1 — Android/iOS straggler: never finalize a partial segment [HIGH]** _(Processor KNOWN_ISSUES →
  "Per-capture streaming — residual refinements" #1; focus path: Android + LAN)._ The data-loss guard already
  ships (a straggler is never deleted), but a page still un-UPLOADED when `segment/complete` arrives is **not
  auto-filed** — it lingers unfiled in the Captured pane. **Fix (both companions, kept in sync):** the phone
  **defers `sendSegmentComplete`** (and `finishSession`'s `/session/complete`) until **every page of the segment
  is confirmed `UPLOADED`** — record a pending-complete group, flush it when its last page hits `UPLOADED` from
  BOTH the upload-success path and the auto-retry path. So the Mac never finalizes a partial segment. **Tier-2**
  (Capture/Net, phone↔Mac protocol — no wire-format change: this is send-*timing*, not a new field). Daemon-buildable:
  Android `./gradlew :app:assembleDebug` + iOS `xcodebuild` build-clean + adversarial self-review of the
  defer/flush logic on both companions. **Keyed/owner verify tail:** the on-device / emulator E2E
  (`scripts/e2e-phone-mac.sh`, needs a Gemini key + the `ap_test36` emulator; XCUITest admin-prompt caveat) →
  Morning Review. | files: ArchiveCapture/capture/CaptureViewModel.kt, ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift | M | med | none(build)/owner(E2E)
  **✅ ALREADY SHIPPED `ce55511` (2026-07-07); verified + tracker-reconciled 2026-07-17.** The defer/flush fix
  was already in code on BOTH companions: `endedSegments` is the pending-complete record; `trySendSegmentComplete`
  gates on ALL pages `UPLOADED` (Android `CaptureViewModel.kt:527` / iOS `:369`) and is the ONLY caller of the
  transport `segmentComplete(...)` — flushed from the upload-success path (Android `:622` / iOS `:456`), the
  auto-retry loop (Android `:229` / iOS `:524`), and reconnect (`:209`/`:508`). The `session/complete` this item
  also named is **dead code** on the phone (the transport `sessionComplete()` has no caller — the phone "Finish"
  button that once sent it was removed; "Finish session" is a Mac-side backstop). Adversarial refutation (independent
  read of both companion trees) could not break the gate on either side. KNOWN_ISSUES #1 marked FIXED-in-code to
  match #2/#3/#4. **Keyed/owner tail unchanged:** on-device/emulator E2E (`scripts/e2e-phone-mac.sh`) → Morning Review.
- [x] **W14.2 — Reader write-target identity re-verification (Safety §6) [MED]** — shipped `838b456` (primitive)
  + `d393ff3` (Reader adapter). Added opaque `FileIdentity` (backed by `fileResourceIdentifier`, compared via
  `isEqual:` — **never** `.documentIdentifierKey`, which mutates on read) + an opt-in `expectedIdentity:` param on
  `CoordinatedTagWriter.write` that **re-verifies the resolved URL's identity inside the `NSFileCoordinator` block
  before any write and aborts with `.identityMismatch`** on a moved/replaced file; threaded `expecting:` through the
  Reader `TagWriter.apply`/`setReadState` adapter (default nil = behavior-preserving). Tier-2 gate met unattended:
  build clean, 0 new warnings; +8 scratch-copy tests (4 primitive + 4 adapter; the deterministic safety case =
  a *different* file at the same path → abort + replacement untouched) — ArchiveCore 100 green (stable ×3),
  ArchiveReaderTests 23 green. **Follow-up (armed below):** wire capture-at-selection at live call sites so the
  mechanism is armed in production — see "W14.2-fu". | M | med | none
- [x] **W14.2-fu — Arm §6 identity check at live Reader call sites [MED, follow-on to W14.2]** — shipped
  `1a7c6cb` (checkpoint: `ArchiveFile.liveIdentity()` on-demand capture + the identity-carrying
  `TagWriter.apply(_:to:[(url,identity)])` batch overload + a scratch-copy test) + this commit (arming +
  docs). All **6** `NavigationModel` `TagWriter.apply`/`setReadState` call sites — `mark`, group edit
  (⌘I), inline edit/read-state, corpus-wide rename (via the batch overload), and **undo** — now capture
  the file's `FileIdentity` **lazily at edit time** (via `liveIdentity()`, never at bulk discovery, so the
  `ArchiveFile` "no per-file I/O" fast path is untouched) and pass it through `expecting:`. Undo re-verifies
  against the identity captured at the ORIGINAL edit (undo stack now carries per-write identity), so a file
  swapped under its path between edit and undo is skipped, not mis-tagged. **Tier-2 gate met unattended:**
  build clean, 0 new warnings; behavior-preserving threading (identical accounting) + the §6 write-path is
  fully unit-tested on scratch copies (existing 3 §6 adapter tests + the new batch test) + adversarial
  self-review; ArchiveReaderTests 199/200 (the 1 failure is the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot`
  env flake, unrelated). No visible UI effect (invisible safety guard, only fires on a file swap), so no
  GUI drive; an optional live regression smoke on a scratch corpus → Morning Review. | files: ArchiveReader
  Views/NavigationModel.swift, Core/ArchiveFile.swift, Core/TagWriter.swift | done
- [x] **W14.3 — Notes: extract-paste imports inline-image BYTES [MED]** _(Notes KNOWN_ISSUES → "Extracts
  create/copy-paste follow-ups")._ The copy side embeds image bytes and Create/Append persist them, but the live
  extract-editor **paste** handler still inserts image *references* without importing the payload's bytes into the
  extract's own `assets/` (and rewriting refs on name collision) — so a live copy→paste renders missing-asset
  placeholders until re-saved via Create/Append. **Fix:** in `MarkdownEditorView.handlePassagePaste` →
  `ExtractBuilder.pastedExtractMarkdown`, import the `com.archivenotes.passage` payload bytes into the extract's
  `assets/` (reuse `ItemAssetStore` reserve→write; no-overwrite guard) and rewrite refs on collision. Store +
  payload bytes both already exist. **Tier-1/2** (writes to the Notes store — scratch-testable). Daemon-buildable +
  unit-testable (`ExtractBuilder`/`ItemAssetStore` tests); GUI copy→paste drive → Morning Review. | files:
  ArchiveNotes/.../Editor/MarkdownEditorView.swift, Core/ExtractBuilder.swift | done — new
  `pastedExtractMarkdown(from:importingAssetsVia:)` overload imports each segment's bytes into the extract's own
  `assets/` via `ItemAssetStore.addAsset` (reserve→write, no-overwrite guard) + rewrites `](assets/…)` refs on
  collision; `handlePassagePaste` wires it in. +3 scratch Tier-2 tests (byte-on-disk, no-clobber disambiguation,
  nil-import resilience); full ArchiveNotesTests green (189 XCTest + 513 swift-testing). Also unbroke the Notes
  test bundle (`67f8938`: W14.2's new `TagWriteError.identityMismatch`). GUI copy→paste drive → Morning Review.
- [x] **W14.4 — Notes W7 polish cluster [LOW]** ✅ COMPLETE 2026-07-17 (`592049a` a + `7ef833d` d + `d615589` c +
  this commit b/docs) _(Notes KNOWN_ISSUES → W7-S2/S3/S4 follow-ups, all four addressed)._ (a) dropped the
  always-succeeds `[NSValue]` cast in `EditorPassageSource` (warning gone); (b) `NoteEditorPane.handleOpen` now
  fronts+focuses the featuring window (`openWindow(id:)` + `NSApp.activate`) on jump-to-source, and
  `NotesModel.create/appendToExtract` route the new/updated extract through `openItem` so the Extracts window
  selects (and raises) it; (c) new `NotesModel.itemsGeneration` (bumped in `replaceItems`) drives a reactive
  chip re-style in `MarkdownEditorView` on any item-set change — gated to chip-bearing docs, scroll preserved;
  (d) per-window `NotesAppSettings.windowHiddenColumns(for:)` (Note window hides the always-blank Sources
  column, Extracts shows it), wired through `NotesTableView`/`ColumnPickerHeaderView`. +7 unit tests; full Notes
  unit suite 709 green (520 swift-testing + 189 XCTest), build clean 0 new warnings. **Tier-1.** **Live GUI drive
  → Morning Review:** window raise/focus (b), cross-window chip recolor (c), two-window column visibility (d).
- [x] **W14.5 — Processor legacy staging-manifest rotation review [LOW, do last]** ✅ COMPLETE 2026-07-17
  (Processor KNOWN_ISSUES #1). Fix option 1 shipped: `loadStagingManifest()` now migrates a legacy manifest
  (bare `[StagedSegment]`, no `retained`) via new `migrateLegacyManifestSegments(_:sourcesPresent:)` — it
  DROPS each legacy segment whose source photos all still exist (deleting its stale staged output) so the
  existing resume path re-processes it from scratch (re-OCR + re-tag → proper `retained` → a COMPLETE rotation
  review), then rewrites the manifest in current format (idempotent). **Data safety (Recovery Core Directive):**
  a legacy segment whose source is gone is KEPT as-is (today's behavior) — we never delete regenerable output we
  can no longer rebuild; raw sources always stay in the backup folder. Tier-2 met unattended: build clean, 0 new
  warnings; +5 scratch checks in `LiveCaptureRecoveryTestDriver` (drop-reprocessable / keep-unreprocessable /
  delete-stale-output / preserve-unrecoverable) → **ALL PASS ($0, no OCR)** + adversarial self-review (confirmed
  `session.groups` is computed from `session.photos`, so dropped segments' pages are guaranteed present to
  re-OCR). **Full E2E verify (legacy manifest + OCR key to actually reprocess) → keyed/owner → Morning Review.**
  | files: Capture/LiveCaptureProcessor.swift, Capture/LiveCaptureRecoveryTestDriver.swift | S | low | owner(verify)


## Known-issues work — Wave 15 (shared tag writer; owner-reviewed 2026-07-18)

- [x] **W15.tu0 — pin the macOS duplicate-tag fact in SPEC + a test [S].** DONE 2026-07-29 — added
  `ArchiveCoreTests/DuplicateTagPremiseTests` (hard-asserts `["A","A","B"]` survives a raw
  `setResourceValue(.tagNamesKey)` write→read round-trip on a scratch temp file — the test RAN, not skipped)
  and recorded the fact in `SPEC/tag-format.md` §"Finder tag model" beside the multiset-comparison rule
  (duplicate tag strings persist verbatim; a `Set`-collapse would drop a duplicate on undo — the premise all
  of Wave 15 rests on). Pure test + doc, **no behavior change, no ArchiveCore Sources/API touched** → app
  bundles unaffected (shared-Core rebuild rule's type-change trigger not met), so ArchiveCore `swift test` is
  the correct-and-sufficient gate: premise test 1/1 green + full suite exit 0, **0 warnings**. Tier-2 APPROVE
  (adversarial self-review + scratch functional test; never the corpus).
  | files: packages/ArchiveCore/Tests/ArchiveCoreTests/DuplicateTagPremiseTests.swift, SPEC/tag-format.md | S | low | none
- [x] **W15.tu1 — occurrence-aware undo inverse in ArchiveCore [M].** DONE 2026-07-28 (recovered from a
  preserved dead-session WIP — `old/w15tu1-divergent-wip-20260728/attemptA` — and independently re-verified).
  New `TagOccurrenceDelta` (multiset peer to `TagDelta`) + `TagWriteResult.occurrenceInverse`, computed via
  `tagOccurrenceInverse` / `multisetDifference` (no `Set` collapse), so an inverse carries per-token
  multiplicity (`["A","A"]`→`[]` undoes to `["A","A"]`, not `["A"]`). Purely ADDITIVE — `inverse: TagDelta`
  and all consumers untouched (new init param defaulted); occurrence-only (count, not order). Verified HERE
  (not the WIP's self-claim): ArchiveCore `swift test` 100/100 green incl. 6 new W15.tu1 tests (the
  end-to-end duplicate test RAN, not skipped — macOS persisted the dup); all three app test bundles
  `build-for-testing` SUCCEEDED; 0 new warnings. NOTE: W15.tu0 (SPEC doc + premise test) landed separately
  (DONE 2026-07-29); the undo/restore consumers are rewired in W15.tu2.
  | files: packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift | M | med | none
- [x] **W15.tu2 — multiplicity-aware apply/restore + wire Reader undo** (blocked-on: W15.tu1) **[M].** DONE
  2026-07-28. Added `TagWriter.applyOccurrence(_:to:expecting:)` — a **bounded reconcile step**: an
  occurrence-precise multiset diff against the FRESH read inside `CoordinatedTagWriter`'s coordination block
  (§2/§3), stripping EXACTLY the delta's occurrence count of each removed token and APPENDING the listed
  copies of each added token, so it re-introduces a duplicate the set-based `apply` (add-when-absent,
  `TagWriter.swift:52`) refuses to. Wired `NavigationModel.undoLast` to `result.occurrenceInverse` +
  `applyOccurrence` (was the set-based `result.inverse`, the sole production consumer). **Safety §9
  preserved** — only named tokens are touched, each by ≤ its listed multiplicity, so an unrelated concurrent
  edit (and any extra copy a concurrent edit added of a named token) survives; undo stays in-memory (no
  persisted ledger). Behavior-identical for the common non-duplicate case; §6 identity re-verify unchanged.
  Tier-2 APPROVE (adversarial self-review, 11 vectors). Verified: Reader `ArchiveReaderTests` 210/211 green
  incl. 5 new occurrence tests (`["A","A","B"]` round-trips; §9 concurrent-survive; exact-count strip; color
  restore) — the 1 failure is the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot` env flake (W20),
  unrelated; Notes test bundle + Processor app build green; 0 new warnings. (Umbrella KNOWN_ISSUE stays open
  for tu3/tu4.)
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Core/TagWriter.swift, Views/NavigationModel.swift | M | med | none
- [x] **W15.tu3 — per-path write serialization → closes the Notes lost-update race** (blocked-on: W15.tu1)
  **[M].** DONE 2026-07-28 (mechanism `f52756d`; doc-sync this commit). Added an in-process,
  per-resolved-path serialization lock INSIDE `ArchiveCore.CoordinatedTagWriter` (Safety §10): a refcounted
  registry of per-path `NSLock`s (`PathWriteSerializer`) wraps the ENTIRE read→modify→verify→write, so two
  concurrent in-process writers to the same file can no longer both read pre-write state and clobber each
  other (the lost update). Distinct paths never contend (unrelated writes stay parallel); an entry is
  discarded once its last holder releases (bounded map). Synchronous `NSLock`, not an actor — keeps `write`
  synchronous so all three callers (Reader `TagWriter`, Processor `MacOSTagger`, Notes `NotesTagProjector`)
  are unchanged; public API is byte-identical (additive). **Cross-PROCESS writers explicitly out of scope**
  (documented in code, not implied). Tier-2 APPROVE (adversarial self-review: deadlock/lock-ordering,
  refcount handoff, balanced acquire/release via `defer`, unchanged single-writer semantics). Functional
  test (ArchiveCore, scratch temp files only): two concurrent same-path writers each appending a distinct
  tag BOTH survive — PROVEN non-vacuous (fails deterministically, racing tag lost, when the §10 lock is
  removed); plus a different-paths fan-out. Verified all three per the shared-Core rule: ArchiveCore 101
  tests green (incl. 2 new §10); Reader `ArchiveReaderTests` 210/211 (the 1 = pre-existing
  `DeepLinkTests.testRevealAndSelectNoRoot` env flake, W20, unrelated); Notes `ArchiveNotesTests` 189/189;
  Processor app BUILD SUCCEEDED; 0 new warnings. Notes KNOWN_ISSUES race marked FIXED (mechanism); the
  cross-app fixture matrix + Notes `concurrentProjectionsNeverCorrupt` assertion flip land in W15.tu4.
  | files: packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift, ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesTagProjector.swift | M | med | none
- [x] **W15.tu4 — cross-app duplicate + concurrency fixtures** (blocked-on: W15.tu2, W15.tu3) **[M].** DONE
  2026-07-28. Cross-app regression matrix pinning the W15 duplicate-survival + no-lost-update fixes at each
  real caller, honoring each adapter's shape: **(a)/(b)** the dup→remove→undo→multiset-survives and
  concurrent-unrelated-tag-survives cases were already pinned at the Reader `TagWriter` boundary by W15.tu2
  (`testOccurrenceInverseRestoresDuplicateTag`, `testOccurrenceUndoPreservesConcurrentUnrelatedTag`) and at
  the ArchiveCore primitive by W15.tu1; this wave ADDED the fresh-write analog for the Processor `MacOSTagger`
  adapter (which has no undo path) — a *duplicated subject survives a fresh write as a multiset*
  (`MacOSTaggerParityTests.testDuplicateSubjectSurvivesFreshWrite`). **(c)** two parallel same-path writes:
  ADDED a Reader `TagWriter` concurrent fixture (both added tags survive — the delta adapter inherits §10,
  `testConcurrentAdapterWritesBothSurvive`), a MacOSTagger concurrency parity fixture (fresh-write adapter:
  neither writer throws `.verificationFailed` and the final array is one complete write — "both survive"
  doesn't apply to an overwrite, `testConcurrentFreshWritesNeitherThrowsAndFinalIsWhole`), and **flipped**
  `NotesTagProjectorSafetyTests.concurrentProjectionsNeverCorrupt` to require **both racing subjects survive**
  (not just the marker) now that W15.tu3's §10 lock closed the lost update. Case (a) is N/A for the Notes
  projector (set-based, dedups, no undo — duplicates are unreachable through it by design). KNOWN_ISSUES
  reconciled (the race is now FIXED + regression-pinned). Gate MET: ArchiveCore `swift test` 103 XCTest + 100
  swift-testing green; Reader `ArchiveReaderTests` 212 (only the pre-existing `DeepLinkTests` env flake, W20,
  unrelated); Notes `ArchiveNotesTests` green; Processor app BUILD SUCCEEDED. Test/doc-only — no production
  change. Two Tier-2 checkpoints (`19228ee` ArchiveCore, `005fa96` Reader) pushed before this completing commit.
  | files: packages/ArchiveCore/Tests/, ArchiveReader/Tests/, ArchiveNotes/macOS/Tests/ | M | med | none


## Known-issues work — Wave 16 (Processor: LAN credential · run config · paid-batch; owner-reviewed 2026-07-18)

- [x] **W16.lan1 — write the LAN threat-model + accepted-risk doc [S].** DONE 2026-07-28 (this commit). Docs
  only, no code. Added a durable **LAN transport security — accepted risk** bullet to `ArchiveProcessor/CLAUDE.md`
  §"Primary Function 3: Live Capture": records the plaintext-HTTP + persistent-token exposure, the
  client-isolation correlation (venues that block LAN entirely are why USB/Drive exist → LAN runs precisely on
  the sniffable open/shared-PSK networks, so the low risk is *real*), the owner's accepted-risk rationale (public
  records → confidentiality ≈ worthless; integrity bounded by the Recovery Core Directive; needs a co-located
  adversary; do NOT re-promote LANSEC-5/6/7), operator guidance (USB bridge / Drive relay on untrusted venue
  Wi-Fi), a forward-ref to the W16.lan2 credential fix, and the corrected stale sub-item (`_archivecap._tcp` is
  advertised at `CaptureServer.swift:68` but **neither companion browses it** — no `NWBrowser`; pairing is
  QR-only). Also marked W16.lan1 DONE in `ArchiveProcessor/KNOWN_ISSUES.md` §"Live Capture LAN channel". Facts
  re-verified against the tree: the `:68` advertise, the `CaptureSession.swift:275-282` 31-char/~29.7-bit token,
  no companion `NWBrowser`, and the USB/Drive alternatives.
  | files: ArchiveProcessor/KNOWN_ISSUES.md, ArchiveProcessor/CLAUDE.md | S | low | none
- [x] **W16.lan2 — high-entropy LAN token + failed-auth throttle [S].** DONE 2026-07-28 (`c335abd` checkpoint +
  this commit). SPLIT the credentials per the owner decision: added `CaptureSession.lanToken` — a fresh **~158-bit**
  LAN credential (32 chars over the 31-symbol alphabet, CSPRNG-drawn via `randomElement()`, persisted under a new
  `LiveCaptureLANToken` key) — now authenticated by `CaptureServer` and carried in the QR's `token` field, while the
  6-char **Drive-relay `token` is untouched** (still `appProperties.relayToken` + QR `relay`; `SPEC/relay-object-format.md:38`
  + golden fixtures + the shipped Android transport ride on it). Added a **per-source failed-auth throttle**
  (`CaptureServer.AuthThrottle`: 5 free 401s → exponential backoff capped at 30 s, keyed per remote IP, fail-open on
  an undeterminable source, cleared on any authenticated request) so a hostile LAN peer can't sweep tokens at
  connection speed. Both companions parse `token` as opaque (Android `MacEndpoint.fromQrPayload`, iOS
  `MacEndpoint.decode` — non-empty check only), so the sole migration cost is **one QR re-scan per phone** for LAN;
  Cloud is unaffected. Tier-2 APPROVE (adversarial self-review; happy-path unaffected, per-IP isolation, bounded
  map, no new timing side-channel). Verified headlessly: standalone algorithm test (22 checks — token entropy + the
  full throttle schedule 2→4→8→16→30-capped + idle-reset + fail-open) PASS; committed `ManifestPersistenceTestDriver`
  W16.lan2 checks exercise the real types (run defers to the next smoke/VM — host app-launch is denied in the
  autonomous scope); Processor Debug build clean, 0 warnings. KNOWN_ISSUES §"Live Capture LAN channel" B marked FIXED.
  | files: Capture/CaptureSession.swift, Net/CaptureServer.swift, Views/LiveCaptureView.swift | S | med | none
- [x] **W16.cfg1 — make `SessionProcessingConfig` the single run config [S].** DONE 2026-07-29 (this commit).
  `SessionProcessingConfig` is now explicitly `Sendable`; its existing `fromDefaults()` builder snapshots
  `ocrWorkerCount` with the same 1…12 clamp/fallback of 4 as `OCRProcessor.loadStandardImageMB()`. A dedicated,
  then-unused `fromProcessFilesRunStart()` builder centralizes that method's complete normalization (worker
  count, all three finite 0.5…20 image sizes, and 1…4 text columns) for W16.cfg2/3 without changing Live Capture
  behavior in this checkpoint. The field defaults to 4 for the two direct Live Capture test-driver configs; no
  scheduling/output call site reads it yet. Kept app-local (no ArchiveCore/SPEC/protocol change). Processor
  Debug build succeeded with no new code warnings; the scratch-only manifest/config regression uses volatile
  defaults to cover the returned configs' worker wiring/bounds and complete Process Files normalization, and
  passed all checks.
  | files: Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift | S | low | none
- [x] **W16.cfg2 — thread the run config into OCR scheduling + PDF generation reads [M].** DONE 2026-07-29
  (this commit). Fresh Process Files runs now capture one normalized `SessionProcessingConfig` and pass it through
  multi-page re-OCR, paid-batch result materialization, sequential/parallel OCR, timeout/high-use retries, the
  interactive retry loop, and PDF writes. OCR calls receive its `standardImageMB`; schedulers use its bounded
  `ocrWorkerCount`; PDF generation uses its `pdfImageMB`/`textColumns`. The exact sizing/scheduling values used
  are also written to `PendingRunRuntimeConfig`, rather than re-read from globals. The processor retains the
  snapshot for the Files pane's post-run per-item Retry / Retry with model / Rotate & re-run actions (an
  adversarial-review catch). Resume paths explicitly pass nil and preserve the existing validated static fallback
  until W16.cfg5, so this checkpoint changes no recovery schema or legacy behavior. Debug build succeeded; the
  scratch config/manifest, multi-page PDF, and batch/non-batch resume suites all passed. The general smoke wrapper's
  two self-contained Local Agent checks passed; its unrelated build/launch/corpus stages remain unusable in an
  isolated worktree because the script assumes a nonexistent nested `ArchiveProcessor/` path and untracked
  `Test Files`. Tier-2 adversarial review approved after the per-item retry gap was fixed.
  | files: OCR/{OCRProcessor,OCRProcessor+OCR,OCRProcessor+Pipeline}.swift,
    Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver,MultiPageReOCRTestDriver}.swift | M | med | none
- [x] **W16.cfg3 — thread the run config into review/regeneration + tagging reads** (blocked-on: W16.cfg1,
  W16.cfg2) **[M].** DONE 2026-07-29 (this commit). Fresh standard-image and pre-OCRed runs now pass the
  same immutable snapshot through rotation/manual PDF regeneration, segmentation and collection review
  reclassification, automatic/manual tag writes, Live Capture priority layering, sized-original export, and
  merged-PDF tag transfer. The late-stage resolver uses explicit config first, then the retained active-run
  config for post-run UI edits; resume deliberately supplies nil and preserves its current validated
  static/instance fallback until W16.cfg5. Process Files snapshots the controller's exact tagging/merge/export policy,
  so headless `.none`/`.copySource` runs cannot inherit unrelated UserDefaults values; every copy-source
  write remains explicitly non-stamping. Processor Debug build plus scratch manifest/config, merge-safety, and
  batch/non-batch resume regressions passed. Tier-2 adversarial review found and closed the remaining live
  tagging/merge/export decision gates, then approved call-path coverage, copy-source behavior,
  trailing-closure compatibility, and the MainActor/detached-task boundary.
  | files: OCR/{OCRProcessor+OCR,OCRProcessor+Pipeline,OCRProcessor+ReviewFlows,OCRProcessor+Tagging}.swift,
    Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift | M | med | none
- [x] **W16.cfg5 — resume constructs a run config instead of fanning out to globals** (blocked-on: W16.cfg2,
  W16.cfg3) **[M].** DONE 2026-07-29 (this commit). Modern `PendingRun` resumes now reconstruct one
  `SessionProcessingConfig` from the validated runtime snapshot; legacy `PendingRun` and `PendingBatch`
  resumes combine their persisted identity/policy with the same current normalized defaults as before
  (including the prior 1%…100% image-scale clamp). Every resume stores the non-nil snapshot in
  `activeRunConfig` and threads it through OCR/PDF/retry/pre-OCRed/review/tag/export/merge seams. The six
  resume assignments and fresh-run static fan-out are gone; fresh runs and standalone Tools diagnostics
  pass rotation/size explicitly, so no production path depends on a stale process-global value. The
  manifest validator and schema version are unchanged. `BatchResumeTestDriver` now asserts modern,
  legacy-run, legacy-batch, malformed-default, and no-global-fan-out behavior. Debug build plus scratch
  batch/non-batch recovery, manifest/config isolation, multi-page PDF, and merge/tag safety suites passed.
  Tier-2 adversarial review found and closed the Tools static escape hatch, two missed run-config seams,
  and the legacy image-scale clamp mismatch, then approved.
  | files: OCR/{OCRProcessor,OCRProcessor+OCR,OCRProcessor+Pipeline}.swift,
    Capture/{BatchResumeTestDriver,SessionProcessingConfig}.swift, Views/ToolsView.swift | M | med | none
- [x] **W16.cfg6-fu — `MacOSTagger.stampUnread` and the `taggingMode.didSet` that armed it are deleted
  [XS · verified].** DONE 2026-08-01 (this commit; checkpoint `5e72f15`). Filed by W16.cfg6. It was the suite's
  last ambient tagging global. Nothing in production read it — W16.cfg4 had already made `stampUnread:` a
  required per-call parameter at all 13 `applyTags` sites — so what kept it alive was three test drivers, plus
  the standing possibility that a driver whose `defer` a crash skipped would leave a stale value behind.
  `MacOSTagger` now holds no state at all; which semantics a tag write uses is an argument at the call site and
  nothing else. The drivers now assert the injected per-call value: `MergeSafetyTestDriver`'s two stamping cases
  were already driven by the processor's own `taggingMode` (`performDocumentMerging` reads
  `taggingMode.stampsUnread`), so the global assignments beside them were simply redundant;
  `ProcessFilesTagWarningTestDriver` only saved/restored it. **`ManifestPersistenceTestDriver`'s B8 check had
  lost its subject entirely** ("activation does not arm the tagging global") and got a NEW one rather than
  retirement: a run holding no snapshot answers from pure UserDefaults reads, so the only channel by which Live
  Capture could still reach a later Process Files run is by PERSISTING its config. B8 now hands
  `beginLiveSession` a config differing from disk in all **seven** such values (five sizing + rotation mode +
  tagging mode) and proves each key reads back byte-identical — split into two checks so a failure says which
  half broke, the first comparing per-field precisely because one struct-level `!=` would let six of the seven
  silently stop being covered. **Verified $0, scratch-only, no network:** manifest-persistence 105 PASS / 0 FAIL,
  merge-safety 15 PASS / 0 FAIL, tagwarn 74 PASS / 0 FAIL; Debug build clean, no new warnings. **Non-vacuity
  measured against 4 mutants** (activation persisted the sizing config / the config didn't actually differ from
  disk / a rotation-mode leak / a tagging-mode leak) — all RED, restored green. **Tier-2 adversarial review
  found four real defects in the replacement B8 check and all four were fixed before the final commit:** the
  comment claimed `runSizing()` was the *only* terminal fallback when `defaultRotationMode()` is a sixth (so a
  future "remember the last live rotation choice" write would have leaked past a green check — the rotation
  conjunct exists because of this finding); the honesty guard was a struct-level `!=`; `taggingMode` was
  hardcoded to `.automatic`, the near-certain on-disk value, making its conjunct nearly vacuous; and the comment
  asserted "read-only throughout — nothing writes `UserDefaults.standard`", which is **false** — constructing
  `CaptureSession` mints the two capture-token defaults when absent, and `activate` prunes orphaned legacy
  staging. The comment now says what is true and why those writes are tolerable. Review also confirmed the SPEC
  citation `Tagging/MacOSTagger.swift` (`stampUnread`) still resolves — `stampUnread` remains the parameter
  label on both `applyTags` overloads — so **no owner-gated SPEC edit was needed.**
  | files: Tagging/MacOSTagger.swift, OCR/OCRProcessor.swift,
    Capture/{ManifestPersistence,MergeSafety,ProcessFiles,ProcessFilesTagWarning}TestDriver.swift | XS | low | none
- [x] **W16.cfg6-fu3 — the WRITERS of the five sizing settings were unbounded; only the reader saved them
  [S · verified].** DONE 2026-08-01 (this commit; checkpoints `eb8a70d`, `42285f4`). Filed by W16.cfg6-fu2's
  adversarial review. fu2 made every *defaults read* clamp, so nothing out of range could reach a run; this
  item was the visible-vs-effective divergence left over — typing `500` into an MB field beside its 0.5…20
  stepper persisted 500 and kept displaying 500 while every run used 20 and the cost pane quoted 500.
  **`SessionProcessingConfig.Bounds`** is now the one declaration of the three ranges (0.5…20 MB, 1…12
  workers, 1…4 columns). It replaced **six** literal sites, not the four the checkpoint commit claimed — the
  adversarial review found two more that the first pass missed, and they were the two that mattered most:
  `OCRProcessor.schedulingWorkerCount` and `PDFGenerator`'s column clamp, i.e. exactly the downstream pair
  that would keep running 12 workers / 4 columns if the shared bound were ever widened, recreating the
  divergence this item exists to kill. Both substitutions are value-identical for every `Int`
  (`min(12, max(1, x))` ≡ `clampOCRWorkers(x)`; `max(1, min(x, 4))` ≡ `clampTextColumns(x)`), so no behaviour
  moved. The fail-closed resume validator `pendingRunRuntimeConfigIsValid` reads `Bounds` too, with all three
  `.isFinite` guards intact and in place — verified value-identical, since a stricter validator there would
  refuse a resumable **paid** batch.
  **`normalizeSizingDefaults(_:)`** is the writer half: it writes back exactly `runSizing(d)`, so writer and
  reader cannot disagree about a bound or a fallback. An UNSET key stays unset (`ProcessingProfileStore`
  reads stored-vs-defaulted), and a key already equal to its normalized value is not rewritten, so it is
  idempotent. Wired at the four sites the fu2 review named: Settings `.onAppear` + four `.onChange`; the two
  panes that quote a size to the operator; `TimeEstimator` (now clamps workers at BOTH ends — `max(1, …)`
  alone let a stored 100 quote an ~8× optimistic ETA while the pipeline ran 12); and
  `ProcessingProfileStore.apply`, which also gained a `to d: UserDefaults = .standard` parameter so the
  headless driver exercises it on a scratch suite rather than the real settings.
  **The design question the item posed is answered, not skipped:** a big number no longer means "keep the
  original bytes". fu2 already ended that — every read resolves 500 → 20 — so normalizing destroys an intent
  that had already stopped working, and there is no production material to preserve it for. If a
  never-re-encode mode is ever wanted it should be an explicit setting, not a magic large number.
  **Verification:** Debug build clean, 0 new warnings; `test-manifest-persistence.sh` **104 PASS / 0 FAIL**
  and `test-batch-resume.sh` **241 PASS / 0 FAIL** ($0, no network, no key, scratch suites only), the latter
  run because this touched the resume validator. **Non-vacuity MEASURED across three mutants:** dropping the
  unset-guard / the equality-guard / the `TimeEstimator` clamp / the `apply` call turns exactly 4 red;
  clamping ∞ to the ceiling instead of resolving it turns 3 red; rounding every size to the nearest 0.5 turns
  exactly 1 red. **The adversarial review earned its keep four times** — it found the two missed literal
  sites; it killed a near-vacuous check (comparing stored against `fromDefaults` *after* normalizing proves
  nothing, because the reader agrees with any in-range number handed to it — measured, the clamp-to-ceiling
  mutant left it green, so it was rewritten to compare against the PRE-normalization read); it produced the
  round-to-0.5 mutant that no existing check caught, now closed by an in-range-value-untouched check; and it
  refuted two doc-comment overclaims (the validator can still be *looser* than the app — the columns Picker
  offers only 1/2/3 while `Bounds` admits 4 — and "what Settings shows is what a run uses" is true only to
  the field's one-decimal display: a stored 19.96 still renders as 20, measured, and is left alone).
  ⚠️ **One check deferred, not skipped:** whether the MB field visibly redraws when the normalizer writes
  behind it while the field still has focus. The Processor has no UITest target or VM lane yet
  (`W21.vmgui-d`), so the off-screen route does not exist and the host screen is the owner's. Proven safe
  regardless — it cannot loop (the write is gated on inequality, converging in two passes) and no run reads
  the raw value — but the redraw itself is unseen. → Morning Review.
  | files: Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift,
    OCR/{OCRProcessor+Pipeline,OCRProcessor+OCR,PDFGenerator}.swift,
    Views/SettingsView.swift, Models/{TimeEstimator,ProcessingProfileStore}.swift | Tier-2 | S | none
- [x] **W16.cfg6-fu2 — `fromDefaults()` clamped looser than `runSizing()`, so Live Capture got unclamped image
  sizes [S · verified].** DONE 2026-08-01 (this commit). Filed by W16.cfg6's adversarial review and re-verified
  on both halves during the 2026-08-01 owner walkthrough. `fromDefaults()` built `pdfImageMB`/`exportedImageMB`
  from bare inline closures (`p > 0 ? p : 2.0`) — no `.isFinite` guard, no 0.5 floor, no 20 ceiling — while
  `standardImageMB`/`ocrWorkerCount` went through the strict shared helpers. **Live Capture snapshots its whole
  session config from `fromDefaults()`** (`CaptureSession.swift:230`), so those closures were the only clamp an
  out-of-range default met on the live path: a 21 MB `pdfImageSizeMB` stayed 21 for a live capture (Process
  Files made it 20), and `+.infinity` — which UserDefaults really does round-trip, measured — passed straight
  through, since `inf > 0`. Fixed by taking **all five** sizing values in `fromDefaults()` from `runSizing(_:)`,
  so there is one normalization per defaults read. `fromProcessFilesRunStart()` therefore had nothing left to
  correct: it is now a one-line forward, and the callerless `applySizing(_:)` is deleted. `textColumns`'
  old closure was already numerically equivalent (`tc > 1 ? min(4, tc) : 1` ≡ `min(4, max(1, tc))` for every
  `Int`, `Int.min` included) — merged for one definition, not to change behaviour.
  **Verification:** Debug build clean, 0 new warnings; `test-manifest-persistence.sh` **96 PASS / 0 FAIL**
  ($0, no network, no key, scratch suites only) including six new `W16.cfg6-fu2` checks. **Non-vacuity
  measured**, not asserted: restoring the two pre-fix closures turns 4 of the 6 red (ceiling, builder
  agreement, 0.5 floor, non-finite). The other two — unset-defaults fallback and negative-falls-back — are
  green pre-fix by design: they guard against a *wrong fix* (e.g. `max(0.5, v)` without the `.isFinite && > 0`
  test), not against the original bug. **Adversarial review** (opus, refute-first) killed two weaker checks and
  one overclaim: a "REAL defaults are in range" check that was unfalsifiable while the clamp exists was
  deleted, a "negative or NaN" check that the old code also passed was re-scoped onto `+.infinity` (which it
  did not), and the new doc comment's "one clamp per value, app-wide" was corrected to per-defaults-read after
  the reviewer produced four counterexamples. Its claim that the resume path applies a runtime config
  unclamped was checked and does not hold — `pendingRunRuntimeConfigIsValid` fail-closes on the same ranges.
  Residual writer-side gaps filed as **W16.cfg6-fu3**.
  | files: Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift | Tier-2 | S | none
- [x] **W16.cfg6 — delete the six `nonisolated(unsafe)` statics; injection mandatory** (blocked-on: W16.cfg2,
  W16.cfg3, W16.cfg5) **[S].** DONE 2026-08-01 (this commit; checkpoints `6713e43`, `2373d30`). All six are
  gone — `rotationModeForRun`, `standardImageMB`, `ocrWorkerCount`, `pdfImageMB`, `textColumns`,
  `exportedImageMB` — with `loadStandardImageMB()`. **Nothing process-global decides how a Process Files run
  sizes an image, columns a text page, or schedules its workers any more.** Two parameters became required, so
  the compiler (not a reviewer) enforces completeness: `targetDimensionScale(forFileAt:sizeFraction:standardImageMB:)`
  and `performOCRCall(…, rotationMode:, standardImageMB:)`; all 11 `performOCRCall` sites resolve both once per
  function via the new `OCRProcessor.ocrCallValues(for:)`, hoisted before any actor hop. Where an optional
  `runConfig` legitimately remains (`pdfGenerationSettings`, `schedulingWorkerCount`, `lateRunOutputSettings`,
  `makePendingRunRuntimeConfig`), the terminal fallback is now `SessionProcessingConfig.runSizing()` /
  `defaultRotationMode()` — **pure, lazily evaluated, Keychain-free** defaults reads, so an injected config
  short-circuits them and the per-file loops never touch UserDefaults. `fromProcessFilesRunStart()` normalizes
  through the same `runSizing()`, so there is now **one clamp per value in the whole app** ⚠️ *(overclaim —
  see W16.cfg6-fu2 below: `fromDefaults()`, which is Live Capture's builder, did NOT go through it; the honest
  scope even after fu2 is one clamp per **defaults read**)*. Behaviour: every
  production path injects a config (cfg2/cfg3/cfg5), so the only branch whose value changes is the one no
  production caller reaches — and there it goes from the deleted statics' *initial* constants (pdfImageMB 0,
  exportedImageMB 0, rotation `.localVision`, which is what a post-cfg5 process would serve since nothing wrote
  them any more) back to the normalized run-start defaults `loadStandardImageMB()` produced pre-cfg5. A
  restoration, not a new rule. The three drivers **stop poking globals** — exactly the pattern this item
  existed to delete, since a crash between a driver's write and its `defer` restore left a REAL run exporting
  at the test's size: `ProcessFilesTagWarningTestDriver` injects its 5 MB export target,
  `BatchResumeTestDriver`'s "no fan-out to statics" check became a bystander-processor check (nothing left to
  fan out to), and `ManifestPersistenceTestDriver` gained five W16.cfg6 checks pinning what a static could never
  offer — read twice, same answer; change a default, seen immediately; nothing cached, nothing retained.
  **Verification:** Debug build clean, 0 new warnings; `test-manifest-persistence.sh`, `test-batch-resume.sh`,
  `test-processfiles-tagwarn.sh`, `test-merge-safety.sh`, `test-multipage-reocr.sh`, `test-recovery.sh`,
  `test-output-file-safety.sh`, `test-collection-organize.sh`, `test-localagent.sh`, `test-segment-json.sh`,
  `test-incremental-skip.sh` — **all pass** ($0, scratch/temp dirs only, no corpus). `test-tier2.sh` needs a
  live Gemini key (pre-existing keyed tail, not run). Two-lens adversarial refute-verify
  (reachability+numeric-equivalence; call-site mechanics+concurrency+test integrity) — see below.
  | files: OCR/OCRProcessor{,+OCR,+Pipeline,+Tagging}.swift, Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver,BatchResumeTestDriver,ProcessFilesTagWarningTestDriver}.swift | S | med | none
- [x] **W16.cfg4 — make `stampUnread` injection explicit at all `MacOSTagger` call sites [M].** DONE 2026-07-18
  (`806a6d3`). `applyTags`'s `stampUnread` is now a **required non-optional** parameter (both overloads);
  the process-global is no longer read by `applyTags` (retained only as a test-driver affordance + `taggingMode.didSet`
  writer, to be deleted with the run-config globals in W16.cfg6). All 13 sites audited individually: the four
  copy-source pass-through sites (`+OCR.swift:168/1064`, `+Pipeline.swift:1091`, `+ReviewFlows.swift:388`) pass a
  literal `false`; the nine real-tagging sites pass `taggingMode.stampsUnread`. The merge path's direct global
  *read* for job selection (`+Tagging.swift:825`) was also moved to `taggingMode.stampsUnread` so it can't disagree
  with its paired write (:834). The image-mirror detached task hoists `taggingMode.stampsUnread` onto the MainActor
  before detaching. **The `⚠️` copy-source-regression hazard was confirmed real and avoided** (the four false sites);
  the `MergeSafetyTestDriver` "empty non-stamping merge skips unnecessary tag writer" case had to be re-expressed via
  `taggingMode = .none` because a fresh `OCRProcessor()` defaults `taggingMode` to `.automatic` and an init default
  doesn't fire `didSet`. **Verification:** non-optional param → compiler-proven site completeness; build clean, 0 new
  warnings; `MergeSafetyTestDriver` (15/15) + `ManifestPersistenceTestDriver` (42/42) ALL PASS; **4-lens adversarial
  refute-verify (equivalence/lifecycle/invariant/concurrency) — 0 findings, none could refute behavior-preservation**
  (the invariant lens proved `enableTagging` is derived, so `passSourceTags && enableTagging ≡ (mode==.copySource)`,
  closing the one hypothesized hole). Behavior-preserving for every production path.
  | files: Tagging/MacOSTagger.swift, OCR/OCRProcessor+{OCR,Tagging,ReviewFlows,Pipeline}.swift, Capture/MergeSafetyTestDriver.swift | M | **high** | none
- [x] **W16.bat1 — provider contract fixtures for the three batch clients' response parsing [M].** The **only
  unmet item in the entry's own verification plan**, and the highest-value remaining slice. `GeminiBatchClient.checkStatus`
  parsed **six alternative JSON shapes** with **zero tests** — a provider response-shape change would silently
  have marked an entire paid batch as failed.
  ✅ **DONE this commit** (checkpoints `8f51c9b` = the seams, `85c3b96` = the checks). Each client's parse body
  was lifted **verbatim** out of its `async throws` network call into a pure static seam — `parseStatusBody(_:)`
  and `parseResultsJSONL(_:)` on all three clients — and `parseInlinedResponses` / `parseSingleResponse` /
  `parseBatchErrorBody` went `private` → internal. No behaviour change is possible by construction: the diff
  moves whole statement runs and adds no logic. `OCR/BatchParseContract.swift` then drives literal
  Anthropic/Gemini/Mistral bodies through those seams as section 12 of `BatchResumeTestDriver`, so
  `scripts/test-batch-resume.sh` covers the whole paid-batch surface: **81 new checks, 144 total, ALL PASS, $0,
  no network, no keys.** Every shape the item asked for is pinned — all six result-file spellings *individually*
  plus the order they resolve in; state under `state` vs `metadata.state` and inline results under `response.…`
  vs `metadata.output.…`, both with their precedence; inline results read ONLY once terminal; all eight terminal
  states across the BATCH_/JOB_ vocabularies; blockReason / RECITATION as stated refusals; entry-level errors
  with their code; the `'0'` → `'file-0'` normalization (and that an unattributable entry is DROPPED, never
  misfiled onto another page); empty + malformed result sets; Anthropic succeeded/errored/expired lines and the
  rule that a non-text block is excluded by TYPE even when it carries a `text` field (thinking must not leak
  into a transcription); Mistral's five terminal statuses, `pages[].markdown` + `text` fallback and its error
  ladder; the shared HTTP error body incl. an HTML gateway page. Across all three: one unreadable JSONL line
  never costs the other paid pages. **Non-vacuity measured, not assumed** — 7 neuters reddened 14 checks
  (8 predicted; the 6 extras all traced to the shared key-normalization neuter's wider blast radius), and every
  neuter reddened at least one check. The operator note also shipped (`README.md` §"Batch Processing → If a
  batch submission reports an uncertain outcome"). Processor builds clean, 0 new warnings. Residual filed as
  **W16.bat1-fu** below.
  | files: OCR/BatchOCR.swift, OCR/BatchParseContract.swift, Capture/BatchResumeTestDriver.swift, scripts/, README.md, TESTING.md | M | low | none
- [x] **W16.bat1-fu — an EMPTY inlined-results container makes the poll consume a paid Gemini chunk with zero
  pages [XS–S · LOW · measured, never observed].** Found by measurement while writing the W16.bat1 fixtures, and
  pinned there as a fact rather than an endorsement (`gemini: an EMPTY inline container parses to a non-nil
  empty set`). `GeminiBatchClient.parseStatusBody` sets `inlineResults` to a **non-nil empty dictionary** when a
  terminal batch carries `inlinedResponses: []`, and the poll then takes the inline arm — `if let inlineResults
  = status.inlineResults { … } else if let fileName = status.resultFileName { … }`
  (`OCRProcessor+OCR.swift:776-785`) — so the result **file is never fetched**. `processBatchResults` returns
  `true` on an empty set (`:874`), so the chunk is marked *consumed* and never retried: that chunk's paid OCR is
  lost while the run reports success. Requires the provider to emit an empty container on a SUCCEEDED batch
  (never seen here), hence LOW — but it is exactly the response-shape class W16.bat1 exists to catch. Fix is one
  condition (`if let inline = status.inlineResults, !inline.isEmpty`) plus a decision on what an empty container
  with **no** file spelling means (fail the chunk loudly rather than consume it). Touches the paid poll →
  **Tier-2**, and the existing pin must be flipped to assert the new behaviour.
  ✅ **DONE this commit** (checkpoints `43b53e9` = the ranking seam, `c9490ac` = the poll + the outcome rule,
  `94c39a9` = the terminal-verdict rewrite the Tier-2 review forced). Both halves of the decision are now pure
  and pinned rather than inline in the poll. `resultsSource(for:)` ranks the two retrieval arms and treats an
  empty inline container — **and a blank or whitespace-only result-file name** — as *not a source*, so the
  result file is still fetched. `chunkOutcome(resultCount:emptyObservations:limit:)` then judges the **raw
  provider results**, which is where the judgement has to happen: `processBatchResults` returns `true` for an
  empty set *by design*, because a resumed chunk whose pages all persisted already legitimately yields no new
  entries — so it can never be the gate.
  **The verdict is terminal, not blocking** — and getting that wrong first is the lesson worth keeping. The
  adversarial review killed checkpoint 2's design: it set `batchPollInterrupted` and returned, with a
  poll-local observation count, so every Resume restarted the grace and aborted again and **nothing ever
  converted an empty chunk to failed** — the run could never finalize, tag, or retry, and sibling chunks still
  hours from finishing were abandoned. Its worst case: a result file that 404s after Gemini's ~48h retention
  (`NetworkSession` does not throw on non-2xx, so the error body parses to zero results) on a chunk whose pages
  are **all already on disk** → a run blocked forever with nothing missing. Now: the chunk is still never
  marked consumed, but the batch COMPLETES, and the existing completion sweep gives each unmaterialized file an
  explicit `no_result` failure the retry pass can act on (resume restores already-persisted results as
  `.succeeded`/`.failed`, so they are not re-failed). Given-up chunks are remembered so later polls don't
  re-fetch them. Grace is 5 polls (~2–4 min); 3 gave the late-attach case it exists for only ~90s.
  **17 new $0 checks** (`test-batch-resume.sh` 144 → 161, ALL PASS), including the invariant swept over BOTH
  axes — every observation count against every limit from −5 to 100,000 — in both directions: zero results
  never materialize, and pages are never withheld. Non-vacuity MEASURED with 4 neuters, each reddening exactly
  its own checks. The W16.bat1 pin was kept but renamed: the *parse* still reports the empty container
  faithfully; what changed is that the poll no longer acts on it. Adjacent `test-network-session`,
  `test-manifest-persistence`, `test-recovery` green; clean build, 0 new warnings. Operator note in
  `ArchiveProcessor/README.md`. Two **pre-existing** defects the review surfaced are filed separately, not
  fixed here: **W16.bat3** (Stop deletes the paid journal) and **W16.bat4** (the Resume control is not
  re-surfaced after an interrupted first run).
  | files: OCR/BatchOCR.swift, OCR/OCRProcessor+OCR.swift, OCR/BatchParseContract.swift | XS–S | low | none
- [x] **W16.bat2 — headless coverage for the cancel path's journal-retention contract [M].** DONE 2026-08-01
  `c3dc615` + `72b1ed7` + this commit — the delete-only-if-all-confirmed rule was the one shipped safety
  guarantee on the money path with no regression test, because it was welded to three live network clients.
  It now lives in one seam, `performServerBatchCancellation` (`+Pipeline.swift:1565`), which takes the
  provider's per-chunk cancellation as an injectable closure and returns what it did to the journal
  (`BatchCancellationOutcome`, incl. which chunks it actually attempted); `cancel()` keeps only the
  provider-specific *how*. Behaviour-preserving: same switch, same order, same message (now a pinnable
  constant), same single delete condition.
  **28 new $0 checks** (`test-batch-resume.sh` 161 → 189, ALL PASS) in `BatchCancelContract`, driven through
  the real seam with a stub canceller and a **real temp file**, so "kept" means a file that is still on disk.
  Named cases for every rule the item asked for — all-confirmed deletes; one refusal keeps; multi-chunk
  Anthropic/Mistral is neither confirmed nor *half*-cancelled (no chunk attempted); zero chunks is a failure
  to confirm, not a vacuous success; OpenAI never confirms — plus Gemini's no-early-exit loop (a live chunk
  is what costs money) and "the words and the disk cannot disagree". Then the invariant swept over both axes:
  4 providers × chunk counts 0–6 × no refusal / each chunk refused in turn / all refused = **132 trials**,
  asserting *deleted ⟺ confirmed* in the outcome AND on disk, confirmation matching an independently written
  statement of the providers' capabilities, no attempt a provider's rule could not act on, message ⟺
  survival, and delete called at most once. Non-vacuity MEASURED with **5 neuters**, each reddening exactly
  its own checks — including one shaped like W16.bat3 (journal deleted while the outcome still says "kept"),
  which reddens 13. Clean build, 0 new warnings; `test-network-session`, `test-recovery`,
  `test-manifest-persistence` green.
  **Scope note — what a green section 13 does NOT buy:** it pins the *rule*, in the seam, not the whole Stop
  path. No check goes through `cancel()`, and `deletePendingBatch()` is executed by none of them (the stub
  deletes a temp fixture), so the *wiring* is unproven — filed as **W16.bat2-fu**. And W16.bat3's bug is
  downstream of this seam entirely, in the poll's cancellation guards; it stays open + owner-gated and must
  not be closed by citing this. Both caveats are now written into the code comments too, because the code
  comment is what the next maintainer reads.
  The adversarial review could not refute behaviour equivalence (case-by-case against `69f3bbc`: identical
  call counts, byte-identical message, same single delete condition, same MainActor executor, clients already
  constructed before the count check). Its findings drove one extra tripwire check (OpenAI's rule is only
  correct because `supportsBatch == false` — reddens if Phase 4 lands), a non-vacuity guard on the
  "never announced as kept" case, honest scoping in both doc blocks, and two new items (W16.bat2-fu, W16.bat5).
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/BatchCancelContract.swift, Capture/BatchResumeTestDriver.swift | M | med | none
- [x] **W16.bat2-fu — the cancel WIRING is untested, only the rule is [S · LOW].** DONE 2026-08-01
  `b4b871f` (seam) + `1c8bf22` (18 checks) + `183f792` (review gaps) + this commit. `BatchCancelContract`
  proved the RULE; nothing proved `cancel()` fed it the truth, and five separate mutations to the cancel block
  left all 189 checks green. The block's choices became data — `BatchChunkCanceller` (provider + how to cancel
  one chunk + which client it closed over), `BatchCancellationJournal` (the ONE durable file a confirmed
  cancellation may remove, as a value), `cancellationChunkIds` (pure), and two per-instance factories
  (`makeBatchChunkCanceller`, `makeBatchJournalDeleter`) — then `BatchCancelWiringContract` drives the **real
  `cancel()`** with both seams stubbed and a real temp file: **24 new $0 checks** (`test-batch-resume.sh`
  189 → 213, ALL PASS), no network, no key, no cent, and `deletePendingBatch()` executed by none of them.
  Non-vacuity MEASURED with **12 neuters** — the five the item named, the pending_run variant (via a second
  journal case), and six for the checks the review added — each reddening its own checks and no pre-existing
  one. Two-reader Tier-2 review: the equivalence reader could not refute the refactor (nothing moved INTO the
  spawned Task, `cancel()` has no `await` so the summary is still assigned before the Task can start, all three
  batch clients are pure value structs, the rule body differs by two lines, the chunk-ID expression is
  textual, both new file-name constants equal the literals they replaced). The test reader killed a tautology:
  the provider check compared a LABEL production passes as a literal, so a Gemini job cancelled through the
  Mistral client — or an arm short-circuited to always-confirm — stayed green while deleting the journal. Fixed
  with `clientTypeName`, read off the constructed client; plus the seams' DEFAULTS (previously covered by
  nothing), a non-Gemini Stop, and a sentinel proving the resume banner is refreshed.
  **Scope note — what a green section 14 does NOT buy:** the default *deleter* is unprovable without deleting
  the operator's real journal (→ **W16.bat2-fu2**), and the kept-journal warning is proven *assigned*, not
  *survived* (→ **W16.bat6**). Both are written into the file header, not just here.
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/BatchCancelWiringContract.swift, OCR/BatchCancelContract.swift, Capture/BatchResumeTestDriver.swift | S | low | none
- [x] **W16.bat2-fu3 — fold in the three wiring checks a killed session's draft had and the shipped one
  does not [XS · LOW].** DONE 2026-08-01, this commit. Not a defect — a coverage delta found while cleaning up. The
  session that landed W16.bat2-fu's checkpoint 1/3 (`b4b871f`) was killed holding an untracked draft of
  `BatchCancelWiringContract`; the shipped file was written independently and is stronger where it counts
  (`clientTypeName`, the seams' defaults, the banner sentinel — the draft has none of those), but the draft
  covered three things the shipped one did not, all three now folded in (213 → 225 checks, ALL PASS):
  (1) `sweepEveryShape` — 80 Stops through the real `cancel()` over every provider × 0–3 acknowledged
  chunks × journal-present × each chunk refused in turn, each demanding an EXACT outcome. Not a port of the
  draft's sweep: that one asserted only internal consistency (satisfiable by a cancel path that confirms
  nothing, ever), and its chunk-ID invariant `attempted == derivedChunkIds` was wrong as written — it
  fails for every shape whose provider rule declines to attempt (multi-chunk Anthropic/Mistral, OpenAI),
  which the killed session never got to run. Here each trial states the expected attempt list and
  confirmation independently, and with-journal trials give the batch decoy IDs the journal never
  acknowledged, so no shape may fall back to them. (2) A multi-chunk single-job-provider Stop: 3 chunks through an
  Anthropic/Mistral batch attempts nothing, keeps the journal, and warns — while still asking for the
  canceller and the deleter, so the check stays about the wiring. (3) The legacy (`lifecycleVersion ==
  nil`) journal driven through `cancel()`: its batch ID is cancelled, never its non-authoritative stored
  chunk list. Non-vacuity measured by mutating production five ways: `cancel()` ignoring the journal
  (14 fails), a single-job provider cancelling the first of several (12), a vacuous empty-list Gemini
  success (7), the no-batch-path provider reporting confirmed (6 — caught by the sweep alone at the
  wiring level), and the derivation reading `submittedChunkIds` past `effectiveChunkIds` (2). The
  adversarial review then found the legacy-journal check green under mutation 1 — it gave the journal and
  the live `BatchContext` the same batch ID, so `pendingBatch: nil` satisfied it; all three ID sources now
  disagree and it reddens. Same review: the 80 Stops each run a real `checkForPendingBatch()`, which
  decodes the operator's OWN manifests, so `test-batch-resume.sh`'s 60s report wait (fine at the measured
  4s on an empty machine) could time out on a large interrupted run — i.e. fail exactly when there is a
  live paid batch. Raised to 300s and the dependency written down; it goes away with W16.bat2-fu2. A red
  in the sweep now names the first bad shape (`Anthropic/1 chunk/journal/none refused`) instead of a bare
  boolean. The preserved draft folder is deleted.
  | files: OCR/BatchCancelWiringContract.swift, scripts/test-batch-resume.sh, ArchiveProcessor/TESTING.md | XS | low | none
- [x] **W16.bat4 — after an interrupted FIRST run, the Resume control the message names never appears [S · LOW].**
  DONE 2026-08-01 `1515773` + `819494d` + this commit. Was: every `batchPollInterrupted` message tells the
  operator the batch was kept so they can resume it; on a **resume** that was true (the site called
  `cleanupTempFiles()` + `checkForPendingBatch()`), but on a **first** run the interrupt was
  `isProcessing = false; return` with neither call. `pendingBatchInfo` — the only thing the "Pending Batch /
  Resume Batch" box (`Views/OCRView.swift:319-336`) renders from — is written only inside
  `checkForPendingBatch()`, so the button the message named did not exist until the operator pressed Start and
  was refused, and the PDF-input temp JPEGs leaked. The two tails are now ONE method,
  `finishInterruptedBatchPoll()` (`+Pipeline.swift:796`), called by both sites and by nothing else, so they
  cannot drift again. Reaching the first-run site through it also covers `performBatchOCR`'s three earlier
  interrupted exits (journal-save failure, a submission stopped part-way, a journal/ID disagreement), which
  previously left a dead `activeBatch`/`activePendingBatch` behind and leaked the same temp files. It deletes
  no journal and touches no output — a paid server-side job may still be running.
  `BatchInterruptTailContract` (driver section 15) adds **16 $0 checks** (`test-batch-resume.sh` 225 → 241),
  non-vacuity measured with **four neuters**, each reddening exactly its own checks — including the shipped
  bug itself (drop `checkForPendingBatch()` → 5 red). Scoped in its header: it pins the TAIL, not its two call
  sites (driving either needs a real paid submission or the un-redirectable journal path — W16.bat2-fu2);
  what keeps them aligned meanwhile is structural, each being a bare `finishInterruptedBatchPoll(); return`.
  | files: OCR/OCRProcessor+Pipeline.swift | S | low | none
- **Split out as its own LOW entry (tracked in `ArchiveProcessor/KNOWN_ISSUES.md`, NOT queued):** *lost-create
  reconciliation* — if a provider accepts a create POST and the response is lost, the app records the ambiguity
  honestly but cannot list the provider's batches to re-adopt the orphan. Cost is one batch's spend possibly paid
  twice. Building auto-adoption needs **live paid API calls** against each provider's list endpoint (outside the
  daemon's envelope) for a failure mode **never observed here**; the non-idempotent retry policy already stops the
  app from creating the duplicate itself. Ship the operator doc note (in W16.bat1) instead; build only if a
  lost-create event is ever actually observed. ✅ **The doc note shipped with W16.bat1** (`ArchiveProcessor/README.md`
  §"Batch Processing → If a batch submission reports an uncertain outcome"): it quotes the exact in-app message,
  says do **not** press Resume before checking the provider's own console, links all three consoles, and separates
  this from the benign *"stopped after N server jobs"* message. The reconciliation itself stays unbuilt by decision.


## Wave 19 — Notes date-mirror + Quality facet (MERGES/replaces Priority) (owner-reviewed 2026-07-18)

- [x] **W19.q1 — SPEC: the Quality facet + Notes-as-date-emitter.** DONE `06fabcc`, **merge revision** 2026-07-18
  — `SPEC/tag-format.md` now defines Quality as the single rating facet that supersedes Priority (Priority row →
  RETIRED + read-alias `P8`–`P10`→`Q1`–`Q3`, `P7`→unrated; `Q3`=old `P10`), records the companions as `Q` emitters
  + the phone↔Mac protocol as a SHARED HOTSPOT, and keeps the Notes date-projection row. Source of truth for q2–q7. | Tier-2 (SPEC) | S


## Notes test hardening (from the 2026-07-29 health-gate RED)

- [x] **W23.flake1 — de-flake `NoteBodyEditorModelTests.supersededLoadIgnored` (it RED'd the health gate).**
  The 2026-07-29 19:10 periodic gate went **RED on Notes** (708 passed / **1 failed**) and then **GREEN on the
  daemon's retry against the identical commit `baa970a` with a clean tree** — same code, different result, i.e.
  nondeterminism, not a regression. Cause: the test raced the two selections with `async let first = m.select(a)`
  / `async let second = m.select(b)`, but **Swift does not specify which child task starts first.** When B started
  first the model did the *correct* thing — B loaded, then A superseded it as the genuinely newest selection and
  won — so the assertions (`loadedID == b`) failed spuriously with
  `Expectation failed: (m.loadedID → …) == (b → …)`. **`NoteBodyEditorModel` was never at fault; the supersede
  guard (monotonic `loadGeneration` re-checked after each `await`) is correct and is unchanged by this item.**
  Fix (test-only): order the race deterministically — start A's slow `select` in a `Task`, spin on
  `Recorder.loadCount` (bumped at the top of `load` *before* its sleep) until A is parked mid-load with
  generation 1 captured, and only then `await m.select(b)`; assert `loadCount == 1` so a never-set-up race fails
  loudly instead of vacuously passing. Also **added `slowUnsupersededLoadStillWins`**, which pins the mirror
  ordering the old test hit by accident (a slow load that nothing supersedes must still win) — so the generation
  guard is now proven to drop *superseded* loads only, never merely late ones. Net: the hazard keeps its coverage
  and gains the complement. Verified: `NoteBodyEditorModelTests` **30/30 consecutive** runs green; full
  `ArchiveNotesTests` bundle green (710 tests, was 709); test bundle builds with **0 new warnings**. Rarity is why
  it surfaced only now — pre-fix, the single test passed **25/25** in isolation and the full bundle **4/4**, so
  the gate's retry-once is what caught it. Tier-2 not triggered (no product code touched, no write path changed).
  ⚠️ **Follow-up left open on purpose:** `NoteBodyEditorModel.flushPending`'s doc comment justifies keeping
  `select`'s flush sequence *inline* because "the extra async frame ... perturbs the actor scheduling its
  superseded-load race relies on" — that rationale was resting on the flaky test and is now stale. Whether
  `select` should call `flushPending()` instead of duplicating the sequence is a real (small) Tier-2 refactor
  decision on a note-body write path, so it is **not** bundled here.
  | files: ArchiveNotes/macOS/Tests/ArchiveNotesTests/NoteBodyEditorModelTests.swift | S | low | none | done


## W21 — GUI lane generalization + small hygiene (owner-reviewed 2026-07-28)

- [x] **W21.screen — the daemon must never draw on the owner's screen [M]** — **DONE 2026-07-30** (owner
  reported the daemon running a GUI test on their display mid-morning). Root cause was **not** a rogue GUI
  command: both unit bundles are **app-hosted** (`TEST_HOST = the .app`), so the routine
  `xcodebuild test -only-testing:<App>Tests` the daemon runs on nearly every session **launched the real app**
  and parked a window on the owner's screen — measured from the health gate's `.xcresult`: **Reader 2m52s,
  Notes 49s**, every session and every gate. The guardrails all aimed elsewhere, and two asserted the
  opposite ("plain unit tests … no VM, no window"). Four layers shipped:
  1. **Source fix** — ArchiveCore `ArchiveTestHost`: under `XCTestConfigurationFilePath` the app sets
     `activationPolicy(.prohibited)` and every auto-opening `Window` renders `HiddenWindowStub` instead of its
     real content (the branch lives in the `ViewBuilder`, because `SceneBuilder` has no `buildEither`). Pinned
     by `TestHostWindowSuppressionTests` in **both** suites. Side effect: with no UI to build, the Reader unit
     suite went **172s → ~2s**.
  2. **Enforcement** — `.claude/hooks/no-host-gui.sh` (PreToolUse/Bash, live when `ARCHIVE_UNATTENDED=1`, which
     the daemon now exports) hard-DENIES host UITest runs, `launch.sh`/`gui-drive*`/`capture-window.sh`/
     `cliclick`/`osascript`, a windowed Android emulator, and the iOS Simulator — each denial naming the VM
     route. Interactive sessions unaffected. Harness: `ops/autonomous/tests/prove-no-host-gui.sh` (24 cases).
  3. **Honesty** — the GUI-VM gate had been reporting `✓ gui-vm` for a lane that ran **zero** tests since
     2026-07-28: `tart ip --wait` returns on *networking*, but `tart exec` needs the Tart Guest Agent's vsock
     socket, which comes up later, so every exec failed and the gate fail-opened with `exit 0`. Fixed both
     halves — poll `tart exec true` until the agent answers, and exit **3 = SKIPPED** so `health-gate.sh`
     prints `⊘ … SKIPPED — <reason>` and `— but NOT VERIFIED:` instead of a checkmark.
  4. **Coverage** — `gui-vm-gate.sh` generalized to a per-app table and now runs **Reader + Notes** UITests in
     the VM (`AUTONOMOUS_GUI_VM_APPS`), builds each app's fixture in the guest, mounts the gitignored fixture
     corpus as its own `corpus:` share (so it works from a worktree), and wipes the guest Notes container
     before each run (the `organization.json` INDEX-DB caveat).
  5. **Second escape, same morning — the wrapper-script hole.** With all of the above shipped, a daemon
     session still put `ArchiveNotesUITests` on the owner's screen by running `./ArchiveNotes/test-smoke.sh`:
     the hook matches the Bash **command string**, and that string contains no `xcodebuild` and no
     `-only-testing`, while the script's own whole-scheme `xcodebuild test` includes the UITest bundle. The
     repo's own loop step 2 ("run the touched app's smoke test") pointed straight at it. Closed with two
     layers a string matcher can't provide: both `test-smoke.sh` scripts now run **only the unit bundle**
     under `ARCHIVE_UNATTENDED=1` (so the documented command is *correct*, not just blocked), and
     `ops/autonomous/bin/xcodebuild` — a **PATH shim** the daemon prepends — refuses any `test` action
     without `-only-testing:` at any nesting depth. Hook pattern added too, as the fast third layer.
  7. **Generalization pass across the whole suite (2026-07-30).** Audit of every app + script, not just the
     two touched: the Processor's `scripts/test-smoke.sh` **launches the app with `open` and drives it with
     `osascript`** and had no unattended guard; the **health gate runs in the daemon LOOP**, where no hook
     applies and the session env is out of scope, so `AUTONOMOUS_GATE_OCR=1` would have opened the Processor
     on the owner's screen with nothing in the way; and the PATH shim covered **`xcodebuild` only**, leaving
     the wrapper hole open for every other mechanism. Fixed: `ops/autonomous/bin/` is now one shim per
     screen-reaching binary (`xcodebuild`/`open`/`osascript`/`cliclick`/`emulator`), the gate declares
     `ARCHIVE_UNATTENDED=1`, and the Processor smoke skips its launch step unattended. Clean by comparison:
     `android-ui-drive.sh` already boots the emulator `-no-window`, and all three `launch.sh` are hook-matched.
     A FORWARD tripwire in `prove-vm-lane.sh` (48 checks) now fails any app whose `project.yml` declares an
     app-hosted unit-test bundle without adopting `ArchiveTestHost` — verified to actually fire against a
     synthetic app, so the Processor is covered the day it gains a test target.
  6. **Adversarial audit of the whole lane** (2026-07-30) — 14 findings raised, 5 survived refutation, all
     fixed here: the warn tier had reintroduced the silent green (a reproducibly-failing suite exited 0 and
     printed `✓ gui-vm` with the failure list discarded → now **exit 4 = WARN**, rendered as `⚠ KNOWN
     FAILURES` with the test names, and detail kept in `gui-vm-<app>-LAST-FAILURE.log`); the fixture was
     built only when absent although the suite **mutates** it (→ rebuilt every run; this alone was two of
     the "Notes failures"); no lock around a single shared VM (→ `tart_lock_*`, and the VM is only stopped
     by whoever booted it); plus the runner's two. New harness `ops/autonomous/tests/prove-vm-lane.sh` (31
     checks) pins the exit-code→owner-text mapping, the lock, the shim and the smoke-script guards.
- [x] **W21.vmgui-path — `vm-gui-runner.sh` blames a missing VM when `tart` is merely off PATH [XS · repeat
  cost].** ✅ **DONE 2026-07-31** (this commit, owner's Morning Review walkthrough). Fixed **in
  `ops/gui/tart-lib.sh`**, not in the runner, because that is where the split caused it: the gate carried its
  own `export PATH=/opt/homebrew/bin:$PATH` (`gui-vm-gate.sh:35`) and the runner did not, so the *interactive*
  entry point every doc points a session at was the only one that could be lied to — the second instance of
  the exact duplication `tart-lib.sh` was created to end. The lib now (a) prepends the first
  `$TART_SEARCH_DIRS` entry that actually holds an executable `tart`, only when PATH lacks one, and (b)
  exports `tart_require`, which reports *"tart is NOT INSTALLED or not on PATH — this is not the same as the
  VM being missing"* with the dirs searched and the PATH it saw, and deliberately makes **no claim about the
  VM** (it cannot run `tart list` to find out). Both call sites now separate the two: the runner dies with
  *"tart is installed, but VM '…' does not exist"* only when tart really is present, and the gate SKIPs with
  two distinct reasons. `TART_SEARCH_DIRS` is one list feeding both the search and the message, so the
  message cannot claim to have looked somewhere it did not. **Proved, not assumed:** `bash -n` on all three
  scripts; under `env -i PATH=/usr/bin:/bin` the lib still resolves `/opt/homebrew/bin/tart` and
  `tart_require` returns 0; with `TART_SEARCH_DIRS=/nope/a /nope/b` it returns 1 and prints the
  not-installed text with the searched dirs echoed back. No VM boot needed for either check.
  Previous text: `ensure_vm()` did `tart list 2>/dev/null | … || die "VM 'archive-gui-runner' not found — create it
  first"`, so in a plain non-interactive shell (no `/opt/homebrew/bin` on PATH) it reports the VM as absent
  while the VM is present and healthy. **This has now cost three daemon sessions** (W23.m14, W23.m15, W23.l4 —
  each logged it to Morning Review, one lost a whole lane run), which is why it is a queue item and not a
  fourth note. **Fix:** resolve `tart` by absolute path (or prepend `/opt/homebrew/bin` inside the script), and
  split the two failures in the message — "tart not found on PATH" vs "VM not created (ops/gui/README.md §3)".
  A misleading message here is expensive in a specific way: a session that believes it defers a GUI check to
  the owner that it could have run itself. Same treatment for any sibling `tart` call in `ops/gui/tart-lib.sh`.
  | files: ops/gui/vm-gui-runner.sh, ops/gui/tart-lib.sh | XS | low | none
- [x] **W23.status1 — `arm.sh status` blamed an empty queue for what was a usage cap [XS · misreport].**
  ✅ **DONE 2026-07-31** (this commit, owner's Morning Review walkthrough). For an hour that morning both
  status renderers said *"running, BACKING OFF (idle 3375s — sessions finding no actionable work)"* while
  every session since 06:35 had been **refused with a 429** (five-hour cap, reset 07:30) and died in ~5
  seconds, with `next-queue-item.sh` offering ~20 actionable items throughout. The 429 was sitting in
  `$STATE/last-session.log` the whole time; neither renderer read it. **The two states demand opposite owner
  actions** — "the queue is drained, add work or stop the daemon" vs "it is throttled and resumes by itself"
  — so this is a misreport, not a wording nit; it is the same family as the `last-gate.log` trap in memory
  `health-gate-red-retry-once`. **Fix:** new `ops/autonomous/run-state-lib.sh` owns the question, sourced by
  BOTH `arm.sh` and `status-digest.sh` (writing the check twice is how the tart-PATH trap survived three
  sessions — see W21.vmgui-path, fixed the same day). Keyed on the **terminal** `"api_error_status":429`, not
  on a `rate_limit_event`, so a session that was warned, recovered and did work is not slandered as
  throttled; `resetsAt` distinguishes *"resets 09:21"* from *"already reset 07:30 — next attempt should get
  through"*. Reporting only — the BACKOFF **behaviour** is already correct for a cap, so no control flow
  changed. Both call sites degrade to the old wording if the lib is absent, which is the real window while
  the PRIMARY checkout has not yet merged (memory `arm-installs-from-primary-checkout`). **Proved:** `bash -n`
  ×3; the detector returns throttled for the real 06:35 log and NOT for the real aborted 07:58 log, a
  synthetic future reset renders "resets HH:MM", a warned-but-successful session and a missing file both
  return not-throttled; then end-to-end through the real `status-digest.sh` with a stubbed `pgrep`, printing
  THROTTLED and BACKING OFF from the two real logs respectively.
  | files: ops/autonomous/run-state-lib.sh (new), arm.sh, status-digest.sh | Tier-2 | XS


## Suite doc hygiene (owner / small) — 2026-07-16

- [x] **Archive Notes `00-overview.md` — RESOLVED 2026-07-29 (owner): KEEP IT PERMANENTLY as the Notes interface
  spec. This item is CLOSED — do not re-open it as a doc-hygiene task.** `00-overview.md` is deliberately exempt
  from the "delete a shipped `execution-plans/` plan" convention: that convention targets *stale* plans, and this
  file is not stale — it is the live, load-bearing interface contract for Archive Notes, cited **65 times across 38
  tracked files** (mostly source and test comments), which `ArchiveNotes/CLAUDE.md` now states explicitly. Deleting
  or relocating it would mean rewiring 65 references inside shipped code for zero functional gain. Left in place at
  its current path by owner decision; it was NOT promoted to `SPEC/` (that would make every future edit hold-queue
  and owner-gated — an ongoing tax on a Notes-internal document). Evidence for the decision below.
  - **History.** Originally "fold §16 into `CLAUDE.md`, delete the plan" [S]. The 2026-07-18 review found that
    under-scoped and re-estimated it as "§2/§5/§6/§16, ~190 lines, 8+ citation sites". On **2026-07-29** the owner
    picked that fuller scope — but a `git grep` census then showed **that estimate is also wrong, by a lot.**
  - **Measured reality (2026-07-29, `git grep`):** the file is cited **65 times across 38 tracked files**, spanning
    **31 distinct sections** — §2, §3.1, §3.2, §3.3, §3.4, §3.6, §3.7, §5, §6, §7, §8.2, §8.3, §8.4, §9, §10, §13,
    §15.1, §15.3, §15.4, §15.5, §16, §16.1, §16.3, §D.1–§D.6, plus D2/D9. Citations are **not** doc-to-doc: most are
    source and test comments (`NotesModel.swift`, `MarkdownBridge.swift`, `FrontMatterCodec.swift`, `ZoteroClient.swift`,
    `NotesGUITests.swift`, `DurableLinkE2ETests.swift`, `e2e-durable-links.sh`, `packages/ArchiveCore` parity tests…),
    and it is also cited by `POTENTIAL_FEATURES.md`, `09-gap-closure.md` and `devonthink-import.md`.
    Note `§2` is **not** cited by `ArchiveNotes/CLAUDE.md` at all (that claim was wrong) — it is cited from
    `POTENTIAL_FEATURES.md` and `SUITE_TODO.md` instead.
  - **The repo already treats it as a spec, not a lingering plan:** this very file says it is "**RETAINED** as the
    authoritative interface contract" (L96) and cites `00-overview.md §2` for the locked D1–D10 decisions (L1101).
  - **RECOMMENDATION: keep it permanently and close this item.** The "delete a shipped execution plan" convention
    exists to stop *stale* plans lingering; this one is not stale — it is the live interface contract for Notes and
    is load-bearing in 38 files. Deleting it means rewiring 65 citations across source, tests, scripts and three
    other docs, for no functional gain and a real risk of breaking references. If kept, the right small tidy is to
    **rename/relocate it out of `execution-plans/`** (e.g. `ArchiveNotes/INTERFACE-CONTRACT.md`) so its status is
    obvious and the doc convention is honoured — that is a ~1-line-per-citation path update, still 38 files.
  - **Decide one:** (a) keep permanently, close this item, optionally note in `ArchiveNotes/CLAUDE.md` that
    `00-overview.md` IS the interface spec [recommended]; (b) keep the content but relocate it out of
    `execution-plans/` and update all 65 citations [M–L, mechanical]; (c) genuinely delete it — relocate all 31
    cited sections into `ArchiveNotes/CLAUDE.md` and rewire 65 citations [L, and `CLAUDE.md` becomes very large];
    (d) promote to `SPEC/` — ⚠️ this makes it a cross-app contract and therefore **hold-queue** for the daemon
    thereafter, which is a real ongoing cost for a Notes-internal document.
- **Worktree hygiene (standing rule, not a to-do).** The 4 stray `suite-wt-2026071[45]-…` worktrees this note
  used to list are **gone** (cleaned 2026-07-16) — don't go looking for them. Standing rules: remove your own
  worktree once your work is pushed, and **never touch a worktree you didn't create.** In particular **IGNORE the
  Codex worktree** — `~/Documents/GPT/archive-suite-processor-fixes` (branch `wt/codex-processor-bugfixes-*`) is
  a different agent's and routinely holds uncommitted WIP: do not clean it, remove it, salvage it, or surface it
  to the owner as a stray. Leave it entirely alone (owner instruction 2026-07-16; also in `AGENTS.md`).


## Owner GUI-pass follow-ups — 2026-07-16 (from the interactive Reader + Processor GUI review)

- [x] **Guided key setup for Anthropic (Processor).** The onboarding wizard's `onboardable` list is
  `[.gemini, .mistral, .openai]` — Anthropic has only a manual key field. Add `ProviderKeySpec.anthropic`
  (console.anthropic.com deep links, `sk-ant-` precheck, cost/privacy notes) so Anthropic gets the same guided flow.
  **Verify:** drive the wizard with `ops/gui/capture-window.sh` + `cliclick` and read the shot — the visual half is
  no longer owner-gated (TCC granted). | files: Models/ProviderKeySpec.swift (+ `onboardable`) | S | low | none
  — ✅ shipped: `ProviderKeySpec.anthropic` added (mirrors the `.openai` spec — console.anthropic.com deep
  links for keys/billing/privacy, `sk-ant-` precheck, honest no-free-tier cost/privacy/card notes; URLs +
  wording `// VERIFY`) and prepended to `onboardable` → `[.anthropic, .gemini, .mistral, .openai]` (enum order,
  Anthropic is the lead provider). The item under-scoped its file list: the spec's `validate` closure needs a
  validator, so **`KeyValidator.validateAnthropic`** was also added (cheap `GET /v1/models` with
  `x-api-key`+`anthropic-version: 2023-06-01` — matching the app's Anthropic OCR clients; 200 works / 401·403
  invalidKey / 429 rateLimited / 5xx providerBusy; like OpenAI, /v1/models 200s even for an unfunded account →
  live smoke surfaces that). Keychain account = `LLMProvider.anthropic.rawValue` ("Anthropic"), so the wizard
  writes the same slot the app reads. The wizard is fully generic (the only provider-specific branch,
  `geminiRegionWarning`, returns nil for Anthropic — same as OpenAI). Additive + opt-in; no default-provider
  change. Build clean, 0 new warnings; Tier-1 self-review. **GUI visual (wizard "Set up (guided)…" → Anthropic
  step) → Morning Review** (GUI off this run).
- [x] **OpenAI LLM rotation detection (Processor).** `.openai` is wired to LOCAL Vision rotation only
  (`LLMRotationDetector.swift:72` + `CostEstimator.rotationModelCost` return nil — defensive, like Mistral/gateway).
  OpenAI is a capable vision model, so wire `.openai` into the LLM candidate-compare rotation path + add its
  `rotationModelCost` arm, matching Anthropic/Gemini (keep local Vision as the free default; Mistral genuinely can't
  → leave nil). | files: OCR/LLMRotationDetector.swift, Models/CostEstimator.swift, OCR/OCRProcessor+OCR.swift | M | low | none
  — ✅ shipped: `.openai` wired into the LLM candidate-compare rotation path — extended the `LLMRotationDetector`
  provider guard + added `askOpenAI` (OpenAI vision chat: `image_url` data URLs, Bearer auth,
  `choices[0].message.content` parse; endpoint via `OpenAICompatibleClient.openAIBaseURL`) on a new
  **non-reasoning** `cheapOpenAIModel = gpt-5.4-mini` (deterministic `temperature: 0` + `max_tokens: 8`; a
  reasoning model would reject `temperature` and could burn the tiny budget on hidden reasoning). Added the
  `CostEstimator.rotationModelCost` `.openai` arm `(0.75, 4.50)` + a tiling-accurate per-candidate token estimate
  (765), so the cost estimate now matches the runtime path. Local Vision stays the free default; Mistral/gateway
  still nil; any call failure falls back to local Vision. **`OCRProcessor+OCR.swift` needed no change** —
  `detectRotation` already passes `provider` through generically (the item over-scoped its file list, like
  W13.oai-1). Additive + opt-in; default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **Live-key OpenAI rotation smoke (does gpt-5.4-mini pick the upright candidate?) + final model-ID/pricing
  confirm → keyed/owner tail → Morning Review.**
- [x] **Auto-route multi-page-PDF drops to re-OCR; retire the mode toggle (Processor) — owner-clarified 2026-07-16.**
  A dropped multi-page PDF should just run the re-OCR flow (render each page → LLM-OCR → interleaved image/OCR-text
  PDF) automatically — **no text-layer heuristic.** Owner's rule: `preOCRedInput` exists only to send input through
  the **tagging pipeline** (segment + tag), which is **not relevant to a multi-page PDF** (an assembled document, not
  a page stream to segment). So: multi-page PDF dropped → auto re-OCR; keep `preOCRedInput` as the separate
  tagging-pipeline path (single-page/image input); retire the manual "Re-OCR multi-page PDF" Settings toggle.
  **Tier-2** (PDF output). **Verify:** a render guard on the interleaved image/OCR-text PDF output (the 2-page-SPEC
  surface `DocumentRenderGuardTests` already guards from the Reader side) + `ops/gui/` for the drop-zone / toggle
  removal. | files: Views/OCRView.swift, OCR/OCRProcessor+Pipeline.swift | M | med | none
  — ✅ shipped: new `PDFToImageConverter.isMultiPagePDF` (ext + `PDFDocument.pageCount > 1`) drives
  `autoReOCR = !preOCRedInput && files.contains(where:)` in `OCRProcessor.startProcessing`, replacing the retired
  `reOCRMultiPagePDF` toggle — a dropped multi-page PDF now auto-routes to `performMultiPagePDFReOCR` (the transform
  itself is unchanged), while images/single-page PDFs stay on the standard path and `preOCRedInput` stays the
  deliberate tagging-pipeline opt-in (wins when set). Presence-based so a multi-page PDF is never silently truncated
  to its first page by the image path; output-only, so file-safety holds. Removed the Settings toggle + its
  `@AppStorage`/`DefaultsKeys`/`ProcessingProfileStore` entry; drop zone now accepts images **and** PDFs (label
  "Drop images or PDFs here") and the Tagging panel greys out with an explanation when a multi-page PDF is dropped;
  `preOCRedInput` help text explains the automatic re-OCR. Build clean 0 new warnings; **Tier-2 $0 functional test
  20/20 PASS** (`test-multipage-reocr.sh` — added 9 auto-route/detection assertions incl. the file-safety
  no-overwrite invariant). GUI visual (drop-zone label, toggle gone, Tagging grey-out) + a live multi-page-PDF
  re-OCR run → Morning Review (GUI off this run).
- [x] **Reader tag-filter → token field (selected tags INSIDE the box) [BUG-3 pane shift] — SHIPPED `b5a5a01`,
  owner-verified 2026-07-16 ("no longer pushes the left margin, all is good").** Selected subject filters used to
  render as separate buttons beside the "Add tag filter…" combo box, so each chip's width tipped the content column
  past the window and the root `HStack` re-centered, dragging the file table left. Two container attempts failed
  (a capped horizontal `ScrollView` reserved its max eagerly → overflowed on the FIRST chip; a wrapping
  `FlowLayout` got squeezed to ~one chip wide and piled vertically). Fix: new `Views/SubjectFilterTokenField.swift`
  — an `NSTokenField` whose tokens ARE the filters, bounded (220 pt), single-line, horizontally scrolling, with LOW
  horizontal compression resistance, so adding filters adds **zero** width to the bar → shift fixed by
  construction, and tags live in the box as the owner expected. Replaced/deleted the `TagFilterField` combo box
  (its only call site). Build clean; Reader units 194/195 (the 1 failure is the pre-existing env-only
  `DeepLinkTests.testRevealAndSelectNoRoot`). | files: Views/SubjectFilterTokenField.swift (new),
  Views/NavigationWindowView.swift, Views/TagFilterField.swift (deleted) | done
- **Processing History view — KEEP (owner-confirmed 2026-07-16).** The Tools-tab history view (W12-cost, promoted
  from POTENTIAL_FEATURES 2026-07-15; records actual run cost + a run log, writes only its own store) stays. No action.
- [x] **Visual-render test tooling — the pixels XCUITest can't see (NEW 2026-07-17).** XCUITest only reads the
  accessibility tree (element exists/hittable); it is blind to whether a PDF/scan actually *drew*. Added two
  layers: **(1) headless pixel guards** — `RenderProbe.swift` renders a SwiftUI view (`ImageRenderer`) or a PDF
  page (ArchiveCore `PDFThumbnailer`) to real pixels and asserts on them (`assertRendersNonBlank`,
  `nonWhiteFraction`); `DocumentRenderGuardTests.swift` guards the **2-page PDF SPEC** (page 0 scan / page 1 OCR)
  + a negative "blank page IS flagged" test; runs in the unit bundle with **no launch / no TCC prompt** → health-
  gate-safe. Reference-image diffs via **swift-snapshot-testing** (`SnapshotTests.swift`, new SPM dep). Rendered
  PNGs are logged as `ARTIFACT <name>: <path>` + attached to the .xcresult so a session can `Read` them.
  **(2) live sighted loop** — `ops/gui/capture-window.sh` grabs a running window's on-screen pixels (needs GUI-on)
  to pair with `cliclick`. Installed `imagemagick` for image ops. Reader units 205/206 pass (the 1 failure is the
  known env-only `DeepLinkTests.testRevealAndSelectNoRoot`). Pre-push adversarial review (workflow) fixed 3 issues
  (OCR fixture ink margin vs font-smoothing, uniform grey/black blank detection, AppleScript arg injection in the
  capture script). Considered Appium mac2 → **rejected** (same XCUITest substrate, so same a11y-tree blindness +
  extra TCC surface). | files: ArchiveReader/macOS/Tests/
  ArchiveReaderTests/{RenderProbe,DocumentRenderGuardTests,SnapshotTests}.swift, ArchiveReader/macOS/project.yml,
  ops/gui/{capture-window.sh,README.md}, AGENTS.md | done
- **DROPPED — Live Capture output-folder default** ("forget about this", owner 2026-07-16). The Downloads-if-unset
  default stays; the picker already lets the operator change it. Not an open question.
- **iOS is ON HOLD — read §Project focus before listing anything iOS.** The iOS Drive-relay OAuth client was
  surfaced to the owner in error: iOS *and* the Google-Drive relay are BOTH on-hold/maintain-only. Anything in
  `ArchiveCaptureiOS/` or the Drive path is out of scope until un-held; don't re-list it.
- [x] **Notes: extract a shared numeric sort-date combiner in ArchiveCore [LOW].** `Item.sortDate`
  (`ArchiveNotes/Store/Item.swift`) re-implements the shared `*10_000/*100` formula instead of reusing
  `ArchiveCore.DocumentTags.sortDate` (ArchiveCore exposes no `(year,month,day,decade)→Int?` combiner for Notes'
  `date:String?`+`datePrecision` input). Drift is already caught by a value-parity test
  (`ItemSortDateTests.testItemSortDateMatchesArchiveCoreSharedFormula`), and sort order is display-only (never
  written to a corpus → no file-safety stakes) — so this is a **low-priority** de-dup, below the W9 Notes
  gap-closure. Tier-1. | files: packages/ArchiveCore (new combiner), ArchiveNotes Store/Item.swift | S | low | none
  — ✅ shipped (2 commits): new `DocumentTags.sortDateKey(year:month:day:decade:)` in ArchiveCore is now the
  single source of truth for the SPEC sort formula (`year*10_000 + month*100 + day`; decade→`decade*10_000`;
  year wins over decade; absent month/day = 0; nil when undated). `DocumentTags.sortDate` (Reader) and
  `Item.sortDate` (Notes — parses `date`+precision, then defers the arithmetic) both call it, so the key can
  never drift between apps. Behavior-identical (the parity table + malformed-input nil cases preserved). +5
  ArchiveCore combiner tests; the Notes parity tripwire + its (now-done) comment updated. Verified across all
  three apps: ArchiveCore `swift test` 100 green, ArchiveNotes 520 unit tests green (13/13 ItemSortDateTests),
  Reader + Processor test bundles compile clean (no new warnings). Tier-1 (display-only).
- **CLOSED — `sessionComplete()` dead protocol surface: WON'T DO, PARKED (owner 2026-07-16).** ~30 lines of
  unreachable code in both companions' `SegmentTransport`/`MacClient`/`DriveRelayTransport`/`FileRelayTransport`
  (nothing calls it; the Mac's `/session/complete` route stays as a harmless no-op for older phones). Removing it
  would mean editing the *frozen* `RelayObjectFormat` wire contract (`encodeSessionComplete` +
  `sessionCompleteMatchesGolden`) and the on-hold Drive path for zero functional gain. **Do not re-raise** unless
  the Drive milestone is un-held AND `RelayObjectFormat` is already being edited for another reason.


## Archive Notes — NEW APP (SHIPPED W0–W8, 2026-07; `execution-plans/archive-notes/00-overview.md` retained)

- [x] **W0** **ArchiveCore extraction + Reader/Processor migration (FIRST)** — create `packages/ArchiveCore`, move
  the shared tag/PDF/date contract (facet parser + `sortDate` + read + the audited **write** path + Processor
  vocabulary/formatting + `PDFTextExtractor`/`PDFFormatStatus` + new `RootMarker`/`DurableLink` + `ArchiveSuite`
  recognition) out of both shipping apps and migrate them onto it; behavior-preserving, parity-gated, one audited
  write seam; adds the SPEC delta — `00a-archivecore-refactor.md` — **Tier-2** (TagWriter + both apps + SPEC)
  (S0 `f050d88` → S5 `cd7ff4f` → S6 `b90800f`)
- [x] **W1** scaffold + app skeleton **depending on the W0 ArchiveCore** — `01-scaffolding-and-core.md` — Tier-2 (scaffold)
  (S1 `7cddf60` → S2 `254fd73` → S3 `91c3c45` → S4 `220b582` → S5 docs — **partial**: app-local
  `README.md`/`AGENTS.md`/`SMOKE_TEST.md` were not actually written at S5; they shipped later under **W9 Phase A**
  `56360f7` (2026-07-18). The SPEC `ArchiveSuite` marker prose section (A4) is still pending — see
  `archive-notes/09-gap-closure.md`.)
- [x] **W2** store + front-matter I/O + virtual folders/replication + FTS5 index — `02-storage-model-and-index.md` — Tier-2 (writers)
  (S1 `64eaa9c` → S2 `02201f0` → S3 `2404852` → S4 `afd06c7` → S5 org graph + organization.json)
- [x] **W3** rich-text/Markdown editor (WYSIWYG + raw toggle, inline images) — `03-rich-text-markdown-editor.md` — Tier-1
  (S1 `0db7f61` → S2 `16e0f43` → S3 `1f740b3` → S4 `2261b1f` → S5 `78a9fb5` → S6 perf+cache+tests)
- [x] **W4** source blocks + page thumbnails + Reader URL scheme/reveal + durable links — `04-sources-and-cross-app-linking.md` — Tier-2 (Reader deep-link)
  (S1 `0b7b89d` → S2 `8a7012c` → S3 `1e81b71` → S4 `f477f3a` → S5 `15c690c` → S6 `0ddf88e` → S7 reveal+preview)
- [x] **W5** Zotero metadata / citations / chips — `05-zotero-integration.md` — Tier-1
  (S1 `3704c6a` → S2 `2dac700` → S3 `97547c1` → S4 `f420346` → S5 settings + degrade polish)
- [x] **W6** viewers + search/filter/sort + replication UI + templates + dates/quality — `06-viewers-search-replication.md` — Tier-2 (delete path)
  (S1 `27d3952` → S2 `70bfd1e` → S3 `c37f175` → S4 `92f84f4` → S5 `3d46c0d` → S6 `598d2f2` → S7 dates & quality UI)
- [x] **W7** extracts (snapshot + provenance, blocks→notes, jump-to-source) — `07-extracts.md` — Tier-1
  (S1 `f5efe60` → S2 `71ca1db` → S3 `50920ce` → S4 `c8c93ee` → S5 `328bff3` → S6 app-quit/window-close autosave flush)
- [x] **W8** tests + XCUITest/cliclick GUI harness (scratch corpus) — `08-testing-and-gui-verification.md` — Tier-1/2
  (S1 `0f164ed` → S2 `6ef2244` → S3 `3aa27e2` → S4 `6f22159` → S5 `2a412c9` → S6 `6ce10a6` →
  S7 GUI-harness scaffold `98a4afc`–`0e7472c` → S8 per-wave GUI checks `f79e279`–`267ca8d` +
  S8b probe-queryability + owner-eye README → S9 durable-link E2E `17a2d27`/`7d2dcb8` + `GUI_SAFETY.md`)
  — **W8 COMPLETE (GUI-on):** full `ArchiveNotesUITests` suite (G0–G11 + Smoke) **13/13 TEST EXECUTE SUCCEEDED**;
  the `an.status.indexReady` probe is now XCUITest-queryable (G0); owner-eye checks (G2/G6/G11 + chip clicks)
  documented in `ArchiveNotes/scripts/GUI-HARNESS.md`. **Completes Archive Notes (Wave 11 / W0–W8).**


## P0 — Finish the Suite publish (network back)

- [x] Push merged history: `main` + `suite-v1.0.0` pushed to `origin` (0 diverged). ✅ 2026-07-06
- [x] Publish release: `suite-v1.0.0` LIVE with `ArchiveSuite-1.0.0.dmg` (4.48 MB) attached. ✅
- [x] Verify online: release published, asset `uploaded`; `origin/main` == locally build-verified tree. ✅
- [x] **Phase F DONE** — redirect banner pushed to the old `archiveprocessor` README; repo **archived** (read-only, `isArchived=true`). ✅ 2026-07-06


## P1 — Quick local wins (S, low-risk, no network)

- [x] Cite `SPEC/tag-format.md` as the shared-contract source of truth from BOTH per-app `CLAUDE.md`. ✅
- [x] Reconcile Reader `CLAUDE.md` prose to SPEC (doc-only; code already correct): page-2 line verbatim/any-ext/may-be-absent; Year 3–4 digits; BC note clarified; Box/Folder/OCR-Failed subjects noted. ✅
- [x] Regression test: `Box`/`Folder`/`OCR Failed` classify as plain subjects (SPEC #3) — added; **110 tests green**. ✅
- [x] Close stale checkbox: near-term-UI item **E3** confirmed shipped & ticked. ✅
- [x] Processor: "Import tag vocabulary from CSV" — added `Import from CSV…` button + file drop target on the vocabulary editor (`SettingsView.swift`; NSOpenPanel + newline/comma parse, de-dupe). macOS build green, no new warnings. ✅
- [x] **Android `targetSdk` 34→36 — DONE 2026-07-08** (builds clean + Android-16 emulator smoke PASSED). Toolchain: installed `platforms;android-36` + `build-tools;36.0.0`; AGP 8.6.1→8.9.1; Gradle 8.9→8.11.1; `compileSdk`/`targetSdk` 34→36; `:app:assembleDebug` **BUILD SUCCESSFUL** (JDK 21). **On-device smoke on the `ap_test36` (API-36 / Android 16) emulator PASSED:** app launches, both connect screens render with correct system-bar insets (no edge-to-edge clipping — screenshots checked), full capture flow drove (pair → 2× shutter → End segment → Skip → Box marker), **camera opened** (CameraService connect), and the phone→Mac protocol ran against a stub (`/ping`, 20× `/phone/status` heartbeat, 3× `/photo`, `/segment/complete`) — **no crash, no foreground-service/permission FATAL, 0 FATAL EXCEPTION**. *(Nice-to-have before Play submission: a final pass on a physical Android 15/16 device — emulator ≈ device but not identical.)* | files: ArchiveCapture/ | done
- [x] Reconcile Bonjour service-name mismatch — iOS now advertises `_archivecap._tcp` (matches the Mac) in both `ArchiveCaptureiOS/project.yml` + generated `Info.plist`; iOS project regenerates clean. ✅


## P2 — Reader features (no network; local build/test)

- [x] Non-standard-PDF **detection layer** — `Core/PDFFormatStatus.swift` (standard/unreadable/noTextLayer; page count is NOT a defect signal — merged >2-page PDFs are legit); persisted in the v2 content index. **117 tests green, lint clean.** ✅
- [x] Surface it — filter-bar "N need attention" toggle (`needsAttentionOnly` filter), health-popover row, per-row ⚠ badge. ✅
- [x] Viewer banner for image-only docs ("no OCR text layer") in the document window — build green. ✅
- [x] Tag near-duplicate detection — `Core/TagSimilarity.swift` (union-find + length-scaled Levenshtein) + `SimilarTagsSheet` review UI (Merge drives the existing audited rename). 130 tests green, lint clean. ✅
- [x] Duplicate-filename disambiguation — `Core/DuplicateNames.swift` + a dimmed containing-folder subtitle for rows sharing a base name. 135 tests green, lint clean. ✅
- ~~Side-by-side compare of two selected documents~~ — **dropped (owner: not doing this), 2026-07-06.**


## P2 — Reader performance

- [x] **Parallelize + batch the content-index build** *(Part A — build speed)* — bounded parallel
  `withTaskGroup` extraction + `upsertBatch` + WAL/`synchronous=NORMAL` + `existingMTimes()` +
  `performMaintenance`. 185 tests green. Tier-2 APPROVE. | done
- [x] **Ranked (bm25) search + search-during-index refresh** *(Parts B+C)* — bm25 relevance-ranked
  search (SQL `ORDER BY bm25`, column weights name=10/class=5/body=1, ordered `[String]` return,
  `ftsRank` map, `.relevance` auto-sort, lifecycle + persistence coercion) + auto-refresh active FTS
  query on index pass completion. 186 tests green. Tier-2 APPROVE. | done
- [x] **Prune the content index** — gated cache eviction: `!isGathering && !files.isEmpty` +
  two-emission absence confirmation + component-boundary root scope + batched deletes. Its own pass
  (`pruneIfSettled`), not folded into `startIndexing`. Root-switch resets pending-prune state.
  Corpus-wide counts now correct at source (the `among:`-scoped workaround stays as defense-in-depth).
  191 tests green (5 new). Tier-2 APPROVE (7/7 vectors). | done


## Owner-requested batch (2026-07-09) — Processor output + Reader UX/viewer

- [x] **Multi-column OCR output layout** — `textColumns` setting (1/2/3, default 1) in Settings +
  ProcessingProfiles; body text on page 2 flows into N CoreText columns (header stays single-column,
  full-width). Threaded through OCRProcessor, SessionProcessingConfig, LiveCaptureProcessor (Codable-safe
  with `decodeIfPresent` fallback). Build clean 0 new warnings. Tier-2 APPROVE (7/7 vectors). 7 synthetic
  tests green. GUI-verify deferred: verify on a real multi-column newspaper scan → Morning Review. | done
- [x] **Multi-page PDF → per-page LLM OCR → single alternating image/OCR-text PDF** _(owner-requested 2026-07-15; SHIPPED — new "Re-OCR multi-page PDF" Process-Files mode)_
  — a NEW Process-Files mode: accept an existing **multi-page PDF**, render EACH page to an image, send each
  page-image to the LLM for OCR (re-OCR the page images — distinct from the existing `preOCRedInput` mode, which
  only extracts the embedded text layer), and output ONE PDF whose pages **alternate image, OCR-text, image,
  OCR-text, …** (each source page → its image page + a selectable OCR-text page). **Mostly assembles from
  existing primitives:** `PDFGenerator.mergeDocumentPDFs` already interleaves image1,text1,image2,text2,…;
  `OCRProcessor.performOCRCall` is already per-single-image; `PDFGenerator.generate` builds the per-page
  image+text unit. **New bits:** a "render ALL pages" variant of `PDFToImageConverter` (today hard-codes
  `page(at: 0)`); a pipeline branch in `OCRProcessor.startProcessing` / `convertPDFInputs` that fans one input
  PDF into N page-jobs then reuses generate+merge; a mode toggle beside `preOCRedInput` (+ a `DefaultsKeys` entry)
  in `OCRView.swift`. **Tier-2** (PDF-writing output — adversarial review + scratch-copy functional test, NEVER
  the real corpus). SPEC: add a short note to `SPEC/tag-format.md` §2-page structure (the interleaved shape
  already matches multi-page-document output + is covered by the "consumers must not hard-assume 2 pages" clause,
  so it's a coordinated Processor+Reader+SPEC clarification, not a format break). |
  files (verify at impl): OCR/PDFToImageConverter.swift, OCR/PDFGenerator.swift (generate + mergeDocumentPDFs),
  OCR/OCRProcessor+OCR.swift (performOCRCall, convertPDFInputs), OCR/OCRProcessor+Pipeline.swift (startProcessing),
  Views/OCRView.swift (intake + mode toggle), SPEC/tag-format.md | M | med | none
  — **DONE:** `DefaultsKeys.reOCRMultiPagePDF` + `ProcessingProfileStore`; `PDFToImageConverter.renderAllPages`
  (fail-loud, no partial set); `OCRProcessor.performMultiPagePDFReOCR` (render all pages → per-page OCR via
  `performOCRCall` → `PDFGenerator.generate` per page → `mergeDocumentPDFs` into ONE alternating image/OCR-text
  PDF), branched in `startProcessing` BEFORE `preOCRedInput`; a pure transform (no Finder tags — output never
  overwrites the input via `uniqueOutputURL`). Settings toggle (mutually exclusive with pre-OCRed; disables
  batch + separate-image export), Process-Files "Drop PDFs here" intake + PDF accept-gate + grayed Tagging box.
  SPEC §2-page-structure interleaved-variant note added. **Tier-2:** adversarial self-review + `$0`/key-free
  functional test `scripts/test-multipage-reocr.sh` (`MultiPageReOCRTestDriver`, 11/11 PASS incl. the
  input-overwrite guard); merge-safety regression still green; build clean, 0 new warnings. GUI visual check
  (toggle render / drop-zone flip) deferred → Morning Review (launch-time Keychain prompt blocks it unattended).
- [x] **Shared provider text-completion client** — **ALREADY SHIPPED `f1d2263` (suite-v1.2.0), before the
  2026-07-15 promotion re-listed it.** `OCR/LLMTextClient.swift` is the shared text-completion client;
  `TagGenerator` + `CollectionSegmenter` both delegate to it, each keeping its own `maxTokens`/timeout so request
  bodies stay byte-identical (the Mistral-signature drift was reconciled deliberately, not blind-merged).
  Verified in-tree 2026-07-16 (file present; both callers reference it). Promoted-in-error 2026-07-15 (`1ee659c`) —
  the POTENTIAL_FEATURES source entry was stale.
  | files: Tagging/TagGenerator.swift, Tagging/CollectionSegmenter.swift, OCR/LLMTextClient.swift | done
- [x] **Live Capture output-folder picker** — **ALREADY SHIPPED `782dfdd` (suite-v1.2.0), before the 2026-07-15
  promotion re-listed it.** LiveCaptureView has the picker (`chooseOutputFolder()` + NSOpenPanel), a "Choose…"
  button, the current-destination "Output folder" row, a `?` HelpButton, and gray-out in Stage-for-later mode —
  unified on the SAME `DefaultsKeys.outputDirectory` as Process Files (one source of truth). Verified in-tree
  2026-07-16. Promoted-in-error 2026-07-15 (`1ee659c`). **Residual (owner):** the owner's promoted wish said the
  default should be "not Downloads"; the shipped default is Downloads-if-unset (visible + changeable via the
  picker). Whether to change the default (and to what — last-used vs a dedicated folder) is an owner call →
  Morning Review. | files: Views/LiveCaptureView.swift | done
- [x] **Cost tracking + processing history** _(promoted 2026-07-15; SHIPPED 2026-07-16)_ — persist each run's **actual**
  cost plus a run log (timestamp, provider/model, file count, results/failures) and surface a simple history view.
  `CostEstimator` already does the per-model math for *estimates*; this records **actuals** and accumulates them.
  Writes only its own store (Application Support / UserDefaults) — **never** the corpus. **Tier-1**.
  | files: Models/CostEstimator.swift, Models/DefaultsKeys.swift, Views/ToolsView.swift (or a new history view) | M | low | none
  — **SHIPPED:** `Models/ProcessingHistory.swift` — `ProcessingRun` + in-memory `RunHistorySnapshot` (params captured at
  run start; cost = the SAME `CostEstimator` math the pre-run pane shows, applied to what ACTUALLY ran — no provider
  returns per-call token usage) + bounded (200) `ProcessingHistoryStore` (JSON in UserDefaults, never the corpus).
  `OCRProcessor` records at EVERY genuine completion tail (startProcessing + resumeRun pre-OCRed/standard + resumeBatch;
  resume snapshots rebuilt from the persisted manifest + live rotation/scale); cancel/interrupt paths never record.
  `Views/ProcessingHistoryView.swift` — a Tools-tab sheet (per-run provider·model/mode/counts/cost, summary totals,
  confirm-gated Clear; cost footnoted as an estimate, not billed). **Tier-1** verified: build clean, 0 new warnings +
  `$0`/no-key/no-GUI headless self-test `scripts/test-processing-history.sh` (`ProcessingHistoryTestDriver`, 19/19 PASS,
  against a THROWAWAY UserDefaults suite — never the operator's real history). Visual GUI check deferred (launch-time
  Keychain prompt blocks the Processor GUI unattended) → Morning Review.
- [x] **Global keyboard shortcuts + dark-mode pass** _(promoted 2026-07-15; re-scoped 2026-07-16; VERIFIED 2026-07-16)_ —
  Tier-1 audit; **no code change needed** (both sub-items already correct in-tree — churning clean code would be worse).
  **(a) Shortcut coverage — complete & correct:** `Views/ProcessingCommands.swift` exposes the two main-window
  commands (⌘R Start Processing, ⌘⌥P Cycle Provider) as a menu-bar `CommandMenu` = the single source (key
  equivalents shown; routes via `NotificationCenter` → MainActor observers with a `TextEditingGuard` so a shortcut
  never steals a keystroke). Every OTHER `.keyboardShortcut` in the app is a `.defaultAction`/`.cancelAction`/⌘Return
  **scoped to a modal sheet** (correctly NOT global menu commands) — matches the Reader's "menu bar = single source"
  convention. **(b) Dark-mode — static audit clean:** all chrome uses adaptive `Color(nsColor: .controlBackgroundColor
  / .windowBackgroundColor / .textBackgroundColor)`; text uses `.primary`/`.secondary`/`.tertiary` + adaptive accents;
  `white`/`black` literals appear ONLY for document/paper rendering (thumbnail/PDF-output/OCR-test canvases — must
  stay), modal scrims (`black.opacity(…)` — intentional dimming), and glyphs/text on dark scrims or saturated colored
  badges; the one AppKit token field sets `drawsBackground = false` (the adaptive pattern). No custom `Color` palette/
  extension, no named-image chrome (`Image(systemName:)` only), no forced `.preferredColorScheme` / `NSApp.appearance`
  / `window.backgroundColor` override. **Human visual dark-mode spot-check deferred → Morning Review** (the Processor
  GUI can't launch unattended — blocking login-Keychain prompt; no Processor XCUITest harness). | files (audited):
  Views/* (all), Views/ProcessingCommands.swift | S | low | none | done
- [x] **Incremental processing (skip already-processed files)** _(promoted 2026-07-15; SHIPPED 2026-07-16)_ —
  re-running a directory now processes only new/changed files instead of redoing everything (matters at 150k scale).
  Skip key = the owner-specified one: an existing `<output>/<base>.pdf` whose mtime is no older than the source.
  **Fail safe: when in doubt, PROCESS** — never silently skip a file that needed processing. **Tier-2** (a wrong
  skip = silently missing output). | files: OCR/OCRProcessor+Pipeline.swift, Views/OCRView.swift | M | med | none
  — **DONE:** new pure `OCR/IncrementalSkip.swift` (`partition(inputs:outputDirectory:)`) is the safety-critical
  decision core; skips a source ONLY when its base name is unique among inputs, the candidate `<out>/<base>.pdf`
  is a distinct file (not the source itself), exists as a regular file, both mtimes are readable, and source
  mtime ≤ output mtime — every ambiguity falls through to PROCESS. Opt-in toggle `DefaultsKeys.skipAlreadyProcessed`
  (default OFF, Settings ▸ Input & Processing; also a `ProcessingProfile` key). Filtered at the top of
  `startProcessing` and confined to plain per-file output (skipped for Live Capture pre-grouped handoffs,
  collection-organized, and merged runs, where an output can't be attributed to one source — a safe no-op there);
  the skipped count is surfaced in the completion status, and an all-skipped run finishes with a clear
  "nothing to do". **Tier-2 verified** (no-key Processor): headless `$0` `scripts/test-incremental-skip.sh`
  (`IncrementalSkipTestDriver`, INCREMENTAL_SKIP_TEST=1) — **13/13 PASS** across every fail-safe branch,
  mktemp-isolated (never the corpus) — plus adversarial diff review + build clean, 0 new warnings. GUI visual
  check (toggle + status line) deferred → Morning Review (Processor GUI launch = blocking login-Keychain prompt).
- [x] **Remove the phone "Finish" button** _(owner decision 2026-07-15 — "get rid of it"; premise found STALE —
  already done, reconciled 2026-07-16 `W12-finish-button`)_ — the phone's **Finish**
  (`CaptureViewModel.finishSession()` → `MacClient.sessionComplete()` → `POST /session/complete`) is near-useless
  and actively misleading: the Mac handler (`CaptureServer.swift` ~L242) only sets a status string and returns OK —
  it does **not** start finalize, so the operator must still click **Finish session** on the Mac. **End segment**
  stays the phone's only "done" action; the Mac's Finish session stays the finalize trigger. Remove the button +
  its call from **both** companions (keep them in sync). **Leave the Mac's `/session/complete` route in place** (a
  harmless no-op) so an older/unupdated companion still works — do NOT change the protocol in the same pass.
  | files: ArchiveCapture/ui/CaptureScreen.kt + capture/CaptureViewModel.kt,
  ArchiveCaptureiOS/UI/CaptureScreen.swift + Capture/CaptureViewModel.swift | S | low | none
  — **ALREADY DONE (stale premise, like recent-years/de-dup).** The phone **Finish button + its `finishSession()`→
  `sessionComplete()` UI call are already gone from BOTH companions** — removed in `ce55511` ("Live capture: End
  segment is the only 'done' action"). Verified in-tree 2026-07-16: neither `CaptureScreen.swift` nor
  `CaptureScreen.kt` has a Finish button (both only expose **End segment** = `finishDocumentSegment()` →
  `segmentComplete(...)`, the segment signal — NOT `sessionComplete`); a full-tree grep finds **zero callers of
  `sessionComplete()`** in either companion's UI/Capture/Net; both UIs even carry a "there is no separate Finish"
  comment. The Mac's `POST /session/complete` route is intact (`CaptureServer.swift:284`), as the item requires.
  So the actionable scope (remove the button + its UI call, keep the Mac route) is fully satisfied — no code change.
  **Residual (OUT OF SCOPE this pass → Morning Review):** `sessionComplete()` survives as **dead protocol surface**
  in the Net/ transport layer (the `SegmentTransport` protocol + `MacClient`/`DriveRelayTransport`/`FileRelayTransport`
  impls, both companions). Removing it would touch the **frozen** `RelayObjectFormat` wire contract
  (`encodeSessionComplete` + the `sessionCompleteMatchesGolden` test) and the maintain-only cloud path, i.e. it
  **"changes the protocol"** — which the item explicitly forbids "in the same pass." Left as an optional future
  protocol-cleanup pass (owner-gated). Doc-only reconciliation (Tier-1, no build needed — tree == `a624ccf`).
- [x] **Cap recent years at 5 (both companions)** _(owner decision 2026-07-15; SHIPPED 2026-07-16)_ — both
  companions now cap the recent-years quick-chip list at **5** (was 6): iOS `Array(ys.prefix(5))`
  (`CaptureViewModel.noteYear`) + comment; Android `.take(5)` (`Prefs.noteYear`) + `max 5` doc comment. Kept in
  sync. Migration-safe (a previously-stored 6th year is truncated on the next `noteYear`; it is only a UI
  convenience list — no tag/corpus write, so Tier-1). **Verified:** iOS `xcodebuild` **BUILD SUCCEEDED** + Android
  `./gradlew :app:assembleDebug` **BUILD SUCCESSFUL**, no new warnings; no unit test asserts the cap. Visual
  chip-count check (needs seeding ≥6 recent years then opening the tag sheet on device/emulator — an
  E2E-harness-level drive, disproportionate for a one-line display cap) → Morning Review.
  | files: ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift (recentYears), ArchiveCapture/.../data/Prefs.kt (recentYears) | S | low | none
- [x] **Adjustable + collapsible side panels** — `PanelDivider` (drag-to-resize, 140–350 / 160–400
  clamped, `@AppStorage`-persisted widths); sidebar + tag cloud toggle via toolbar buttons + View menu
  shortcuts ⌥⌘S / ⌥⌘T; animated expand/collapse. 191 tests green, 0 warnings. | done
- [x] **Add/remove columns in the file list** — right-click the column header → checkmark menu to
  show/hide any column (except File name); visibility persisted via UserDefaults. `ColumnPickerHeaderView`
  subclass + `AppSettings.hiddenColumns`. |
  files: Views/AppKitTableView.swift, Core/AppSettings.swift | done
- [x] **Make tags editable in the file list _again_** — `TagTokenCellView` (NSTokenField in NSTableCellView)
  replaces the plain-text tags cell; edit-start base snapshot + freeze-during-edit + WYSIWYG commit on blur,
  all routing through `commitSubjectEdit` → `TagWriter`. Tier-2 APPROVE (6/6 vectors). 191 tests green,
  0 warnings. GUI write-verify deferred (screen locked). | done
- [x] **No dates in the tag cloud** — exclude Year/Month/Day **and decade** facets; show subjects only
  (facet classification already exists in `DocumentTags`). | files: Views/NavigationWindowView.swift
  (tag-cloud panel), Core/DocumentTags.swift | S | low | done
- [x] **Remove date tags from the tag filter search** — months/years/decades must not appear as
  suggestions/targets in the tag filter field. | files: Views/TagFilterField.swift, Core/DocumentTags.swift | S | low | done
- [x] **Logarithmic tag-cloud sizing** — size by `log(count)` (or similar) so a 1000-count outlier doesn't
  crush the 2/10/20/100/1000 gradient into uniformly tiny text. | files: Views/NavigationWindowView.swift | S | low | done
- [x] **Wrap (not clip) file tags in the list** — `usesAutomaticRowHeights` + multi-line `NSTokenField`
  (`wraps = true`, top/bottom constraints). Build clean, 191 tests green. GUI-verify deferred (screen
  locked). | files: Views/AppKitTableView.swift | S | low | done
- [x] **Decade tags ("1970s", "1980s")** _(plan: `execution-plans/decades-date-facet.md`)_ — SHIPPED.
  SPEC + Reader parse/sort/display/topicalTags + write-path safety (year supersedes decade) +
  Processor Year-field help text. 12 new unit tests (182 total green). Tier-2 APPROVE. Defaults
  applied for the 4 open questions (italic=yes, no Reader decade editor, no hard validator, cloud/filter
  exclusion structural). Plan deleted. | done
- [x] **Incremental (as-you-type) OCR search** — debounced 150ms Combine pipeline on `$fullTextQuery`
  triggers `runFullTextSearch()` as-you-type; FTS5 MATCH + bm25 is indexed and fast at scale; existing
  `ftsGeneration` token handles superseded queries. `.onSubmit` removed (debounce handles it); clear
  button still calls explicitly for instant feedback. 191 tests green, 0 new warnings.
  | files: Views/NavigationWindowView.swift, Views/NavigationModel.swift | done
- [x] **In-viewer find, scoped to the open PDF(s)** _(owner-requested 2026-07-14)_ — ⌘F find bar over the
  open PDF(s): highlights ALL matches (yellow), next/prev navigation (⌘G / ⇧⌘G, wrapping) with a global
  "N of M" count, and searches ACROSS every open document (both panes = page 0 + page 1) — not the corpus
  FTS. New `Core/DocumentFind.swift`: pure `FindNavigator` (reading-order match list + wrap cursor) +
  `DocumentFindScanner` (per-pane match counts via `PDFDocument.findString`). `PDFPaneController` grows
  find-highlight state reapplied on every view rebuild (mirrors the persisted-zoom pattern), so highlights
  survive page cycling; cross-document jumps set the pane target then change `index` so the rebuild applies
  it with no timing race. 10 new unit tests (`DocumentFindTests`, incl. a synthesized text-PDF scanner
  check); build clean 0 new warnings. Read-only → Tier-1. Live GUI drive (highlight render / scroll /
  next-prev / cross-doc jump) → Morning Review (GUI off). | files: Core/DocumentFind.swift,
  Views/DocumentViewerModel.swift, Views/PDFPaneView.swift, Views/DocumentWindowView.swift,
  ArchiveReaderCommands.swift | M | low | done
- [x] **Full-text search snippet previews (keyword-in-context)** _(promoted from POTENTIAL_FEATURES 2026-07-15;
  SHIPPED 2026-07-16 — `80725d3` core, `d797ea8` UI)_ —
  show a `snippet()`-style **keyword-in-context** excerpt for each search hit (the matched OCR text with the query
  term highlighted) so results are scannable without opening each doc. FTS5 has `snippet()` **built in** and the
  content index **already stores the OCR `body`**, so this is a **search-UI addition, not an indexing change** —
  it layers on the shipped bm25 relevance ranking (and is distinct from the in-viewer find above: this is the
  corpus/library search). Read-only, no writes → **Tier-1**. Was deferred out of the `index-parallelization` plan
  (owner, 2026-07-09), which shipped ranking but explicitly not previews. | files (verify at impl):
  Search/ContentIndex.swift, Views/NavigationModel.swift, Views/NavigationWindowView.swift | M | low | none
  — **DONE:** `ContentIndex.searchRanked(query,snippetLimit)` returns every bm25-ordered match path (unchanged
  filtering surface) **plus** bounded FTS5 `snippet()` KWIC previews for the top hits — `snippet()` reads each
  doc body, so a `path IN (…)` filter caps the work at the top N rather than every match at 150k scale (an
  `ORDER BY bm25 … LIMIT` would still evaluate `snippet()` for every scanned row). New pure `Search/SearchSnippet.swift`
  (STX/ETX marker vocabulary shared by the SQL builder + the UI; robust segment parser). `NavigationModel` stores
  per-path snippets (`ftsSnippets`, cleared at every reset site) + `searchSnippet(for:)`; the AppKit list name cell
  grows to a dimmed 2nd keyword-in-context line for a hit (matched terms bold + faint adaptive-yellow wash) via the
  existing `usesAutomaticRowHeights`. **Tier-1** verified: 15 new unit tests (`SearchSnippetTests` + `ContentIndexTests`)
  green; build clean, no new warnings; **GUI-verified** by a new fixture XCUITest (`testOCRSearchShowsKeywordInContextSnippet`,
  **TEST SUCCEEDED**) that OCR-searches a body-only term ("California", in 9/11 fixture bodies, in no filename) and
  asserts the snippet line renders end-to-end. (Pre-existing env-only unit failure `DeepLinkTests.testRevealAndSelectNoRoot`
  — owner's real `archiveRootBookmark` in the shared unit-target UserDefaults — is unrelated → Morning Review.)
- [x] **Drop the top-bar Sort button; sort via column headers** — removed the toolbar Sort menu; primary
  sort via native column-header click (already wired via `sortDescriptorPrototype`); right-click header →
  secondary sort (asc/desc) + remove-secondary + reset-to-default via `ColumnPickerHeaderView`. Dead
  SwiftUI-Table sort code removed (`ArchiveFileComparator`, `sortComparators`, `applyTableSort`). 191 tests
  green, 0 warnings. | done
- [x] **Smart folders behave like a scoped root** — selecting a saved search enters a base scope; user
  filters layer on top; Clear returns to the base set, not the whole root. Sidebar shows a durable
  highlight. Scope persists across relaunch. `LibraryFilter.effective` merge for Save/summary. 170 tests
  green. Tier-2 APPROVE. | done
- [x] **Single-page PDF with an embedded text layer → show its text as plain text (right pane)** — in both
  the document viewer and the navigator Preview, when a PDF has selectable text but no OCR page-2, extract
  the text layer via `embeddedText` and render it as selectable plain text in the right pane. Build clean,
  191 tests green. GUI-verify deferred (screen locked). | done
- [x] **Preview gets its own default zoom** — independent of the document viewer's persisted zoom; default
  to **full page** until the user changes it; on open, **focus the image pane** so keyboard zoom works
  immediately. `PDFPaneController(persists: false)` in preview mode; focus via async dispatch on appear.
  Build clean, 191 tests green. GUI-verify deferred (screen locked). | done
- [x] **⌘0 = "fit full page" everywhere zoom applies** — `.focusedObject(model)` on PreviewSheet
  publishes the viewer model so the existing Document menu ⌘0 (Fit Page) + zoom shortcuts reach the
  preview. Build clean, 191 tests green. GUI-verify: Document menu confirmed; preview-specific test
  deferred (scratch corpus not Spotlight-indexed). | done
- [x] **View non-PDFs (e.g. JPG) in the viewer** — tagged non-PDF images (JPG/PNG/TIFF/HEIC/BMP/GIF)
  now open in viewer + preview via PDFPage(image:) wrapping in DocumentViewerModel.loadCurrent().
  Build clean, 191 tests green. GUI-verify deferred (scratch corpus not Spotlight-indexed). | done


## Owner-requested (2026-07-10) — Reader

- [x] **Exclude a subfolder (inside the root) from indexing _and_ display** — a Settings control to
  name one or more folders under the current root that the Reader should treat as out of scope: their
  files are neither shown in the library nor added to the content index. UI lives in the Reader's
  **Settings** scene (`ArchiveReaderApp.swift:30` — add an "Excluded folders" section / list; a folder
  picker scoped under root that appends rows, each removable). Persist the exclusions (path prefixes,
  and/or security-scoped bookmarks like `RootFolderStore`) via `AppSettings`/a small store. **Apply at
  BOTH gates so "not indexed" and "not shown" actually hold:** (1) _display_ — filter files whose path is
  under an excluded prefix in `NavigationModel.libraryDidChange`/`recompute` (discovery is Spotlight-wide
  by tag in `ArchiveLibrary`, so match on path prefix, not search scope); (2) _index_ — skip excluded
  paths in `ContentIndexer.startIndexing`, **and prune already-indexed rows** under a newly-excluded
  folder (reuse the gated-prune path so search stops matching them; growth stays bounded). Reversible:
  un-excluding re-includes + re-indexes on the next library change. Edge cases: exclusion must be a
  descendant of root; overlapping/nested exclusions dedupe to the outermost; an excluded folder that
  later disappears is a no-op. Mostly build+unit verifiable (path-prefix filter, prune-on-exclude);
  GUI-verify the Settings list + that excluded rows vanish from the list and OCR search. **Not Tier-2**
  (no tag/corpus writes — read/index-side only). | files: `ArchiveReaderApp.swift` (Settings scene),
  new `Search/ExcludedFoldersStore.swift` (or `Core/AppSettings.swift`), `Views/NavigationModel.swift`,
  `Search/ContentIndexer.swift`, `Search/ArchiveLibrary.swift` | M | low


## Deferred from the 2026-07-09/10 autonomous run → queued for next autonomous run

- [x] **Prefix-match as-you-type OCR search** _(W10.1)_ — `ftsMatchExpression` appends `*` to the last token
  (>2 chars) for FTS5 prefix queries ("news" → "newspaper"). Min-length gate skips wildcard for ≤2-char tokens.
  3 new tests (196 total green), 0 warnings.
- [x] **Reader perf (deferred W6.2/W6.5)** _(W8.1)_ — (a) `displayedByID` rebuild gated by `displayedGeneration` counter (skips O(N) dict rebuild on unrelated `updateNSView` calls); (b) `tagCloud` cached + invalidated in `recompute()`. 193 tests green, 0 warnings.
- [x] **Processor OCR throughput (deferred W6.5 — M3–M5). Tier-2** _(W8.2)_ — M3 `handleOCRResult` PDF gen →
  `Task.detached(.utility)`; M4 `processBatchResults` rotation → bounded-concurrent `withTaskGroup`; M5
  Anthropic batch submit → incremental JSON serialization (1-image peak vs all-images). Tier-2 APPROVE
  (18 attack vectors). Build clean 0 warnings. | files: `OCR/OCRProcessor+OCR.swift`, `OCR/BatchOCR.swift` | M | low
- [x] **Processor OCR LOW cleanup (W6.4 L1–L4)** — L1 Gemini `cancelBatch` apiKey → `urlComponentEncoded`; L2
  preserve `errorCode` across 4 OCRResult re-creations; L3 documented `nonisolated(unsafe) static var` concurrency
  contract (write-once-per-run on MainActor, happens-before child tasks); L4 cache previous JPEG in Anthropic +
  Gemini batch loops. Build clean 0 warnings. | files: `OCR/BatchOCR.swift`, `OCR/OCRProcessor+ReviewFlows.swift`,
  `OCR/OCRProcessor.swift` | S | low
- [x] **Reader GUI test harness (XCUITest)** — W7.1–W7.5 shipped (target + accessibilityIdentifiers + fixture-root override + make-gui-fixture.sh + suite). **W7.6 (fixup) — all 14 tests now EXECUTE and PASS** (were 13/14 skipping): fixed the sandbox↔Spotlight fixture load (DEBUG off-Spotlight directory enumeration, since NSMetadataQuery returns nothing for a temporary-exception path), UITest↔owner shared-UserDefaults isolation (no view-state restore/persist in test mode — was inheriting the owner's live filter AND clobbering their settings), the tag-cloud element-type query + row/header click hittability, and marked the UI-test classes `@MainActor` (test-target warnings 171→32). PDFView content panes aren't XCUITest-queryable (framework limit) — asserted via observable chrome instead. | L | med


## P2 — Processor (KI#3 done; rest bucketed by how it can be verified)

- [x] KNOWN_ISSUES #3: zoomed-image scroll monitor no longer swallows scroll app-wide — scoped to the image via a hit-test-transparent probe (`ZoomableImageView.swift`); SwiftUI drag/pinch intact, no OCR/output logic touched. Build clean. ✅  ← GUI-verify (zoom a page >100%, confirm the filmstrip scrolls).
- [x] **[A1 — SHIPPED; owner-gated live-verify remains]** **Owner-requested (2026-07-07): bring the Live Capture Processing pane up to the Process Files "Files" pane's level of detail — on shared central code.** Today the Processing pane in Live Capture is too sparse: when a document **fails OCR the user gets no reason**, and there's **no way to (re)process just one or two files**. It should show the same per-file detail as the Process Files "Files" pane (status, OCR text/error reason, per-file actions) and offer the same **granular fallback/retry options** (retry a single file, change model/rotation and re-run, etc.). The pane likely needs to be **larger** to fit this. **DRY — don't invent it twice:** factor the Process Files file-list + row + per-file action UI into a **shared component** so both the Process Files pane and the Live Capture Processing pane render from one central source, rather than two parallel implementations. Mostly build-verifiable; verify the failure/retry paths in a live run. **Tier-2** if it touches the finalize/retry write path. | files: Views/OCRView.swift (+OCRView+*), Views/LiveCaptureView.swift, Capture/LiveCaptureProcessor.swift, new shared row/pane component | L | med
  - **Progress (2026-07-07, A1 design `.maintenance/A1-shared-pane-design.md` steps 1–9):** SHIPPED — shared `Views/Shared/{ProcessableItem,ProcessableItemRow,ProcessableItemListView,ModelChoiceView}.swift`; Files pane adopts it (`FileItem` adapter, identical render); Live pane fully adopts it (`SegmentItem` adapter, reasons + per-item retry / retry-with-model / rotate-&-re-run / view-text / reveal + grown scrollable box); `LiveCaptureProcessor.retryFailed(groupIds:override:)` generalized (G1 = all-failed footer); failure taxonomy un-conflated (`succeededNoText` for filed image-only docs — labeling only, deletion path untouched); `OCRProcessor.retryOne(...)` extracted. Builds clean, no new warnings. **Files pane inline-disclosure action UI shipped** (overnight, commit `d068a99`): tap-to-expand rows surface retry / retry-with-model / rotate-&-re-run / view-text / reclassify via `OCRProcessor.retryOne(...)` + `ModelChoiceSheet` + `FileTextViewerSheet`; review-mode keyboard/tap gestures preserved (expand only outside review mode). `.fileAsImageOnly` not surfaced (auto-files via `succeededNoText`). **REMAINING:** live-run GUI verification of the new reasons/retry paths (owner-gated).
- [x] **shipped `f1d2263`, suite-v1.2.0** — Behavior-preserving de-dups (audit `wf_4373722d-e70`): shared text-completion client; small cluster (`highestLeadingNumber`, `monthTag`, `acceptedImageExtensions`, `GatewayConfig.fromDefaults`, `liveProcessingMode`); reconcile iOS(5)/Android(6) recent-years cap. **Correction 2026-07-18:** the **finalize/organize move helper** and the **box/folder color-retag** unification were listed here but `f1d2263`'s own commit body **DEFERRED both** (Tier-2, not provably identical — the `trashOrRemove`+`filedGroupIds` vs `fm.removeItem` paths differ, and 3 drifted color-retag copies remain in `OCRProcessor+ReviewFlows.swift`). They are **still open** and live in `ArchiveProcessor/POTENTIAL_FEATURES.md` → *Maintainability / refactor backlog*. | M | low
- [x] **shipped `b1fc5d4`, suite-v1.2.0** — No-API local features: processing profiles/presets + main-window global shortcuts (start / switch provider). | Views/SettingsView.swift, Views/OCRView.swift, new store | M | low
- [x] **shipped `782dfdd`, suite-v1.2.0** — Output-folder picker in the Live Capture pane (+`?` help + gray-out); unify with Process Files `outputDirectory`. **Tier-2** (output path) — add the picker + wire the EXISTING setting; don't change write/move logic. | M | low
- [x] **shipped `d2de49d`, suite-v1.2.0 (owner live-verified pairing).** **Remove the Mac Transport picker — auto-run both receivers.** The phone already chooses its transport at pairing (Wired/Wi-Fi/Cloud), so the Mac-side lan/cloud setting is redundant + a footgun (left on Cloud, Wi-Fi pairing silently dies, and vice-versa — hit live 2026-07-07). Instead: the Mac always runs the LAN `CaptureServer`, and *also* runs the Drive relay watcher automatically whenever it's signed into Google + a session is active (sign-in = the enablement, not a mode). Drop the Transport picker from `SettingsView` (keep the "Sign in to Google Drive" config); emit ONE combined pairing QR (host/port/token + relay token) so any phone-side choice works from a single scan; show dual status (Listening + Watching Drive). Gate the Drive poll to active sessions to save quota. **Tier-2** (Capture/Net/Views) — worktree + adversarial review; verify LAN via the android-ui-test-harness + the cloud path with a paired phone. | Capture/CaptureSession.swift, Views/SettingsView.swift, Views/LiveCaptureView.swift | M | low
- [x] Connectivity UX — **superseded/shipped** by the cloud-transport integration (legible Wi-Fi failure + reachability preflight landed; USB + Drive relay is now the direction). ✅
- [x] **shipped `338dc1b`, suite-v1.2.0 (B2)** — Keep OCR/progress live while the per-segment tag card is open (looks hung today). | Views/LiveCaptureView.swift | S
- [x] Tag card: when the Spotlight tag index is still building, present UI saying so instead of silently-empty autocomplete. ✅ `SystemTagsProvider.isReady` (false until first gather) → SegmentTagCard shows a spinner + "building tag suggestions…" that clears when the query finishes. | Views/LiveCaptureView.swift (SegmentTagCard), Tagging/SystemTagsProvider.swift
- [x] After rotation review, if finalize/processing is still running, show a throbber so the gap before collection naming doesn't look hung. ✅ LiveCaptureView overlay: "Finishing — processing segments…" shown while `isFinalizing && no sheet` (the regen gap; gated off during the finalize move which has its own spinner). View-only — no Capture/ change needed. | Views/LiveCaptureView.swift
- [x] **shipped `6ea268a`, suite-v1.2.0 (B4)** — Re-pair coordination: auto re-show QR on phone re-pair; split "listening" vs "connected"; verify USBBridge re-runs `adb reverse`. | Net/, Views/LiveCaptureView.swift, companions | M
- [x] **shipped `6ea268a`, suite-v1.2.0 (B5; residual `resolvedGroupIds` resurface tracked as B9 in KNOWN_ISSUES)** — Streaming residuals (mostly shipped in the cloud-transport work — Finish drain-gate + phone queue-depth + "End segment = the only done action" landed): finish/verify any remainder — `needsResend` for P10/reclassify in-flight, `completedDocGroups` persistence across Mac restart. | Capture/LiveCaptureProcessor.swift, companions | M
- [x] **shipped `7aace39` + audit fix, suite-v1.2.0 (see KNOWN_ISSUES ✅ FIXED)** — KNOWN_ISSUES #2: merged multi-page docs leave exported originals loose — thread per-page image URLs into `organizeOutput`. **Tier-2 file-move**; needs a live pipeline run. | OCR/CollectionSegmenter.swift, Capture/LiveCaptureProcessor.swift | M
- [x] **Owner-gated: live Google Drive end-to-end test — DONE 2026-07-07.** Android phone→Drive→Mac verified end-to-end (sign-in, single photo, multi-page segment + Mac tag card, Box/Folder markers, Finish; photo durable in the Mac session + backup folder). Fixes landed: `DriveError` legibility + `DriveAuth.init` whitespace-trim; console setup (Desktop client for Mac, Android client + SHA-1 + **Custom URI scheme enabled** for the phone) captured in the Processor CLAUDE.md Live Capture section. ✅
- [x] **iOS Drive-relay on-device OAuth — implemented.** `DriveAuth.swift` (`ASWebAuthenticationSession` + PKCE, `drive.file` scope, thread-safe `TokenStore` for `DriveClient`'s blocking token provider); `CaptureViewModel` gains `TransportMode` (.lan/.drive) + auto-selects Drive when QR has a relay token and user is signed in (falls back on LAN-unreachable too); `ConnectScreen` gains a "Sign in to Google Drive" section. `project.yml` registers the reversed-client-ID URL scheme. **Placeholder client ID** — needs a real iOS OAuth client in GCP project YOUR_GCP_PROJECT (bundle ID `com.archiveprocessor.capture.ios`, "Custom URI scheme" enabled). iOS build clean, no new warnings. On-device testing deferred → `ArchiveProcessor/POTENTIAL_FEATURES.md`. | ArchiveCaptureiOS | M


## P3 — Suite structural

- [x] Processor Implementation Map added to `ArchiveProcessor/CLAUDE.md` — 2026-07-07. ✅
- [x] De-nest the `App/App` folders → `App/macOS/`. Both apps build (0 warnings), 161 Reader tests green, DMG verified. ✅


## Flagged — need the owner present / GUI / a scratch-corpus write

- [x] **Headless GUI-test lane for the daemon — Tart macOS VM (BUILT 2026-07-28).** macOS has no `Xvfb`, so host GUI tests hijack the one console `WindowServer` (the screen); a **Tart** `macos-tahoe-xcode:26.3` VM (macOS 26 + Xcode 26.3, matches host) gives its own virtual display so XCUITest **and** a sighted pixel loop run entirely off the physical monitor. Shipped `ops/gui/vm-gui-runner.sh` + `ops/gui/README.md` §3: **resumable** image pull (skopeo → local `crane` registry → `tart clone`; a network drop costs ≤512 MB vs the non-resumable `tart pull`), VM `archive-gui-runner`, an **XCUITest lane** (Reader UITests build + run + drive the app in-VM — proven, 10/15 pass), and a **VNC sighted lane** (`--vnc-experimental` virtual display; `vncdotool` grabs the framebuffer + injects input from the host — off-screen, and bypasses guest TCC). Also fixed `make-gui-fixture.sh` (was broken since the `c07c98c` corpus slim removed the consecutive `00002–00010` it required → now takes the first 10 real PDFs + honors `AR_FIXTURE_SRC`). **Follow-ups — both DONE 2026-07-28:** (1) ✅ window-scoped the 5 toolbar UITests via a `toolbarButton(_:)` helper in `FixtureUITestCase` (scope to the "Archive Reader" window + prefer the hittable match) → **full Reader UITest suite is 15/15 green in the VM** (was 10/15). (2) ✅ wired into the periodic health gate as a **fail-open** step — `ops/autonomous/gui-vm-gate.sh` + a hook in `health-gate.sh`, **ON by default (owner enabled 2026-07-28; `AUTONOMOUS_GUI_VM=0` disables)**: missing-VM/boot/timeout → skip (never parks; inert where no VM), REDs only on a reproducible `** TEST FAILED **` (retry-once). On-by-default also raised `GATE_MAXRUN`→50 min (absorbs the ~15–20 min VM step; else a slow cold run could false-park), added a fixture-absent WARN, and updated session guidance (CLAUDE.md loop step 2 + resume-prompt STEP 3.5) so sessions verify view/interaction changes in the VM **screen-free, regardless of gui-mode**. **Item-picking gate RELAXED / `gui-mode` RETIRED (2026-07-28, owner-directed):** GUI items now run + verify OFF-screen in the VM by default (no gate); Live-Capture E2E runs on the Android **emulator** (unattended — the harness is "emulator only, never a physical phone"), so the daemon needs **no capability flags at all**. `gui-mode` + its `arm.sh gui`/taskport/UI-automation machinery is DELETED from `arm.sh`, the resume-prompt (STEP 1/2/3.5), the daemon work-fingerprint, `prove-daemon.sh`, and `next-queue-item.sh`; owner-interaction/hardware work is simply not daemon work (→ Morning Review / hold-queue). Model: unattended-by-definition, so flags key off machine capability (there are none left needed), never owner presence. prove-daemon 72/72; taskport confirmed already-secure (nothing stranded). | files: FixtureUITestCase/NavigationUITests/ViewerUITests, ops/autonomous/{gui-vm-gate,health-gate,archive-suite-autonomous,resume-prompt,arm.sh,next-queue-item,tests/prove-daemon}, ops/gui/{vm-gui-runner,README}, CLAUDE.md, ArchiveReader/scripts/make-gui-fixture.sh | done
- [x] **GUI-verified 2026-07-08 (owner-driven, on the AR-Smoke scratch corpus, checked at the on-disk xattr level):** Reader inline tag-editor commit — Return-commit ✓, blur-commit of a completed token ✓. Found the half-typed-fragment case *dropped* the word (the documented no-lost-tag safety) yet left a misleading phantom chip; owner chose **WYSIWYG** instead, so `SubjectTokenField` now commits the field's tokens on blur (typed text sticks). Adds route through `TagWriter` (no tag loss); Tier-2 APPROVE. | files: Views/SubjectTokenField.swift | done
- [x] **Perf-checked the nav Table 2026-07-08 (owner-driven GUI, 40k synthetic scratch corpus): the SwiftUI `Table` JANKS at scale.** Scroll stutters; filter-box *keystrokes* lag + can beachball (per keystroke it re-filters 40k AND re-diffs the whole Table on the main thread); sort is slow. Discovery/load of 40k was fine — it's the Table view layer. At the ~150k production target this would be worse. → spawned the follow-up below.
- [x] **Reader: swap the nav SwiftUI `Table` → AppKit `NSTableView`** — `AppKitTableView.swift` (`NSViewRepresentable` wrapping `NSScrollView`+`NSTableView` with `NSTableViewDiffableDataSource`): virtualized rows + cell reuse (fixes scroll); incremental snapshot apply (fixes sort); debounced `filterSearchText` (150 ms, fixes the typing beachball). `ContextMenuTableView` subclass for right-click menu; `ContextMenuActions` trampoline bridges NSMenu items to `NavigationModel`. Model + `TagWriter` untouched (no data-safety surface). Build clean, 161 tests green. **Full GUI re-verify deferred → Morning Review (owner-gated).** ✅
- [x] Remove stray `InlineTest` tag on the SCRATCH corpus — **N/A: scratch corpus (`AR-Smoke/Batch-A/00001`) no longer exists on disk** (directory empty, file cleaned up). No action needed. ✅


## Processor/Capture — WS11 paced re-review findings (2026-07-18, autonomous)

- [x] **W3.cap-r1 [MED · tag/PDF SPEC] — ✅ DONE (this commit), BOTH FIXES IN ONE COMMIT as required.**
  Premise re-confirmed by symbol first: three `_ = try? MacOSTagger.applyTags(...)` sites remained (line
  numbers had drifted to 666/673/699). Both now go through one new `LiveCaptureProcessor.tagStagedArtifact`
  seam that passes the app's own `jsonTags.colorTag` with `colorIsAuthoritative` fixed `true` — so this path
  can never again infer a Finder colour from a subject string — and returns whether the write landed. A
  refusal is recorded on the new `StagedSegment.untaggedOutputs` (optional ⇒ legacy manifests unchanged) and
  `finalize` warns per filed artifact. Per the 2026-07-18 owner decision the file **still counts as filed**;
  only the silence is fixed. Merge drops its deleted constituents from the record so the warning never names
  a file that no longer exists. Tier-2: `test-recovery.sh` Test 12 (11 new checks) covers colour authority,
  the box-colour regression, a real `uchg`-refused write, the wiring onto the segment, and the merge path —
  56/56 ALL PASS, and **both halves proven non-vacuous** by neutering each in turn (colour → 1 RED, discarded
  result → 2 RED, everything else GREEN). `test-merge-safety.sh` + `test-output-file-safety.sh` re-run clean.
  Build clean, 0 new warnings. Unblocks **W23.m5**, which reuses this exact mechanism for the 9 Process Files
  sites. Original entry: `LiveCaptureProcessor.swift:640/647/673` — **(a) the SPEC subject-collision:** the live path writes tags via the raw `[String]` `MacOSTagger.applyTags` overload (no `colorIsAuthoritative`), so a document segment whose subject is literally "Red"/"Purple" is promoted to a Finder color label (Red=6/Purple=3) → the Reader mis-parses it as a box/folder photo. KNOWN_ISSUES #5's fix (derive authoritative color from classification) was applied to the batch merge path but **never to the live streaming path**. *(Premise manually confirmed: raw overload at all 3 call sites.)* **(b) tag-write failures are silently swallowed** (found by the 2026-07-18 review; was NOT in any KNOWN_ISSUES entry): all three sites are `_ = try? MacOSTagger.applyTags(...)`, so a PDF can land byte-perfect, count as **filed**, and have its **source photo trashed** while carrying no subject/date/priority tags at all — in the Reader that file is then invisible to tag-driven triage. **This is the only way today's "filed" verdict can be wrong without the operator ever knowing.** Owner decision 2026-07-18: record a per-artifact `tagsApplied` and **warn in the finalize summary**, but the file still counts as filed — the bytes are safe and retagging is possible, so withholding "filed" (and thus retaining the source) over-corrects. ⚠️ **THESE MUST BE ONE COMMIT.** (a) changes *which* overload is called; (b) changes *whether the result is discarded* — both rewrite the same three lines, so landing them separately means the second silently reverts part of the first. | Capture | Tier-2

## P3 — Suite structural

- [x] **SUITE.consolidate — one item list, and a doc set where every split has a stated reason.** DONE
  2026-08-01 (`08fa6ed`, `92f0667`, `3483627`, `ec967aa`, `3c00f46`, and this commit). Owner-directed, executed
  interactively with the daemon down. Driven by one morning producing the same defect three times — a stale
  `W21.vmgui-path` checkbox, a six-grants-stale tag list in `resume-prompt.txt`, a prove script false-failing 4
  runs in 6 — every one *a secondary copy drifting from the truth*.
  **Audit:** each document was tested against five criteria (tooling binds its path / distinct lifecycle /
  audience / durability / mutability), per the owner's instruction to check there was "actually a reason and
  not just path determinacy". Most splits survived with the reason now written down — `AGENTS.md` on audience
  (non-Claude agents that never read `CLAUDE.md`), `REVIEW.md` on load pattern, the per-app `CLAUDE.md` files on
  the token-efficiency directive. Four did not.
  **Shipped:** `check-tracker-sync.sh`, WARN-only on every health gate, which also reports untracked actionable
  work (25 assertions); the dead 139K `ARCHIVE_NOTES_PROGRESS.md` retired to `old/`; GUI verification
  de-duplicated to one canonical home in `AGENTS.md`; 160 completed entries moved here out of `SUITE_TODO`
  (3,580 → 1,189 lines); and the plan's 36 open WORK QUEUE entries collapsed to one-liners, removing 208 lines
  of duplicated prose and the dual-write tax on every item edit.
  **NOT done, deliberately:** replacing the plan's checkboxes with bare tag references. Tried and reverted — it
  dropped `(blocked-on: …)` clauses that live only in the plan, flipping `W16.bat6` and `W21.vmgui` from
  `blocked` to `ok`, and W16.bat6 going actionable before W16.bat3 would have inverted a fix order the owner had
  confirmed that morning. The guard already makes that class of drift loud, which was the actual goal. The
  reasoning sits at the code site (`next-queue-item.sh` §2b) and in the plan's WORK QUEUE header, so a future
  attempt starts from it — deliberately NOT left as a lingering execution plan.

