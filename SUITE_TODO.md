# Archive Suite — working to-do queue

The **near-term** to-do queue for both apps (see root `CLAUDE.md` §Docs & backlog convention). Long-term
ideas live in each app's `POTENTIAL_FEATURES.md`; detailed in-flight plans live in `execution-plans/`
(indexed below, deleted when shipped). Full-codebase review: the paced method in `REVIEW.md`. Unattended /
autonomous runs: `ops/autonomous/README.md` (durable plan → self-resume daemon), which drains this queue one
bounded item per fresh session.
Paths repo-root-relative; Reader source = `ArchiveReader/macOS/Sources/ArchiveReader/`,
Processor source = `ArchiveProcessor/macOS/Sources/ArchiveProcessor/`.

Legend — effort S/M/L · risk low/med/high · **needs:** none | gui (drive app at runtime) | owner
(account/manual) | corpus-write (safety-sensitive).

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

## 🎯 Project focus & ON-HOLD areas (owner, 2026-07-09)

**Focus now:** the **wired (USB) + wireless (LAN/Wi-Fi) phone↔Mac transmission** path and the **Android**
companion — plus the core Mac pipeline (OCR/tag/PDF/finalize) and the Reader, which continue as normal.

**ON HOLD — maintain-only** (mirror shared-contract changes so they don't rot, but **no new feature
development, and NOT a code-review or bug-fix target**; keep them compiling — **except the iOS companion,
now fully PARKED, see below**):
- **iOS companion** — `ArchiveProcessor/ArchiveCaptureiOS/`. **PARKED 2026-07-18 — stronger than
  maintain-only: its full-app build is now OUT of the verify loop** (iOS simulator runtime removed to
  reclaim ~18 GB — see `ArchiveCaptureiOS/PARKED.md`). Source retained and still gets shared-contract
  edits; parity is auto-checked via `scripts/test-relay-golden.sh` (host `swiftc`, no runtime needed), so
  it can't rot. Reviving = reinstall a simulator runtime + restore its build line (steps in PARKED.md).
- **Cloud (Google Drive) relay transport** — Mac `Net/{DriveObjectStore,DriveClient,DriveAuth}.swift` + the
  `FileRelayReceiver`/`RelayObjectStore` cloud path (incl. the offline `FileRelay` stand-in); both companions'
  `DriveRelayTransport`/`DriveAuth`/`DriveClient`. The `RelayObjectFormat` wire contract stays frozen — only
  mirror it if a focused change forces it.

*Maintain-only* means: if a protocol/SPEC change on the focus path (LAN/USB, Android) requires it, mirror the
minimum into iOS/cloud so they still build — but don't invest effort or reviews there. **Code reviews + fixes
concentrate on:** LAN transport (`Net/CaptureServer.swift`, `CaptureReceiver`, non-Drive `Net/`), USB
(`Net/USBBridge.swift`), the **Android** app (`ArchiveCapture/`), and the Mac pipeline + Reader.

## Active execution plans (`execution-plans/`)
- `devonthink-import.md` — **PLANNING (Archive Notes; HIGH-risk, Tier-2 + reconciliation gate)**: import the
  owner's personal **DEVONthink 3** database (`~/Desktop/Scholarship/1000 Research Database.dtBase2`, ~7.5 GB,
  internal "Meritocracy Project", ~40k rtf/rtfd/txt notes+excerpts; + `Photo Database.dtBase2` for cross-DB photo
  links) into Archive Notes, losslessly. 3-stage offline pipeline (JXA extract →
  frozen JSON manifest → pure transform → materialize a **fresh** store) + a stop-on-flag verification gate.
  Owner decisions locked (2026-07-17): text notes+excerpts incl. embedded images; archival `file://` →
  durable `archivereader://` Reader links; **primary + additional dates**; pointer-notes → a **Related-notes**
  section. Net-new Notes work: multi-date model (per-date timeline index rows) + Related-notes. Correctness
  core = replicants (shared `uuid` → memberships) vs near-duplicates (different `uuid` → date consolidation),
  and the link-conversion contract (nothing survives as `file://`/`zotero://`/`x-devonthink-item://`; only
  internet URLs stay `://`). See §9 open decisions + §8 owner prerequisites (a Reader root over Archival Photos).
- `archive-notes/09-gap-closure.md` — **IN PROGRESS (Archive Notes post-ship reconciliation; W9; mixed Tier-1/Tier-2)**:
  closes the plan-vs-build + spec-vs-build deltas found after W0–W8 shipped (docs/tracker sync, wire built-but-dead
  features, re-arm safety-net lint/smoke tooling, secondary UI polish), then a **Phase-E verification review** that
  gates flipping the **W9** checkbox + deleting the plan. Phase A docs A1/A2/A3/A8 shipped `56360f7` (2026-07-18);
  `00-overview.md` remains the retained interface contract alongside it. See **W9 (gap-closure)** in the Archive
  Notes section below.
- ~~`autonomous-2wk-hardening.md`~~ — **SHIPPED 2026-07-16/17** (all 12 workstreams; see the DONE rollup above
  + `ops/autonomous/README.md` for the mechanisms, and `ops/autonomous/tests/prove-*.sh` for the proofs). Plan
  deleted per the "delete a shipped plan" convention — git history keeps the detailed Progress log.
- ~~`openai-chatgpt-provider.md`~~ — **SHIPPED (Processor, W13.oai-1/2/3)**: OpenAI/ChatGPT as a first-class
  provider — (1) native `LLMProvider.openai` (model list + param-family adapter + onboarding/validation/cost,
  routed through the reused `OpenAICompatibleClient`) and (2) a one-click **OpenAI gateway preset**. All
  daemon-buildable sub-tasks landed (build-verified, additive + opt-in, default provider unchanged); the
  live-key OCR smoke + OpenAI Batch API (Phase 4) remain the **keyed/owner tail** (see the keyed-tail note in
  Wave 13 + Morning Review). **Plan deleted on ship** (git history keeps it).
- ~~`local-agent-cli-provider.md`~~ — **SHIPPED (Processor, W13.cli-1…4)**: drive OCR/tagging through a locally
  installed, subscription-authenticated CLI (**Claude Code + Gemini CLI + OpenAI Codex CLI**, first-class) with no
  API key — additive `localAgent` config sibling to the gateway (`localAgent > gateway > direct` selection),
  validator + guided wizard + subscription cost pane + full pipeline wiring, all gated unattended at $0 via a
  committed fake-CLI harness. **Plan deleted on ship** (git history keeps it); the real-CLI live smoke +
  gemini/codex install remain the keyed/owner tail (see **Provider expansion (Wave 13)** + Morning Review).
- ~~`archive-notes/` (00a, 01–08)~~ — **SHIPPED** (NEW APP: Archive Notes, W0–W8). The per-wave plans were
  **deleted on ship** (git history keeps them). `execution-plans/archive-notes/00-overview.md` is **RETAINED** as
  the authoritative interface contract (§2 locked decisions, §5 front-matter schema, **§16 Interface Contract**
  cited by `ArchiveNotes/CLAUDE.md`). Cleanup item: fold §16 into `ArchiveNotes/CLAUDE.md` or promote to `SPEC/`,
  then delete — see **Suite doc hygiene** below.
- ~~`index-parallelization.md`~~ — **SHIPPED** (parallel+batched index build + bm25 ranked search +
  search-during-index refresh). Plan deleted.
- ~~`index-pruning.md`~~ — **SHIPPED** (gated content-index pruning). Plan deleted.
- ~~`decades-date-facet.md`~~ — **SHIPPED** (decade date facet). Plan deleted.
- ~~`reader-smart-folders-scoped.md`~~ — **SHIPPED** (smart folders as scoped root). Plan deleted.
- ~~`reader-gui-test-harness.md`~~ — **SHIPPED** (W7.1–W7.5). XCUITest target, accessibilityIdentifiers,
  DEBUG-gated fixture-root override, `make-gui-fixture.sh`, initial test suite (navigation, tag cloud,
  viewer, preview, filter, sort, degrade). Plan deleted.

## ⚠️ Known-issues work — Wave 23 (Codex full-suite review; owner-commissioned 2026-07-29) — TOP OF THE DRAIN

**Source.** An owner-commissioned static full-suite review by Codex, 2026-07-29, against remote `main`
`bfcb38e`. Read-only: nothing was fixed, built, or run. Scope = Processor (macOS + Android; iOS only for severe
parity), Reader, Notes, `packages/ArchiveCore`, suite scripts/release tooling. 24 findings survived its own
refute pass: **5 HIGH · 15 MEDIUM · 4 LOW**. The report itself is archived (gitignored) at
`old/Codex_Review_July_29.md`; **every finding is transcribed below in full, so this queue is self-sufficient —
you do not need the report.**

**Owner routing decisions (2026-07-29).** (a) **W23 drains FIRST**, ahead of the remaining W16/W3.cap/W17–W22
work — these are confirmed bugs, several with silent data loss. (b) All **5 HIGH findings are daemon-AUTHORIZED
per item** via named entries in the plan's `## OWNER AUTHORIZATIONS`, rather than parked in the hold queue —
they are the most valuable findings and the authorization text carries each one's hard constraints. The normal
Tier-2 gate is unchanged, and **scratch-copy-only** still binds absolutely (Reader Core Directive).

**⚠️ LINE NUMBERS ARE STALE — RE-LOCATE BY SYMBOL, NOT LINE.** The review baseline `bfcb38e` is five commits
behind current `main` (`62a10d1`), and W16.cfg1/cfg2/cfg3/cfg5 **substantially rewrote**
`OCR/OCRProcessor+{OCR,Pipeline}.swift`, `OCR/OCRProcessor.swift`, `Capture/SessionProcessingConfig.swift` and
`Views/ToolsView.swift`. Cites in those files have drifted by tens of lines. Every item below names the
**function/symbol**; find that, and treat the line number as a hint only. Re-confirm each premise before fixing
it (Tier-2 requires this anyway).

**Independently re-verified while queueing (2026-07-29, against `62a10d1`)** — so these three are not
taken on trust: **W23.h1** (confirmed, and *worse* than reported — see the item), **W23.h5** (confirmed
verbatim), **W23.m5** (confirmed; 9 `_ = try? MacOSTagger.applyTags` sites, not 3). The other 21 carry Codex's
refute-verified confidence and must be re-confirmed by the fixing session.

**Codex deduped against** `SUITE_TODO.md`, all three `KNOWN_ISSUES.md`/`CLAUDE.md`/`AGENTS.md`, the Notes
`00-overview.md` + `09-gap-closure.md` plans, `devonthink-import.md`, and the gitignored maintenance material.
It deliberately did **not** re-report: W3.cap-r1…r6, W3.net-r1, W16/W17/W19/W20/W21/W22, the owner-closed
immutable-staging-generation proposal, Notes W9 gap-closure, DEVONthink import, the fixed ArchiveCore
lost-update/duplicate-tag work, known Notes asset-write failures, or the parked iOS backlog. It also explicitly
**refuted and dropped** five candidates: the non-ASCII/APFS filename-cap claim, Processor receiver
stale-callback ordering, ArchiveCore partial Finder-tag mutation (already documented), and Reader header
stripping / case-only tag convergence / smart-folder flattening (all intentional, tested behaviour). Do **not**
re-promote those.

**iOS parity is PARKED** (§Project focus): where a finding has an iOS twin (`W23.m1`), fix **Android only** and
record the iOS parity as parked — do not revive the iOS build to chase it.

**Prior-art audit — CLOSED 2026-07-29. Do not go re-mining the archive.** A removed Codex worktree (work dated
2026-07-17, preserved as branch `wt/codex-processor-bugfixes-20260712` + patches in
`old/codex-processor-fixes-20260717/`, ~2,900 uncommitted lines over 8 unpushed commits, **76 commits behind
`main`**) was audited against every W23 defect symbol. **This is the complete list of overlaps — the rest is
superseded** (its run-config work was re-implemented on `main` as `W16.cfg1`–`cfg5`):
- **`W23.h5` — prior art EXISTS** (`PDFGenerator.generateRequiringEmbeddedImage()` + `PDFError.imageEmbeddingFailed`). See the item.
- **`W23.m7` — prior art EXISTS** (`3ea3221`: checked `writeManifest()` + memory rollback). See the item.
- **`W23.h1` — NONE.** Only the `pruneEmptySessions(under: root)` *call site* moved; the function's
  delete-unknown-content logic is untouched. The most severe finding has no head start.
- **`W23.m5` — NONE, and worse than none:** its new call sites are themselves written
  `_ = try? MacOSTagger.applyTags(…)`, i.e. they *repeat* the swallowing bug. Don't copy that code.
- Everything else queued in W23 (all Notes, Reader, ArchiveCore and Android items): **no overlap at all** — that
  branch is Processor-macOS only.
In both "EXISTS" cases: **re-derive against current `main`, never cherry-pick.** Neither was ever build-verified
in this repo, and both predate the W16.cfg* rewrite of the same files.

### HIGH — all five daemon-AUTHORIZED per item (plan §OWNER AUTHORIZATIONS); Tier-2, scratch copies only

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

- [ ] **W23.h3-fu — a replicate can still slip a live membership onto a note already on its way to the Trash
  [S · LOW–MED · residual of W23.h3].** Filed 2026-07-30 while closing W23.h3 (`ae0e6eb`); **not** covered by
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

### MEDIUM

- [ ] **W23.m1 — re-pairing Capture leaves an upload owned by the OLD Mac; the phone copy is deleted on the
  wrong acknowledgement [M · MED · misroute · Android].** `capture/CaptureViewModel.kt` (disconnect/re-pair,
  `inFlightUploads`, the upload coroutine). Disconnect/re-pair clears the current client but **does not cancel
  upload jobs or invalidate `inFlightUploads`** — so a newly paired client refuses to re-enqueue the same item
  while the existing coroutine keeps using its **captured old client**. If the old Mac is still reachable and
  acknowledges, the model marks the item uploaded and **schedules removal of the phone file**, though the
  newly selected Mac/session never received it. Not classified as data loss (the old Mac does hold a durable
  copy) but a **silent destination mismatch** — and it contradicts the Capture requirement that disconnected
  items re-upload to the **new** endpoint.
  **Fix:** make endpoint identity **generational** — stamp each upload job with the pairing generation, cancel
  (or hard-invalidate) jobs on disconnect/re-pair, drop `inFlightUploads` entries for the dead generation, and
  **ignore an acknowledgement from a stale generation** for the purpose of "uploaded → delete local".
  **iOS twin is PARKED** (`ArchiveCaptureiOS/.../CaptureViewModel.swift`) — record the parity gap, do not fix
  it. The existing re-pair known issue is about Mac QR/status/USB UX, not endpoint-generation ownership.
  | files: ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/CaptureViewModel.kt | M | med | none

- [ ] **W23.m2 — Reader cannot display or find page 3+ of Processor's intentional merged-PDF format
  [M · MED · CROSS-APP].** Processor merges multi-page documents as `image1, text1, image2, text2, …`
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

- [ ] **W23.m3 — Notes inline-image resolution escapes the item directory and reads another item's asset
  [S–M · MED · provenance corruption].** `Editor/MarkdownBridge.swift`, `Editor/InlineImageAttachment.swift`,
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

- [ ] **W23.m4 — Reader page-level durable links are broken at command, creation AND reveal time
  [M · MED · shipped-contract regression].** Three independent defects break the feature end to end:
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

- [ ] **W23.m5 — Process Files reports Finder tags as applied after silently discarding tag-write failures
  [M · MED · tag/PDF SPEC] (blocked-on: W3.cap-r1).** `OCR/OCRProcessor+Tagging.swift`,
  `OCR/OCRProcessor+OCR.swift`, `OCR/OCRProcessor+Pipeline.swift`. Automatic tagging, **both** manual tagging
  paths, and copy-source tag pass-through all discard `MacOSTagger.applyTags` errors with `try?`, then populate
  `jobs[].appliedTags` **as though the output were tagged**. On an xattr / coordination / verification /
  permission / filesystem failure the PDF succeeds and the UI+model report tags that are **absent on disk** —
  and Reader then silently omits the file from tag-driven triage.
  **Re-verified 2026-07-29:** **9** `_ = try? MacOSTagger.applyTags(...)` sites, not 3 —
  `+Tagging.swift` ×6, `+OCR.swift` ×2, `+Pipeline.swift` ×1. (Line numbers drifted with W16.cfg*; grep the
  literal.) **W3.cap-r1 is scoped to the three *Live Capture* sites in `LiveCaptureProcessor.swift` only** —
  these ordinary Process Files sites are the remainder. **Blocked-on W3.cap-r1 deliberately: reuse its
  per-artifact `tagsApplied` + finalize-summary warning mechanism, do not invent a second one.** Same owner
  decision applies — warn, but the file still counts as filed.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+{Tagging,OCR,Pipeline}.swift | M | med | none

- [ ] **W23.m6 — Reader can emit durable links carrying a root GUID that was never persisted
  [S–M · MED · broken citations · SHARED CORE].** `packages/ArchiveCore/.../Links/RootMarker.swift` →
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

- [ ] **W23.m7 — Mac tag-card Apply/Skip begins finalization before proving the manifest decision is durable
  [S–M · MED · manifest/finalize].** `Capture/CaptureSession.swift` (Apply/Skip), `Views/LiveCaptureView.swift`.
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

- [ ] **W23.m8 — Android's crash-durable `SessionStore` silently ignores current-manifest publication failure
  [M · MED · metadata loss · Android].** `data/ManifestFileWriter.kt`, `data/SessionStore.kt`,
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

- [ ] **W23.m9 — Reader and Notes indexers report successful completion after SQLite failures, and can
  poison the DB handle until restart [M · MED · CROSS-APP].** Reader `Search/ContentIndexer.swift` +
  `Search/ContentIndex.swift`; Notes `Index/NotesIndexer.swift` + `Index/NotesIndex.swift` +
  `Core/NotesModel.swift`. Two failure modes:
  1. Both indexers suppress `open` and batch-upsert errors with `try?` then **unconditionally finish** — Notes
     reloads the partial index and marks it **Ready**; Reader clears progress and serves partial/empty search
     and format-health results.
  2. **Half-open database:** in both SQLite actors, if `sqlite3_open_v2` succeeds but a PRAGMA, migration, or
     schema-creation step then fails, `db` is left **non-nil**. Every future `open()` returns immediately
     without completing setup or closing the handle — **poisoning the index until process restart.**
  **Fix:** propagate open/batch errors to a typed failure state the UI can show (never "Ready" on a partial
  index); on any setup failure **close the handle and null `db`** so a later `open()` retries cleanly; report
  partial-batch counts. Notes W9 C6 is a scale harness and Reader's index work is scheduling/pruning —
  neither covers error propagation or half-open recovery.
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Search/{ContentIndexer,ContentIndex}.swift, ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/NotesIndexer,Index/NotesIndex,Core/NotesModel}.swift | M | med | none

- [ ] **W23.m10 — `organization.json` export failure is reported as a successful organization change
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
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Index/{OrganizationFile,OrganizationStore}.swift | S | med | none

- [ ] **W23.m11 — the app-wide inline-image cache can display another note's same-named image
  [S · MED · wrong content shown] (blocked-on: W23.m3).** `Editor/InlineImageAttachment.swift`,
  `Editor/MarkdownBridge.swift`. The **static app-wide** thumbnail cache is keyed **only by the
  markdown-relative path** — normally `assets/name.png`. Neither item identity nor the resolved absolute URL
  is part of the key. If notes A and B each own a *different* `assets/x.png`, rendering A caches its thumbnail
  and rendering B **displays A's image without ever reading B's bytes**. Same-named assets across item
  directories are **normal and explicitly supported by the store**, so no malformed data is required.
  **Fix:** key the cache by the **resolved, canonical absolute URL** (plus item UUID), and invalidate per item.
  Blocked-on W23.m3 on purpose: that item makes `resolveAsset` return a canonical contained URL — which is
  exactly the key this needs, so doing m3 first means one correct key instead of two. Not W9 B4 (Reader-page
  thumbnails). | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/{InlineImageAttachment,MarkdownBridge}.swift | S | med | none

- [ ] **W23.m12 — a FAILED move-to-Trash still removes the surviving note from the index [S · MED · note
  disappears].** `Core/NotesModel.swift` → `trashItems`. It **logs** each `NoteStore.delete` failure but then
  deletes **every requested ID** from `NotesIndex` and reloads the list. A note whose directory is still on
  disk therefore vanishes from **All Notes for the rest of the run** — there is no watcher to restore it, and
  the full disk rebuild runs only at bootstrap. This **contradicts the method's own stated safety invariant**
  that a trash failure leaves the note on disk *and discoverable* under All Notes.
  **Fix:** only remove IDs whose delete actually succeeded; surface the failures. Add a test that a failed
  delete leaves the note in All Notes.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift | S | med | none

- [ ] **W23.m13 — several multi-step Notes organization operations leave partial state after a failure
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
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationStore,Core/NotesModel,Core/NotesNavigationModel}.swift | M | med | none

- [ ] **W23.m14 — resolving a missing Reader link synchronously scans the whole archive on the main actor
  [S–M · MED · UI freeze].** `Links/ReaderLinkResolver.swift`. The resolver is `@MainActor`; when an exact
  relative path is missing, `resolve` **synchronously enumerates every descendant** of the granted Reader root
  looking for a matching basename. Clicking **one** broken or moved source link therefore freezes all Notes UI
  for the duration of a **100k–150k-file** archive walk, with **no cancellation**. (The basename fallback is
  intended behaviour — doing it synchronously on the UI actor is the defect.)
  **Fix:** move the fallback off the main actor into a cancellable async task with progress + a bound, and
  keep the resolver's fast exact-path hit synchronous. Notes W9 C6 covers Notes-index scale, not Reader-root
  fallback scanning. | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Links/ReaderLinkResolver.swift | S–M | med | none

- [ ] **W23.m15 — deleting the Inbox or Extracts system folder is permanent and creates ghost memberships
  forever [S–M · MED].** `Views/NotesFolderTreeView.swift`, `Index/OrganizationStore.swift`,
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

### LOW

- [ ] **W23.l1 — the Notes Reader-link containment check is bypassable through a symlink [S · LOW · scope
  bypass] (blocked-on: W23.m14).** `Links/ReaderLinkResolver.swift`, `Views/ReaderPreviewPopover.swift`. The
  resolver uses `standardizedFileURL`, which normalizes `..` **lexically but does not resolve symlinks**, then
  calls `fileExists`, which **does** follow them. A symlink under the granted Reader root pointing at an
  otherwise-accessible PDF **outside** the root is returned as `.resolved`, violating the resolver's stated
  granted-root containment contract. (The app sandbox may independently deny some targets — this is a semantic
  scope bypass, not a claim that every symlink escapes the sandbox.)
  **Fix:** contain on `resolvingSymlinksInPath` / `realpath`, not `standardizedFileURL`. Blocked-on W23.m14 —
  same function, and m14 restructures it. Tests cover `../../` traversal but not symlink/real-path containment.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Links/ReaderLinkResolver,Views/ReaderPreviewPopover}.swift | S | low | none

- [ ] **W23.l2 — a cancelled prune task can still defeat the two-emission absence gate [S · LOW · residual
  race] (blocked-on: W23.m9).** Reader `Search/ContentIndexer.swift`, Notes `Index/NotesIndexer.swift`.
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

- [ ] **W23.l3 — concurrent first-time root-marker creation can orphan newly copied links [S · LOW · SHARED
  CORE].** `packages/ArchiveCore/.../Links/RootMarker.swift` → `ensure`. It checks for absence **before**
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

- [ ] **W23.l4 — Notes accepts impossible day-precision calendar dates [XS–S · LOW].**
  `Views/NoteMetadataInspector.swift`, `Store/Item.swift`. The UI and normalization logic validate month as
  1…12 and day as 1…31 **independently**, never validating the combination against a calendar — so
  `2026-02-31` is persisted as a day-precision date and receives a normal chronological sort key.
  **Fix:** validate the (year, month, day) triple against `Calendar` before accepting/normalizing; reject or
  clamp with a visible message. ⚠️ Sort keys come from ArchiveCore's shared
  `DocumentTags.sortDateKey(year:month:day:decade:)` — **validate at the input seam, do not change the shared
  sort formula.** No current Notes date-validation item covers impossible combinations.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Views/NoteMetadataInspector,Store/Item}.swift | XS–S | low | none

### Follow-ups discovered while fixing Wave 23

- [ ] **W23.h2-fu — concurrent edits can leave the Notes FTS index row transiently stale [S · LOW].**
  Found 2026-07-30 while fixing W23.h2 (adversarial self-review of the fix, not a new review). The `.md` on
  disk is now always correct — `NoteStore.withItem` is atomic — but `NotesModel.mutateItem` does its
  `index.upsertBatch` **after** the transaction returns, and two concurrent `mutateItem`s can commit their disk
  transactions in one order and their index upserts in the **other**. The row for that item then lacks the
  second edit until the next edit or an index rebuild, so the list/FTS can show a stale field while disk is
  right. **Not data loss** (the index is a documented rebuilt-from-disk projection) — hence LOW, not a
  re-open of W23.h2. **Fix options:** carry `ItemTransaction.ref.mtime` into the upsert and have
  `NotesIndex.upsertBatch` skip a row whose stored mtime is newer (a compare-and-set on the projection), or
  fold the upsert into a per-item serialized step so index writes inherit the transaction order. Prefer the
  mtime guard — it also hardens the indexer against W23.m9's failure modes. Test: two concurrent
  `mutateItem`s on one item, then assert the index row matches disk without a rebuild.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Core/NotesModel,Index/NotesIndex}.swift | S | low | W23.h2

- [ ] **W23.h5-fu — Process Files still can't tell a placeholder PDF from a real one (the signal now exists;
  nothing there reads it) [XS–S · LOW].** Found 2026-07-30 while fixing W23.h5. `PDFGenerator.generate` now
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
The two proposed provider plans, now **elaborated with a "Daemon build plan"** each so a fresh autonomous session
can build them: each sub-task below is **unattended, $0, no key, no GUI** (build clean + fake-CLI/unit tests +
self-review), with the live-key verification split out to a **keyed/owner tail** (below) that is flagged to
Morning Review, NOT skipped. Do top-to-bottom, one bounded sub-task per session. **OpenAI first (Tier-1, smaller,
reuses the existing OpenAI-format client), then CLI (Tier-2).** New provider changes stay **additive + opt-in** —
never flip the default provider until the keyed live test passes. Legend as above.

**OpenAI / ChatGPT provider** (plan `openai-chatgpt-provider.md` shipped + deleted W13.oai-1/2/3; Tier-1;
SHARED HOTSPOT = the persisted `LLMProvider` enum, append-only):
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

**Local Agent CLI provider** (plan `execution-plans/local-agent-cli-provider.md` SHIPPED + deleted at W13.cli-4;
Tier-2; fake-CLI harness made the whole gate unattended-satisfiable at $0 — the daemon-buildable code half
W13.cli-1…4 is COMPLETE; only the keyed/owner tail below remains):
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

**Keyed / owner tail (NOT daemon-buildable — do not attempt unattended):**
> The *visual* half of these (does the wizard / Settings row / cost pane look right) is now dischargeable in a
> GUI-on / Morning-Review session via the live sighted loop (`ops/gui/capture-window.sh` + `cliclick` → read the
> shot); only the *live-key / account* halves stay genuinely owner-gated. Don't park a pure visual check on the
> owner as "GUI blocked."
- **⏸️ ON HOLD (owner 2026-07-16) — OpenAI live 2-image OCR smoke** through gateway + native `.openai` (needs an
  OpenAI key). Come back to it. _(Model-ID + pricing `// VERIFY` placeholders are RESOLVED — `openaiModels` is now
  the current GPT-5 generation (gpt-5-nano/-mini/5.4-mini/5.4/5.5) priced per the owner-provided SoCOCRbench
  source; the live-key smoke remains the final ID confirmation, but nothing is blocked on it: the provider is
  additive + opt-in.)_
- [ ] **W13.cli Phase 0 — install `gemini` + `codex` CLIs and confirm entitlements (owner).** Was buried in this
  prose note with no checkbox, so nothing ever tracked it (owner asked for it to be a real item, 2026-07-16).
  Install both CLIs, sign in with the enterprise/Edu accounts, and confirm each is entitled to run OCR. Gates the
  real-CLI live OCR smoke for W13.cli-1…4 (the `claude` path additionally can't run inside a Claude Code session —
  nested-session guard). The fake-CLI harness already covers the code path at $0, so this gates only final
  "shipped". | S | low | owner
- Later phases (not now): OpenAI Batch API (Phase 4) + CLI persistent-`stream-json` perf (Phase 4). Land the
  build-verified code first; these gate final "shipped".

## Known-issues work — Wave 14 (cross-app; owner-requested 2026-07-16)
Actionable open items pulled from the three `KNOWN_ISSUES.md` + the Processor streaming-residuals review, ordered
by value. **Android straggler is first (HIGH).** Each notes what's daemon-buildable vs. the keyed/GUI verify tail.
Legend as above.
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

**Parked — explicitly NOT a Wave-14 work item:** Processor cloud/relay **post-finalize reclassify → duplicate
output** (A11, MED, Drive-milestone) lives entirely in the **Google-Drive relay path**, which is **ON HOLD /
maintain-only** (see §Project focus). Leave parked until the Drive milestone is un-held; do not build it unattended.

## Known-issues work — Wave 15 (shared tag writer; owner-reviewed 2026-07-18)
Promoted from `ArchiveProcessor/KNOWN_ISSUES.md` → "lossless Finder-tag undo must preserve duplicate
occurrences" [MED · shared contract], **bundled with** `ArchiveNotes/KNOWN_ISSUES.md` → the W8-S2 latent
concurrent-write race. Both land on the same `ArchiveCore.CoordinatedTagWriter` choke-point, so the shared
serialization/reconcile layer gets built once instead of paying the shared-Core Tier-2 tax twice.

**Owner review 2026-07-18 settled three questions — do not re-litigate:**
1. **Scope** = bundle the two items (this wave).
2. **Restore semantics** = **occurrence-only**: undo restores the correct *count* of each token; position/order
   is **not** guaranteed (macOS reorders on write and the SPEC already compares as a multiset, so exact-order
   restoration is unobservable and buys nothing).
3. **No persisted undo ledger** — undo stays in-memory/session-scoped, so `TagDelta` needs **no**
   `Codable`/versioning. The CLAUDE.md §12 audit ledger stays unbuilt; it is a separate future item.

**Verified during the review (established facts, don't re-derive):** macOS **does** persist duplicate tag
strings — a scratch probe round-tripped `["A","A","B"]` through both `setResourceValue(.tagNamesKey)` and raw
`setxattr`, so this is a real on-disk state, not theoretical. Forward writes are **already** duplicate-lossless
(untouched tokens kept verbatim + multiset verify) and **color-label undo is already exact**
(`.restoreLabel(Int?)` is a single `Int?` — no multiplicity problem, out of scope). Only the **inverse/undo**
loses occurrences, and closing it needs **both** fixes below: the inverse is computed by `Set` subtraction
(`TagWrite.swift:191-196`) **and** the apply path refuses to re-add an already-present token
(`TagWriter.swift:52`) — fixing either one alone still loses the duplicate.

All five are **Tier-2** (shared audited tag writer) and must **build + test all three apps** (Reader +
Processor + Notes) per the shared-Core rule. All are daemon-buildable ($0, no key, no GUI, no hardware) and
verified on **scratch copies only — never the corpus**. Legend as above.
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

**Explicitly NOT in Wave 15:** the persisted/versioned undo **audit ledger** (Reader `CLAUDE.md` Safety
Protocol §12 — documented but never built; undo is an in-memory `NavigationModel.undoStack` today). Owner
decision 2026-07-18: undo stays in-memory. A durable ledger is a separate future item and must not be
coupled to this bug.

## Known-issues work — Wave 16 (Processor: LAN credential · run config · paid-batch; owner-reviewed 2026-07-18)
Promoted from three deferred `ArchiveProcessor/KNOWN_ISSUES.md` entries after a code-grounded review. **Two of
the three entries were materially over-stated** — the review's main output was deflation plus a few genuinely
unmet slices. Severities corrected in KNOWN_ISSUES; the scope decisions below are the owner's and are final.

### #6 LAN channel — crypto redesign CLOSED (accepted risk); credential hardening promoted
**Owner decision 2026-07-18: do NOT build the TLS/AEAD redesign.** Rationale, recorded so it isn't reopened:
the payload is photographs of **public archival records the owner intends to publish**, so confidentiality is
near-worthless; the integrity loss is bounded by the Recovery Core Directive (idempotent `(group,seq)`,
originals retained in the visible backup folder, deletions via Trash not `rm`); and it needs a targeted
adversary co-located in the same reading room. Encrypting the transport would change the wire contract on
**all three platforms**, needs a physical iPhone + the `ap_test36` emulator E2E gate, and buys little. **Closed
permanently — do not re-promote LANSEC-5/6/7 (secure transport, companion mirroring, packet-capture harness).**

**But two things ARE promoted**, because they are cheap, Mac-only, and need no wire-contract change:
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

### #4 process-global processing settings — consolidation, not greenfield
**Corrected severity: HIGH → MEDIUM-LOW.** The headline scenario (a Process Files run mutating an in-flight
Live Capture's settings) is **already impossible** — Live Capture reads and writes zero globals. Two things the
entry claims as missing already exist: `MacOSTagger.stampUnread` is **no longer** `nonisolated(unsafe)` (it's
`OSAllocatedUnfairLock`-backed since `5b58da8`, so the residual defect is an implicit default at ~13 call sites,
not a data race), and `PendingRunRuntimeConfig` is **already** the versioned, manifest-persisted,
structurally-validated run config the entry asks for. **Owner decision 2026-07-18: extend
`SessionProcessingConfig` to be the single run config** (it already carries 5 of the 6 values) and have
`PendingRunRuntimeConfig` wrap it — **do NOT introduce a third type.**

The residual that justifies doing this at all: the env-gated headless test drivers mutate these globals directly
(`ManifestPersistenceTestDriver` sets `rotationModeForRun`/`standardImageMB`, `MultiPageReOCRTestDriver` sets
`pdfImageMB`/`textColumns`, `MergeSafetyTestDriver` flips `stampUnread`). If a driver runs — **or its `defer`
restore is skipped by a crash** — alongside real work, output gets the wrong embedded-image size, wrong column
count, or a missing/extra `Unread` tag. That is non-zero **precisely because the daemon runs smoke tests
unattended.** All Tier-2 (file-writing/tag paths); Processor has no unit target, so verify via the headless
drivers + `scripts/test-smoke.sh` on scratch fixtures.
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
- [ ] **W16.cfg6 — delete the six `nonisolated(unsafe)` statics; injection mandatory** (blocked-on: W16.cfg2, W16.cfg3, W16.cfg5) **[S].**
  The payoff commit: remove `OCRProcessor.swift:70/73/76/79/82/85`; delete the now-redundant
  `loadStandardImageMB()` and make every run start use cfg1's already-normalized
  `SessionProcessingConfig.fromProcessFilesRunStart()` builder; drop the redundant `explicit…` fallback params
  (`OCRProcessor.swift:114-124`, `+OCR.swift:1117-1133`); and update the three drivers that save/restore statics.
  The compiler enforces completeness. | files: OCR/OCRProcessor.swift, Capture/*TestDriver.swift | S | med | none
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
- **Deferred (needs owner sign-off, NOT queued):** the concurrent-runs + Thread-Sanitizer stress driver
  (verification-plan items 1/2/4). It needs either live API keys for a genuine concurrent OCR run or an
  **owner-approved stub OCR backend**, and the mutate-Settings-mid-run steps need GUI. Revisit if the stub
  backend is ever approved.

### #5 paid-batch — downgraded to LOW; refactor dropped, tests promoted
**Corrected: MEDIUM architecture/safety → LOW maintainability/test-coverage**, retitled *"typed BatchProvider
refactor + provider contract fixtures."* **Three of the entry's four headline risks are already closed and
regression-tested** (persist-before-next-irreversible-action `+Pipeline.swift:593-613`; partial submission as a
first-class journaled state `OCRProcessor.swift:298` + `+Pipeline.swift:408`; cancel-retains-journal-until-confirmed
`+Pipeline.swift:1466-1470`), and the legacy migration decoder already shipped. The comma-joined Gemini `batchId`
still exists but is now a **derived, no-comma-validated, provably-lossless mirror** — the ordered
`submittedChunkIds` array is the source of truth. **Owner decision 2026-07-18: do NOT build the full
`BatchProvider` protocol rewrite** — it would touch the only code path that spends real money in order to remove
risks that are already gone. Revisit only when OpenAI batch (Phase 4) is actually built.
- [ ] **W16.bat1 — provider contract fixtures for the three batch clients' response parsing [M].** The **only
  unmet item in the entry's own verification plan**, and the highest-value remaining slice. `GeminiBatchClient.checkStatus`
  parses **six alternative JSON shapes** (`BatchOCR.swift:511-548`) with **zero tests** — a provider response-shape
  change would silently mark an entire paid batch as failed. Pure-parse, **$0, no network**. Requires promoting
  `parseInlinedResponses`/`parseSingleResponse` (`BatchOCR.swift:559, :588`) and the Anthropic/Mistral JSONL
  parsing from `private` to internal (or extracting free functions) so a headless driver can reach them. Cover:
  all six Gemini status shapes, inline vs result-file, Recitation/blockReason, error entries, key normalization
  (`'0'` → `'file-0'`), empty + malformed result sets, and Anthropic/Mistral succeeded+errored JSONL lines. Wire
  into `scripts/test-batch-resume.sh`. **Also fold in here:** a short operator-facing note pointing at the
  provider console for the lost-create case (see the separate LOW entry below).
  | files: OCR/BatchOCR.swift, Capture/BatchResumeTestDriver.swift, scripts/ | M | low | none
- [ ] **W16.bat2 — headless coverage for the cancel path's journal-retention contract [M].** `cancel()`
  (`+Pipeline.swift:1437-1473`) is the one shipped safety guarantee with **no regression test** — the
  delete-only-if-all-confirmed rule is currently verified by reading the code. Add a small injectable cancel seam
  (a closure) so a no-network driver can prove: all-confirmed → journal deleted; any chunk unconfirmed → journal
  **retained** + status message; multi-chunk Anthropic/Mistral (`chunkIds.count != 1`, :1448-1455) → not
  confirmed, retained; zero chunks → not confirmed.
  | files: OCR/OCRProcessor+Pipeline.swift, Capture/BatchResumeTestDriver.swift | M | med | none
- **Split out as its own LOW entry (tracked in `ArchiveProcessor/KNOWN_ISSUES.md`, NOT queued):** *lost-create
  reconciliation* — if a provider accepts a create POST and the response is lost, the app records the ambiguity
  honestly but cannot list the provider's batches to re-adopt the orphan. Cost is one batch's spend possibly paid
  twice. Building auto-adoption needs **live paid API calls** against each provider's list endpoint (outside the
  daemon's envelope) for a failure mode **never observed here**; the non-idempotent retry policy already stops the
  app from creating the duplicate itself. Ship the operator doc note (in W16.bat1) instead; build only if a
  lost-create event is ever actually observed.

## Known-issues work — Wave 17 (Live Capture durability; owner-reviewed 2026-07-18)
Outcome of the code-grounded review of the last two deferred `ArchiveProcessor/KNOWN_ISSUES.md` architecture
entries: **"one recoverable filesystem-transaction service + operator recovery UI"** and **"immutable, versioned
Live Capture inputs."** **Both headline proposals are CLOSED by owner decision.** Two small units are promoted,
one fix was folded into the already-queued `W3.cap-r1`, and both KNOWN_ISSUES entries were rewritten because
they described machinery that **was never built**.

### ⚠️ The finding that drove the decision: both entries were written in past tense about code that doesn't exist
- RAT claimed Live Capture "freezes exact content hashes" and commits a "receipt." **`grep -rn "sha256|SHA256|CryptoKit"`
  across `Capture/` returns ZERO hits.** There is no receipt anywhere in the finalize path.
- IMMCAP claimed "the narrow safety fix preserves a changed re-upload instead of overwriting." `CaptureSession.ingest`
  still does `try? FileManager.default.removeItem(at: finalURL)` then `moveItem` (`CaptureSession.swift:505-507`).

That is not staleness — it is **fictional shipped work sitting in the data-safety register**, and it would
mislead every cold-start reader (human or daemon) into believing guarantees that do not exist. Both entries are
now corrected in place.

### CLOSED by owner decision 2026-07-18 — do NOT re-promote any of these
The shared **`RecoverableArtifactTransaction` engine**; the bundled **Recovery screen** (Validate/Retry/Export/
**Abandon**); the **companion-persisted photo UUID** wire migration; and the **conflict/reconciliation UI**.
Reasons, recorded so they aren't relitigated:
1. **The guarantees are already delivered by other means.** The finalize deletion gate keys off
   `outcome.filedGroupIds` — an **on-disk fact**, not a promise (`LiveCaptureProcessor.swift:983-986`); every
   deletion is a Trash move; staging is co-located in the **visible** backup folder; `OutputFileSafety.relocateArtifactSet`
   already **is** a copy-verify-install-then-delete transaction; `PendingBatch` v1 already **is** a versioned
   SHA-256-fingerprinted journal. RAT's own stated blocker — the trustworthy tri-state tag reader — **shipped**
   as `ArchiveCore/Tags/TagReading.swift`.
2. **Consolidation would be a net risk increase.** Three understood, separately-regression-tested mechanisms
   beat one general engine with unknown failure modes — in the one subsystem that has already caused real data
   loss. The entry's own verification plan concedes it needs contract tests proving each path's existing
   guarantees survive, i.e. *the same guarantees, differently spelled.*
3. **Finder is already the recovery surface**, via the one-click Backup Folder button (`LiveCaptureView.swift:139-148`),
   and it works in the one case a bundled screen cannot — when the app won't launch. **`Abandon` would also add a
   destructive affordance to a subsystem whose entire design is that no destructive affordance exists.**
4. **IMMCAP's central hazard is unreachable from our own companions.** It needs two byte-distinct uploads on one
   `(groupId, seq)`; but `groupId` is a fresh random `"g" + UUID().prefix(8)` per segment
   (`CaptureViewModel.swift:97`), `seq` is a durably-persisted monotonic counter, retries re-POST the same
   immutable file, and reclassify mints a new groupId. **No such incident has ever been recorded** — the conflict
   UI was speculative.
5. **The queued items retire them.** `W3.cap-r6` is the concrete ~10-line instance of the recoverability hole RAT
   wanted a hundred-times-larger engine for; `W3.cap-r2` delivers IMMCAP's stable-identity pillar with **no**
   persisted generation record, **no** manifest migration, and **no** three-app protocol review. The obsolescence
   runs the *opposite* direction from what the entries assumed — nothing in RAT/IMMCAP makes any queued item
   obsolete (a transaction engine that faithfully commits the wrong destination is exactly as broken).

### Promoted
- [ ] **W17.stg1 — version + fingerprint + fail-closed the Live Capture staging manifest** (blocked-on: W3.cap-r4) **[M].**
  Live Capture's durable state is the **only one of the Processor's three** that is unversioned and unverified:
  `PendingBatch` has `lifecycleVersion` + a SHA-256 `lifecycleFingerprint` and fails closed on an unknown version
  (`OCRProcessor.swift:289-305, :379-383`); `OutputFileSafety.relocateArtifactSet` byte-verifies with
  `contentsEqual` before installing; `StagingManifest` (`LiveCaptureProcessor.swift:709-719`) has **neither**, and
  `loadStagingManifest` (:190-242) **fails SILENT-OPEN** — both decodes fail, `restored` stays empty, and the
  operator sees an empty Processing pane while `_processed/` holds orphaned output. Mirror the proven in-repo
  `PendingBatch` pattern: add `schemaVersion` + a fingerprint, and on a corrupt/unknown-version manifest **rename
  it to `staging-manifest.corrupt-<ts>.json` and surface a banner — never auto-delete, never silently continue.**
  Owner decision: **manifest only** — do NOT add a per-source content hash (that was defensible as corruption
  detection but is optional, and it is *not* collision defense given #4 above). Testable end-to-end in the
  existing `$0` `LIVECAPTURE_RECOVERYTEST` driver. **Sequencing: after `W3.cap-r4`** — both touch `RetainedSegment`
  (:552-563), so let the fingerprint land on settled struct semantics.
  | files: Capture/LiveCaptureProcessor.swift, Capture/LiveCaptureRecoveryTestDriver.swift | M | med | none
- [ ] **W17.det1 — stranded-session DETECTION logic (no UI) [S].** The one operator gap neither Finder nor the
  Backup Folder button covers is **discovery** of a session stranded by a crash. Owner decision: build the
  **pure-logic half only** — scan `backupRoot` for sessions with a non-empty `staged` array and surface the count
  on the existing status line / log. **No new SwiftUI, no banner, no Recovery screen.** This costs none of the
  owner's design-review time and settles empirically whether stranded sessions actually occur before any UI is
  committed to. Revisit the at-launch banner only once this has been seen to fire.
  | files: Capture/CaptureSession.swift, Capture/LiveCaptureProcessor.swift | S | low | none

### Folded into an existing item (NOT a separate task)
The **silently-swallowed tag-write failures** (`_ = try? MacOSTagger.applyTags(...)` at
`LiveCaptureProcessor.swift:640/647/673`) — a real finding that appeared in **neither** KNOWN_ISSUES entry — is
folded into **`W3.cap-r1`** above and **must ship in the same commit as r1's overload fix**, because both rewrite
the same three lines and landing them separately would silently revert part of the first. See that entry.

## Wave 19 — Notes date-mirror + Quality facet (MERGES/replaces Priority) (owner-reviewed 2026-07-18)
Owner decision from the wishlist review, refined: (a) Notes mirrors its front-matter **date** into Finder tags
(reuse the existing Year/Month/Day/Decade facets — **no** SPEC change); (b) **no author** tags; (c) a **single
rating facet, `Q1`/`Q2`/`Q3`**, that **MERGES WITH + REPLACES the legacy Priority facet** — they were redundant
("how important is this document"). Owner-locked contract: 0–3 scale, **`Q0`/unrated writes NO tag** (so the wire
only carries `Q1`/`Q2`/`Q3`); **`Q3` = old `P10`**, mapping `P10`→`Q3` / `P9`→`Q2` / `P8`→`Q1` / `P7`→unrated.
Priority is **retired** (no app or companion writes `P` anymore); legacy `P8`–`P10` on pre-W19 files **alias to
`Q1`–`Q3` on read** — no corpus rewrite. Human-set everywhere, never LLM-emitted: Notes (front-matter), Reader
(edit), Processor's interactive tagging, **and the phone companions** (the old priority control now emits `Q`).
Shared-contract (Tier-2) — SPEC first, then the shared parser, then each app + companions; every code item must
**build + test all three apps**, scratch-only. **This wave REPLACES existing priority UI/plumbing — merge, don't
add a second control alongside.**
- [x] **W19.q1 — SPEC: the Quality facet + Notes-as-date-emitter.** DONE `06fabcc`, **merge revision** 2026-07-18
  — `SPEC/tag-format.md` now defines Quality as the single rating facet that supersedes Priority (Priority row →
  RETIRED + read-alias `P8`–`P10`→`Q1`–`Q3`, `P7`→unrated; `Q3`=old `P10`), records the companions as `Q` emitters
  + the phone↔Mac protocol as a SHARED HOTSPOT, and keeps the Notes date-projection row. Source of truth for q2–q7. | Tier-2 (SPEC) | S
- [ ] **W19.q2 — ArchiveCore: `parseQuality` in shared `DocumentTags` + legacy Priority alias [M].** `Q1`/`Q2`/`Q3`
  → 1–3 (absence = 0); include Quality in facet classification with the **subject-collision rule** (a subject
  literally `"Q2"` survives — facet parse is display/sort/filter only, never a destructive write). **Fold the old
  `parsePriority` into the alias:** `P8`/`P9`/`P10` parse as `Q1`/`Q2`/`Q3`, `P7` as unrated (read-only; nothing
  writes `P`). Unit tests. **Tier-2 shared-Core → build+test Reader + Processor + Notes.** | packages/ArchiveCore/Sources/ArchiveCore/Tags/DocumentTags.swift, Tests/ | M | med | none
- [ ] **W19.date — Notes: project front-matter date → existing Year/Month/Day/Decade tags [M].** `NotesTagProjector`
  additionally projects the item's `date`+`datePrecision` into the existing date facets (reuse
  `ArchiveCore.DocumentTags.sortDateKey`; **no new vocabulary, no SPEC change**). Independent of the quality chain.
  Tier-2 (projector tag write) — scratch `.md` only; the DEBUG scratch-write guard applies. Related hardening:
  W15.tu3 (not a hard blocker). | ArchiveNotes/.../Core/NotesTagProjector.swift | M | med | none
- [ ] **W19.q3 — Reader: Quality REPLACES the Priority column/filter/editor** (blocked-on: W19.q2) **[M].** The
  existing Priority nav facet **becomes** the Quality facet (column + filter + inline edit) — rename `P`→`Q` in
  the UI, don't add a parallel control. Edit via `TagWriter` (set `Q1`–`Q3`; clear = remove the token, never write
  `Q0`). Legacy `P8`–`P10` still display as `Q1`–`Q3` via the q2 alias. Tier-2 (tag write). Build + Reader unit
  tests; live GUI confirm → owner tail. | ArchiveReader/.../Core/, Views/ | M | med | none
- [ ] **W19.q4 — Notes: project front-matter quality → `Q1`–`Q3`** (blocked-on: W19.q2) **[M].** `NotesTagProjector`
  maps the item's front-matter `quality` to the 0–3 scale and projects `Q1`/`Q2`/`Q3`; **0/unrated writes no
  quality token** (and removes a stale one). Tier-2 (projector tag write; scratch-only). | ArchiveNotes/.../Core/NotesTagProjector.swift | M | med | none
- [ ] **W19.q5 — Processor: recognize + preserve Quality; retire priority code paths (foundation)** (blocked-on: W19.q2) **[S–M].**
  Parse Quality for free via the shared `DocumentTags`; ensure Processor tag writes **preserve** an existing
  `Q1`–`Q3` token (never strip a rating as an unknown subject on re-tag / merge / mirror-to-image). Repoint the
  existing priority-writing path (`OCR/OCRProcessor+Tagging.swift` `applyCapturePriorityTags`) to emit `Q`, and
  stop emitting `P`. Never auto-emit from OCR. Foundation for q6/q7. Tier-2 (tag path). | ArchiveProcessor/.../Tagging/, OCR/, Capture/ | S–M | med | none
- [ ] **W19.q6 — Processor: USER-SET Quality in the interactive tagging UIs** (blocked-on: W19.q5) **[M].** The
  user sets the 0–3 rating while capturing/processing. **Merge into the existing priority entry** (don't add a
  second control): a 0–3 selector in **(a)** the **Live Capture per-segment tag card** (`Views/LiveCaptureView.swift`)
  and **(b)** the **Process Files manual tagging** sheets (`Views/ManualTaggingSheet.swift`,
  `Views/ManualSegmentTagView.swift`), carried via `SegmentTagData`/`ManualTagSegment` → a `quality` field on
  `GeneratedTags` whose `allTags` emits `Q1`/`Q2`/`Q3` (0/unrated → **no token**) through the existing
  `MacOSTagger` path. **Tier-2 no-undo Capture path** → adversarial review + Live Capture functional test
  (recovery/manifest drivers), scratch-only; confirm quality survives finalize + the image-mirror. GUI verify →
  owner tail. | ArchiveProcessor/.../Views/, Tagging/GeneratedTags.swift, Capture/ | M | med | none
- [ ] **W19.q7 — Companions: phone priority control → Quality; emit `Q`** (blocked-on: W19.q6) **[M].** The old
  phone priority picker/per-page toggle becomes the 0–3 **quality** control on **both** companions
  (`ArchiveCapture/` Android + `ArchiveCaptureiOS/`), emitting `Q1`–`Q3` (map the 4-level `P7`–`P10` picker → 3
  levels + none; `P10`→`Q3`). **Phone↔Mac protocol is a SHARED HOTSPOT — change all sides together:** the
  companion `MacClient` + the Mac `Net/CaptureServer` route (+ `RelayObjectFormat` if the relay carries it). The
  code change is small (a token/level swap), but it spans the wire contract. Alias-on-read (q2) means an old-build
  phone still works mid-rollout, so no flag-day. Daemon-buildable (code + Android/iOS builds); **on-device /
  emulator E2E (`scripts/e2e-phone-mac.sh`) = owner tail** (companions have no unit tests — the E2E is the gate).
  | files: ArchiveProcessor/ArchiveCapture/, ArchiveProcessor/ArchiveCaptureiOS/, Net/CaptureServer.swift, Net/RelayObjectFormat.swift | M | med | owner(E2E)

## Reader test hardening (owner-reviewed 2026-07-18)
From the review of Reader `KNOWN_ISSUES.md` "Open risks / to verify" — almost all entries were already settled in
code; the owner queued only this one (the others are pruned/soft-backlog there). See that file for the record.
- [ ] **W20.deeplink-isolation — isolate `DeepLinkTests.testRevealAndSelectNoRoot` from the machine's real defaults [S–M].**
  The test builds `NavigationModel()` with no `-ARUITestRootPath`, so `RootFolderStore.resolveSaved()` reads
  `UserDefaults.standard` and picks up the owner's persisted `archiveRootBookmark` → the "no archive folder"
  assertion fails on this machine. The WS7 health gate currently `-skip-testing`s it, so the **no-root deep-link
  path has zero automated coverage here.** Fix: make `RootFolderStore`'s defaults **injectable** (it hardcodes
  `UserDefaults.standard` at `RootFolderStore.swift:15/58`) and have the test inject a **volatile
  `UserDefaults(suiteName:)` with no bookmark**; then drop the `-skip-testing` line in
  `ops/autonomous/health-gate.sh`. ⚠️ **Do NOT** stash/remove the machine's real `archiveRootBookmark` — that's
  the never-mutate-live-root hazard; inject a throwaway defaults instead. **Tier-2** (touches the security-scoped
  bookmark store) — adversarial review; daemon-buildable (build + Reader unit tests, scratch-only). Restores
  coverage + removes the skip. | files: ArchiveReader/macOS/Sources/ArchiveReader/Search/RootFolderStore.swift, Tests/ArchiveReaderTests/DeepLinkTests.swift, ops/autonomous/health-gate.sh | S–M | low | none

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
From the 2026-07-28 Morning Review walkthrough. The VM lane (`ops/gui/vm-gui-runner.sh`, built 2026-07-28,
Reader UITests **15/15** in-VM) is the only way GUI verification runs unattended on this machine — but it is
**hardcoded to the Reader**, so a 10-day-old Processor + Notes backlog still reads "GUI blocked → Morning
Review": the Anthropic key-wizard visual, the multi-page-PDF auto-re-OCR visuals, the three Notes **W14.4
b/c/d** checks, and the Notes **W14.3** extract copy→paste image flow. Generalizing drains them off-screen.

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
  6. **Adversarial audit of the whole lane** (2026-07-30) — 14 findings raised, 5 survived refutation, all
     fixed here: the warn tier had reintroduced the silent green (a reproducibly-failing suite exited 0 and
     printed `✓ gui-vm` with the failure list discarded → now **exit 4 = WARN**, rendered as `⚠ KNOWN
     FAILURES` with the test names, and detail kept in `gui-vm-<app>-LAST-FAILURE.log`); the fixture was
     built only when absent although the suite **mutates** it (→ rebuilt every run; this alone was two of
     the "Notes failures"); no lock around a single shared VM (→ `tart_lock_*`, and the VM is only stopped
     by whoever booted it); plus the runner's two. New harness `ops/autonomous/tests/prove-vm-lane.sh` (31
     checks) pins the exit-code→owner-text mapping, the lock, the shim and the smoke-script guards.
- [ ] **W21.vmgui — generalize the headless-VM GUI lane to Archive Processor + Archive Notes [L]** — one lane,
  three apps, sub-steps in the order below (**Notes before Processor**: Notes already has the UITest target, the
  scratch fixture builder and a 13/13 GUI-on baseline; Processor is greenfield **and** carries the Keychain risk).
  **Reader-specific assumptions to parametrize — the complete list** (`ops/gui/vm-gui-runner.sh`): `PROJ_REL` +
  `SPEC_REL` (L29–30), `SCHEME` (L31), `ONLY_TESTING` (L32 — the *only* env-overridable one today), `GUEST_DD=
  /Users/admin/dd-reader` (L34), `GUEST_APP` (L35), `GUEST_FIXTURE=…/ArchiveReader/AR-GUI-Fixture` (L36), the
  fixture builder `ArchiveReader/scripts/make-gui-fixture.sh` + its `AR_FIXTURE_SRC` env (L95–96), `pkill -x
  ArchiveReader` (L97), the `-ARUITestRootPath` launch arg (L98), and the artifact name `sighted-launch.png`
  (L103) — **plus the same six in `ops/autonomous/gui-vm-gate.sh`** (`GUEST_PROJ`, `-scheme`, `-only-testing:`,
  `GUEST_DD`, the Reader-only fixture-absent WARN, and the `--spec` handed to `xcodegen`).
  - [ ] **W21.vmgui-a — `APP` argument + one per-app config table in both scripts [M].** `vm-gui-runner.sh
    [reader|processor|notes] [xcuitest|sighted|both]` (keep today's arg order + env overrides working). Per-app:
    project/spec/scheme/only-testing, `GUEST_DD=/Users/admin/dd-<app>`, app bundle, `pkill` name, fixture builder
    + fixture path + launch arg, artifact prefix. **Also fix the LATENT fixture bug this exposes (verified
    2026-07-28):** L95–96 passes `AR_FIXTURE_SRC='$GUEST_REPO/../fixture-src'` → `/Volumes/My Shared Files/
    fixture-src`, but only `repo` + `out` are mounted (`--dir=repo:… --dir=out:…`, L55), so that path does not
    exist and the in-VM fixture build can never succeed — and `>/dev/null 2>&1 || true` swallows it. It is
    currently MASKED by the `[ -d "$GUEST_FIXTURE" ] ||` guard plus a fixture baked into the VM image, so it will
    bite silently the first time the image is rebuilt. Make a failed fixture build LOUD (warn + name it), never silent.
  - [ ] **W21.vmgui-b — corpus-free fixtures so the VM never needs the real corpora [S].** Both builders require
    gitignored test corpora that **do not exist in a worktree and are not on the mount**: Reader's
    `make-gui-fixture.sh` hard-exits when `<10` PDFs are found under `Test files/Brown Gemini`, Notes'
    `make-notes-fixture.sh` only warns and leaves `reader-corpus/` empty. Add a synthetic source mode to both
    (Reader already writes a raw minimal PDF inline for its no-text-layer fixture — extend that to N text-bearing
    pages) so the lane is corpus-independent. If a real sample is ever wanted, mount it as a **read-only** third
    share — **never** mount anything under `~/Desktop/Google Drive`.
  - [ ] **W21.vmgui-c — Notes lane green in the VM, then drain the Notes GUI backlog [M].** ⚠️ **Wiring is
    DONE (2026-07-30, W21.screen): the Notes suite now runs in the gate — and it is NOT green: 4/12 fail**
    (`ArchiveNotes/KNOWN_ISSUES.md` has the table + leads). G3 and G8 fail "… is not hittable" on tiny controls
    that are **both at x ≈ 1033** — likely one window-geometry problem under the VM's 1920×1200 display, not two
    bugs; G6/G11 report "the reveal/zotero seam must be drivable" (the hidden a11y probes aren't queryable —
    smells like editor focus / first-responder, not logic). Deterministic across both attempts. **It was first
    logged as 5/12 and "flaky"; that was the gate's own stale-fixture bug** (build-if-absent vs a suite that
    mutates its fixture) — fixed, G5 passes, don't re-derive the old number. Held in the gate's **warn tier**
    (`AUTONOMOUS_GUI_VM_WARN_APPS=notes`) so it reports every gate without parking the run — **remove `notes`
    from that list as the definition of done**.
    The remaining original scope below (guest fixture, container reset) is already implemented in the gate.
    `ArchiveNotesUITests`
    already exists (`macOS/project.yml`: `bundle.ui-testing`, `TEST_TARGET_NAME: ArchiveNotes`, ad-hoc sign +
    `ENABLE_HARDENED_RUNTIME: NO`) and is in the scheme's test action; Debug already uses
    `ArchiveNotes.uitest.entitlements` and the fixture builder + `-ANUITestStorePath` override are shipped — so
    this is wiring, not construction. Build the fixture **in the guest**, assert prereqs there
    (`/opt/homebrew/bin/tag`; absent → tag projection is skipped with a warning), and **reset the app container**
    (`~/Library/Containers/com.archivenotes.app`) before each run: `organization.json` is loaded only when the
    container's index DB has no folders, so a stale container shadows the fixture graph and makes G7/G8
    nondeterministic (the INDEX-DB CAVEAT in `make-notes-fixture.sh`). **Store safety:** hit only
    `…/ArchiveNotes/AN-GUI-Fixture` with the DEBUG scratch-write guard armed — **never** the real store
    (`GUI_SAFETY.md`). Then discharge **W14.4** (b) window raise/focus, (c) cross-window chip recolour,
    (d) two-window column visibility, and **W14.3** live copy→paste image bytes.
  - [ ] **W21.vmgui-d — Processor lane from zero, then drain the Processor GUI backlog [L]** (blocked-on:
    W21.vmgui-c). Processor has **no test target of any kind**, **no `schemes:` block** (it relies on Xcode
    autocreation), **zero `accessibilityIdentifier`s** in `Sources/` (vs 4 files Reader / 11 Notes) and **no
    UITest launch-arg override** — all four must be created: (1) an `ArchiveProcessorUITests` target
    (`bundle.ui-testing`, `TEST_TARGET_NAME: ArchiveProcessor`, `CODE_SIGN_IDENTITY: "-"`,
    `CODE_SIGNING_REQUIRED: NO`, **`ENABLE_HARDENED_RUNTIME: NO`** — the W7.1 finding: an ad-hoc-signed runner
    can't load the xctest plugin under hardened runtime, and `settings.base` sets it YES); (2) an explicit
    `schemes:` block mirroring Notes with the UITest target `[test]`-only, so `-scheme ArchiveProcessor … build`
    keeps working for `launch.sh`, `test-smoke.sh` and `scripts/e2e-phone-mac.sh`; (3) `accessibilityIdentifier`s
    on exactly the surfaces under check (Settings provider rows + "Set up (guided)…", `ProviderKeyWizard`, the
    drop zone + Tagging panel in `OCRView`); (4) a scratch launch config (guest `mktemp` IN/OUT) — Processor is
    **not sandboxed**, so no temporary-exception entitlement is needed.
    **Keychain posture — why the VM is the right place, and how to keep it that way.** The host prompt comes from
    `ContentView.maybePresentKeyOnboarding` (5 eager `KeychainHelper.load`s on first launch) plus
    `SettingsView.loadKeys()` (5 more on appear): the host keychain *has* those items, and an ad-hoc rebuild
    changes the code identity so their ACL no longer matches → macOS prompts. **The VM is a different machine
    whose login keychain holds no ArchiveProcessor items at all, so `SecItemCopyMatching` returns
    `errSecItemNotFound`, which does not prompt (there is no ACL to fail).** The lane's job is to preserve that:
    **never seed API keys into the guest keychain, never run `ensure-signing.sh` in the guest** (ad-hoc is correct
    there), never point the guest at the host keychain. Belt-and-braces: set `ARCHIVEPROC_HEADLESS=1` in the
    UITest `launchEnvironment` so `KeychainHelper.load/save` early-return and **zero** Keychain calls happen.
    *Caveat that shapes the check:* that same flag suppresses the wizard's auto-present, so the key-wizard visual
    must be reached explicitly via Settings → "Set up (guided)…" (or a dedicated `-APUITestShowKeyWizard` arg),
    not the no-key first-launch path. **Gate safety:** a Processor launch yielding no window within N s must SKIP
    (fail-open) **and** save a VNC capture, so an unexpected keychain/unlock panel is diagnosable instead of an
    invisible 20-minute hang. **Then discharge ALL THREE $0 Processor visuals** (owner-confirmed 2026-07-29 —
    the third was under-scoped when this item was written and is the same class as the other two, so it drains
    here too, not by hand):
    1. **Anthropic key-wizard** — Settings ▸ "Set up (guided)…" lists **Anthropic first**: console sign-in
       button, `sk-ant-` field, no-free-tier cost/privacy notes.
    2. **Multi-page-PDF auto re-OCR** — the "Re-OCR multi-page PDF" toggle is GONE; drop zone reads "Drop images
       or PDFs here"; after dropping a multi-page PDF the **Tagging** panel greys out with the re-OCR note.
    3. **Local CLI Agent wizard + cost panes** (W13.cli-2/cli-3) — Settings ▸ Provider & Model ▸ "Local CLI
       Agent" ▸ "Set up (guided)…": Claude/Gemini segmented steps render and Install/Docs links resolve; with
       Local Agent active BOTH the SettingsView pinned pane and the OCRView Files-tab card read "Included in
       your subscription — usage limits apply" (+ pacing note) instead of a dollar figure; the 3-way backend
       picker shows Local-Agent controls only in that mode and switching clears the other backend. This needs
       **no key and no CLI login** — it is pure rendering, so `ARCHIVEPROC_HEADLESS=1` is fine and the
       `cliNotLoggedIn` state is an acceptable (indeed expected) thing to see in the guest.
    Every discharged check must cite the VNC PNG / xcuitest log it was verified from, and flip its line in the
    plan's "Outstanding owner checks" block in the SAME commit.
    ⚠️ The **live-key** halves stay keyed/owner and do NOT drain here: the multi-page-PDF *live run*, the OpenAI
    rotation *smoke*, Local Agent *live OCR*, `test-localagent.sh`, and the W14.5 legacy-manifest E2E all spend
    against the owner's real accounts or need a signed-in host CLI.
  - [ ] **W21.vmgui-e — drain the Reader `W14.2-fu` §6-guard smoke on the EXISTING Reader lane [S].** This one
    needs none of `-a`..`-d`: `vm-gui-runner.sh reader` already runs 15/15 in the VM today, so the check can be
    discharged now. Point the in-VM Reader at the scratch `AR-GUI-Fixture` (the `-ARUITestRootPath` override the
    lane already passes) and edit/rename/mark a tag to confirm normal **matched-identity** writes still succeed
    after the §6 write-target identity guard was armed at all six `NavigationModel` call sites. ⚠️ **NEVER**
    File ▸ Choose Archive Folder, and never the owner's real root (memory `never-mutate-live-app-root`). The
    guard is invisible and already unit-proven, so this is confidence-only — but it is free, so it should not
    sit on the owner's manual list. | files: ops/gui/vm-gui-runner.sh (invocation only) | S | low | none

  **Acceptance criteria (all must hold):**
  1. `vm-gui-runner.sh reader xcuitest` is still **15/15** (regression baseline), `notes` matches its host
     baseline (G0–G11 + Smoke, 13/13 recorded 2026-07-15) **with no `XCTSkip`**, and `processor` runs its new
     UITests green plus produces a sighted VNC capture.
  2. Every app-specific string (project · spec · scheme · only-testing · DerivedData · app bundle · pkill name ·
     fixture path · launch arg · artifact prefix) comes from **one** per-app table per script — no `ArchiveReader`
     literal survives outside that table in either `vm-gui-runner.sh` or `gui-vm-gate.sh`.
  3. The health-gate step stays **fail-open**: missing VM / boot failure / timeout / missing target → SKIP
     (exit 0); RED only on a reproducible `** TEST FAILED **` after retry-once. Proven by a new
     `ops/autonomous/tests/prove-gui-vm.sh` (fake `tart` on PATH, full matrix), in the style of
     `prove-housekeeping.sh` — the existing gate has no prove harness.
  4. The gate runs **one app per invocation, round-robin via a state file** (the `next-review-unit.sh` cadence
     pattern). 3 apps × `AUTONOMOUS_GUI_VM_MAXRUN` (1200 s) = 60 min > the daemon's whole-gate `GATE_MAXRUN`
     (3000 s / 50 min), so an all-three run would false-park on timeout — round-robin (or a raised cap) is
     required, not optional.
  5. No corpus dependency: with `Test files/` and `ArchiveProcessor/Test Files/` absent (the normal worktree
     case) both fixtures still build inside the VM; nothing under `~/Desktop/Google Drive` is mounted or read.
  6. File safety: Notes touches only `AN-GUI-Fixture` (scratch guard armed), Reader only `AR-GUI-Fixture`,
     Processor only a guest `mktemp` IN/OUT; no API key is ever written to the guest keychain.
  7. Artifacts land per app under `~/.tart-mirror/vm-artifacts/<app>/` (xcuitest log · `.xcresult` · sighted
     PNGs), and every drained backlog item cites the PNG/log it was verified from.
  8. Guest housekeeping: three DerivedData trees (`/Users/admin/dd-{reader,processor,notes}`) are pruned/reused
     so the guest disk (≈33 GB free on the 120 GB image) can't fill; a full guest disk SKIPs, never REDs.
  9. Docs move in the same commits: `ops/gui/README.md` §3 (three apps, per-app fixtures, the round-robin rule),
     root `CLAUDE.md` loop step 2, `AGENTS.md` → *GUI verification*, and the per-app `CLAUDE.md`
     visual-verification sections; each drained item's checkbox flipped in the **same commit** as its verification.

  **Verification gate.** Two halves: (i) `gui-vm-gate.sh` + the round-robin state file are **daemon infra →
  Tier-2** — adversarial review + prove-the-mechanism (`prove-gui-vm.sh`) **before** it goes live, per the
  autonomous-setup change discipline; (ii) `ArchiveProcessor/macOS/project.yml` + the a11y-ID edits are **Tier-1
  but cross-cutting** — `project.yml` is a documented SHARED HOTSPOT, so build all three app schemes clean with
  **no new warnings**, keep `swift test` in `packages/ArchiveCore` green, and re-confirm `-scheme ArchiveProcessor
  … build` still resolves for `launch.sh` / `test-smoke.sh` / `e2e-phone-mac.sh` now the scheme is explicit.
  | files: ops/gui/vm-gui-runner.sh, ops/autonomous/gui-vm-gate.sh, ops/autonomous/tests/prove-gui-vm.sh (new), ops/gui/README.md, ArchiveReader/scripts/make-gui-fixture.sh, ArchiveNotes/scripts/make-notes-fixture.sh, ArchiveProcessor/macOS/project.yml, ArchiveProcessor/macOS/Tests/ArchiveProcessorUITests/ (new) | L | med | none

- [ ] **W21.hash — make `ArchiveNotes.BlockKind` conform to `Hashable` [XS].** On every Notes launch the console
  logs *"Obj-C `-hash` invoked on a Swift value of type `ArchiveNotes.BlockKind` that is Equatable but not
  Hashable; this can lead to severe performance problems."* Diagnosed 2026-07-28: `BlockKind` is declared
  `Sendable, Equatable` (`Editor/MarkdownAttributes.swift:19`) but is stored as an **`NSAttributedString`
  attribute value** under the custom key `.noteBlockKind` (`"an.blockKind"`, same file L6–7), so AppKit bridges it
  to Obj-C and calls `-hash` on it — a boxed/slow hash on every markdown parse (chip styling). Fix: add `Hashable`
  to the conformance list; all payloads are synthesizable (`Int`, `String?`, `(ordered: Bool, depth: Int,
  ordinal: Int)`), so no manual `hash(into:)` is needed. Pre-existing, **not** caused by W14.4. Tier-1 (no data
  path): build clean + `ArchiveNotesTests` green + confirm the warning is gone from a launch log.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/MarkdownAttributes.swift | XS | low | none

- [ ] **W21.verify — verify the three release `// VERIFY` desk checks against live vendor docs [S].** These sat
  on the owner's manual list but are **not GUI checks** — no app launch, no VM, no key. They are "does this
  hard-coded fact still match the vendor's live model list / console flow", which a session can do with web
  access. Confirm each, then either flip the `// VERIFY` comment to a dated confirmation or file a correction:
  1. **OpenAI rotation model + price** — `cheapOpenAIModel = "gpt-5.4-mini"` (`OCR/LLMRotationDetector.swift`)
     and the rotation cost pair `(0.75, 4.50)` (`Models/CostEstimator.swift`) still match OpenAI's live model
     list and pricing. ⚠️ If pricing moved, the cost ESTIMATE misleads the owner before a paid run — treat a
     mismatch as a real bug, not a doc nit.
  2. **Anthropic wizard deep links + wording** (`Models/ProviderKeySpec.swift`) — `console.anthropic.com/settings/keys`,
     `…/settings/billing`, `privacy.anthropic.com` still resolve and still describe the 2026 Console flow.
  3. **Local-Agent install links + step wording** (`Models/LocalAgentSpec.swift`). Note the `gemini`/`codex`
     flags, JSON envelope and entitlement wording stay deliberately unvalidated placeholders until those CLIs
     are installed — do NOT invent confirmations for them; say they remain unverified.
  Docs-only unless a fact is wrong; then it becomes a small code fix in the same commit. No corpus, no keys,
  no GUI. | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/{OCR/LLMRotationDetector,Models/CostEstimator,Models/ProviderKeySpec,Models/LocalAgentSpec}.swift | S | low | none

- [ ] **W22.localagent-provenance — the Local Agent backend is invisible in every durable record [S–M].**
  Found 2026-07-29 while verifying the owner's Local-Agent run: a run performed by the local `claude` CLI is
  recorded everywhere as if the selected API provider did it. Three sites, one cause — the Local Agent was
  added as a third backend but only the *gateway* was ever threaded into the provenance/reporting layer:
  1. **The output PDF's text page — the serious one.** `OCR/PDFGenerator.swift:9/207` take only
     `gatewayDisplayName`; with none set, line 220 falls back to `model.provider.rawValue`, so a CLI-produced
     transcription is permanently stamped `Gemini · Gemini 2.5 Flash Lite`. In a provenance-first suite that
     text page IS the durable record of how the text came to exist, and it is **wrong** — verified on the
     owner's real output (`RGB — upright.pdf`, produced with `useLocalAgent = 1`). Fix: add a
     `localAgentDisplayName` (e.g. "Local CLI Agent (claude)") alongside `gatewayDisplayName` and thread it
     from the 4 `PDFGenerator.generate` call sites (`OCRProcessor+OCR.swift:325`, `:1092`,
     `OCRProcessor+Pipeline.swift:1071`, `OCRProcessor+ReviewFlows.swift:378`, `OCRProcessor+Tagging.swift:457`).
     ⚠️ **Wording is a de-facto output-format change** — check `SPEC/tag-format.md` before choosing the string,
     and note `PDFTextExtractor` parses this page (it must keep round-tripping).
  2. **Run history `providerLabel`** = `gatewayConfig?.displayName ?? provider.rawValue`
     (`Models/ProcessingHistory.swift:78`) → also says "Gemini".
  3. **Run history `cost` records a phantom charge.** `estimatedCost` (`ProcessingHistory.swift:61-73`) calls
     `CostEstimator.estimate(… useGateway: gatewayConfig != nil …)` with **no localAgent parameter**, so a
     subscription run that spent **$0** is logged with a real dollar figure. The owner's six runs today all
     show non-zero Gemini cost. Fix: pass the backend through and record 0 (or nil/"subscription") for Local
     Agent — the cost pane already knows to say "Included in your subscription".
  **Side effect worth having:** until this is fixed there is *no way* to confirm from artifacts which backend
  produced a given output, which is exactly why the owner's Local-Agent verification could not be closed
  conclusively. | files: OCR/PDFGenerator.swift, Models/ProcessingHistory.swift, Models/CostEstimator.swift, OCR/OCRProcessor+{OCR,Pipeline,ReviewFlows,Tagging}.swift | S–M | med | none

- [ ] **W22.mixed-batch — per-file dispatch so a mixed drop stops discarding non-PDF files [M · owner
  decision needed].** Partly fixed 2026-07-29: the *silence* is closed (see `ArchiveProcessor/KNOWN_ISSUES.md`
  top entry) but the **routing still skips every non-PDF file in any run containing a multi-page PDF**.
  - **The fix:** partition at `OCRProcessor+Pipeline.swift:1607` — `reOCRSet = files.filter(isMultiPagePDF)`,
    `imageSet = rest` — and run the re-OCR transform over `reOCRSet` then the standard path over `imageSet`
    in one run, instead of handing the unfiltered array to `performMultiPagePDFReOCR` (line 1634).
  - ⚠️ **Index hazard (the reason this isn't a one-liner):** `performMultiPagePDFReOCR` writes `jobs[index]`
    using `files.enumerated()`, which is only correct because `jobs = files.map { OCRJob(sourceURL: $0) }`
    (`Pipeline.swift:1597`) makes them positionally identical. Passing a **filtered subset** silently aliases
    the wrong job — it would mark an innocent file failed. Change the signature to take
    `[(jobIndex: Int, url: URL)]` (or resolve via `jobs.firstIndex(where:)`), and compute `progress` over the
    whole run, not the subset.
  - ✅ **OWNER DECIDED 2026-07-29 — option (a): re-enable the tagging picker, relabelled "applies to images
    only".** Tagging is currently disabled whenever a multi-page PDF is present (`Views/OCRView.swift:30`,
    `:375` `.disabled(isMultiPagePDFReOCR)`) because the re-OCR route is a pure transform that never tags. In a
    partitioned run the picker must be **live again**, with its label/help making clear it applies to the
    **image subset only** — multi-page PDFs in the same run are still never tagged. Do NOT force `.none` for the
    image subset (that was option (b), rejected). The re-OCR'd PDFs must stay untagged even with tagging ON for
    the run, so the functional check should assert exactly that asymmetry in ONE run: image outputs carry
    `com.apple.metadata:_kMDItemUserTags`, re-OCR'd PDF outputs do not. (That xattr asymmetry is what proved
    which route the owner's 13:25 run took, so it is a known-good discriminator.)
  - **Tests to update:** invert `Capture/MultiPageReOCRTestDriver.swift:107-108` (it currently *pins* the
    whole-run routing) and keep §4's reason checks; widen `Capture/ProcessFilesTestDriver.swift:102`, whose
    `imageExts` filter excludes `.pdf` so the driver **cannot form a mixed drop today**; add a functional case
    (mixed drop → the image writes its 2-page PDF **and** the PDF writes its 2N-page rebuild).
  - **Tier-2** (file-writing output path, no undo): adversarial review + functional test on scratch dirs.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/{OCRProcessor+Pipeline,OCRProcessor+OCR}.swift, Views/OCRView.swift, Capture/{MultiPageReOCRTestDriver,ProcessFilesTestDriver}.swift | M | med | **owner**

- [ ] **W21.smoke — fix stale de-nesting paths in `ArchiveProcessor/scripts/test-smoke.sh` [S].** Verified
  2026-07-28: line 23 sets `APPDIR="ArchiveProcessor"`, so `APP` resolves to
  `ArchiveProcessor/ArchiveProcessor/build/DD/…/ArchiveProcessor.app` — a path that **does not exist** (the
  de-nesting `7706368` moved the Xcode project to `macOS/`). Fix: `APPDIR="macOS"` (→
  `macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app`). ⚠️ **Correction to the original 2026-07-17 note,
  which was WRONG on its second claim:** the "`Test Files/` doesn't exist" part is false — `cd "$(dirname
  "$0")/.."` makes `REPO=ArchiveProcessor/`, and both `Test Files/Ground Truth Segmentation/Herrnstein` and the
  `Test Files/Herrnstein` fallback exist, so section [3] needs no change. Don't "fix" that half. The owner has to
  run the script once interactively because section [2] `open`s the app (login-Keychain modal → see W21.seed).
  | files: ArchiveProcessor/scripts/test-smoke.sh | S | low | none
- [ ] **W21.warn — 2 pre-existing non-Sendable `DispatchWorkItem` warnings in `Net/CaptureServer.swift` [S · LOW].**
  `TimeoutHandle(DispatchWorkItem { [weak self, weak conn] … })` at `CaptureServer.swift:151` captures a
  non-`Sendable` `DispatchWorkItem` in a `@Sendable` context; surfaces only on a full clean build. ⚠️ The file
  imports **only `Foundation` + `Network`** (verified 2026-07-28), and Foundation re-exports Dispatch, so the
  originally-suggested `@preconcurrency import Dispatch` may be a no-op — **reproduce the warnings on a fresh
  clean build FIRST** and only then choose the fix. `Net/` is a Tier-2 no-undo path, so treat any behavioural
  change as Tier-2 even though this is nominally a warning cleanup. | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/CaptureServer.swift | S | low | none
- [ ] **W21.seed — OWNER, one-time ~2 min: seed the Processor login-Keychain "Always Allow" [XS].** ⛔ **This
  gates every Processor GUI check.** Launch `./launch.sh processor` **interactively** once and click **Always
  Allow** on the login-Keychain prompt so the stable "Archive Suite Dev" cert requirement sticks across rebuilds
  (memory `processor-keychain-stable-signing`). Until then the Processor cannot be GUI-verified on the HOST at
  all. Note this is *host-only*: `W21.vmgui-d` deliberately avoids it entirely (the VM's keychain holds no
  ArchiveProcessor items, so nothing prompts there). | files: — | XS | low | **owner**

## Pulled forward from POTENTIAL_FEATURES (owner, 2026-07-18)
Wishlist items the owner promoted to near-term after the 2026-07-18 wishlist review. **Note:** the owner also
asked to queue the **Android `targetSdk` 34→36** bump, but grounding against the real `build.gradle.kts` found
it **already shipped (`8eb4ef4`)** — the wishlist claim was stale (now corrected in
`ArchiveProcessor/POTENTIAL_FEATURES.md`). So only the one item below was queued.
- [ ] **W18.reader-breadcrumb — Reader Box/Folder provenance breadcrumb column [S–M].** Surface each document's
  Box/Folder provenance (the `Classification` value — `Box`/`Folder`/`Document Start`/`Continuation`) as an
  optional nav-table column. It is the one unshipped residual of the shipped "Select Document Run" feature
  (Reader `POTENTIAL_FEATURES.md` High §). **Display-only, no writes → Tier-1** (not a tag-write path). Reuse the
  existing customizable-column machinery (`Views/AppKitTableView.swift` + `ColumnPickerHeaderView`); the
  `Classification` already lives in the content index (`Search/ContentIndex.swift`, the same value that drives
  `DocumentRuns`), so the work is joining it into the nav row model + adding a hide-by-default column (mirror the
  Notes Sources-column pattern). Daemon-buildable ($0/no key); build + the 186 Reader unit tests + a `RenderProbe`
  assertion for the new column. **Live GUI confirm → owner tail** (the fixture XCUITest / sighted loop).
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Views/, Core/ArchiveFile.swift, Search/ContentIndex.swift | S–M | low | none

## Archive Notes — DEVONthink import (owner, 2026-07-17)
- [ ] **Import the personal DEVONthink database into Archive Notes** — plan
  `execution-plans/devonthink-import.md` (PLANNING). Losslessly migrate the owner's ~7.5 GB DEVONthink 3
  "Meritocracy Project" DB (`~/Desktop/Scholarship/1000 Research Database.dtBase2`; ~40k notes+excerpts) into
  Archive Notes: 3-stage offline pipeline (JXA extract →
  frozen JSON manifest → pure transform → materialize a **fresh** store) + a stop-on-flag reconciliation
  gate. Delivers net-new Notes features (multi-date primary+additional with per-date timeline rows;
  Related-notes section) and a deletable import toolchain. **Owner prerequisites (§8):** a Reader root over
  `~/Desktop/Google Drive/Archival Photos/`, a copy of the `.dtBase2`, a fresh output store; resolve §9 open
  decisions. Next step = **DTI-0 spike & ground-truth** on a DB copy. | HIGH risk · Tier-2 · **needs:** owner
  + corpus-safety
- [ ] **Reader/Notes: PDF + JPEG dual image reference** (owner, 2026-07-17; **design decided + premise corrected
  by a full corpus audit 2026-07-29**). Let a Reader image entity — and thus the durable link surfaced in Notes —
  reference **both** an archival PDF and its JPEG partner (opens the PDF by default; user can switch to the
  higher-detail JPEG when the PDF lost resolution). Supports the DEVONthink import
  (`execution-plans/devonthink-import.md` §4a) but is a standalone Reader feature.

  ⚠️ **The original premise was WRONG and is retained here only as a warning.** It claimed "naming/paths mirror
  1:1 … so the partner is derivable by filename." A read-only audit of all **102,516** PDFs (manifest +
  per-collection rollup: see the 2026-07-29 corpus-audit report) found:
  - **relocated 82,147 (80.1%)** — partner exists but under a *differently named* collection folder;
    **mirrored only 10,765 (10.5%)**; **none 9,529 (9.3%)**; **ambiguous 75 (0.07%)**.
  - So **90.7% of PDFs do have a partner, but pure path derivation finds 1 in 10.** Leaf *stems* mirror; the
    *collection folders* do not (24 exact-name matches, 23 main-only, 17 JPEGS-only), and the divergence recurs
    at sub-collection level (`Cambridge/Young, Michael` ↔ `.../Michael Young Archive`).
  - The JPEGS tree is not purely JPEG (**4 image extensions** jpg/jpeg/JPG/HEIC with case variance, plus 443 pdf,
    8 mp3, 6 rtf), and the MAIN tree already holds ~18k images of its own.
  - **The corpus cannot be normalised by renaming** (owner asked; audit says no): JPEGS `Stanford University
    Archives` is the dominant partner for BOTH PDF `Stanford University Archives` AND `… — Tech` (**41,585 PDFs,
    41% of the corpus**) — a many-to-one that no 1:1 rename can express; same for Harvard. The 7 genuinely safe
    renames would fix only ~10% of the relocated cases. **DECIDED by the owner 2026-07-29: leave the corpus
    alone — no renames, ever, for this feature.** Do not re-propose corpus normalisation as a way to simplify
    this work: it was measured, it does not work, and the index below resolves 100% of partners without touching
    a single irreplaceable file. Full evidence: `~/Desktop/CORPUS-AUDIT-REPORT.md`.

  **Decided design (owner, 2026-07-28/29):**
  1. **Root:** raise Reader's granted root to the common parent so both trees sit under one root GUID.
     *(Owner's choice; note it widens Reader's WRITE surface over sibling folders — keep tag writes scoped.)*
  2. **Detection:** index the JPEGS tree (a second `NSMetadataQuery`). This is **REQUIRED, not an optimisation** —
     80.1% of partners need relocation resolution no path rule can do. Resolve in this order: exact mirrored
     subpath → indexed stem within collection context → **refuse and show no partner when ambiguous** (75 files);
     never guess, since a wrong partner shows the historian a different archive's scan.
  3. **Durable link:** encode the PDF path **and** the resolved JPEG path explicitly — the partner is not
     re-derivable, so a citation must pin what was actually cited. ⚠️ This changes `DurableLink`
     (`packages/ArchiveCore/Sources/ArchiveCore/Links/DurableLink.swift`) — a shared ArchiveCore type + cross-app
     URL contract → **still HOLD-QUEUE / owner-gated**, and it must rebuild all three app test bundles.
     Old links without the JPEG field must keep parsing (additive/optional).
  4. **Switch UI:** View-menu item + keyboard shortcut, **no** toolbar button; the choice is **sticky per
     document** (needs a small persisted per-file preference store).
  Also handle: PDFs with no partner (9.3%) → hide the switch entirely; case-insensitive extension matching.
  **Verify:** headless render guards (`RenderProbe`/`DocumentRenderGuardTests`) that both the PDF page and the
  JPEG partner render non-blank; VM GUI lane (`W21.vmgui`) for the in-viewer switch.
  | Reader + Notes + ArchiveCore (durable-link/image entity) | M–L | med | **owner** (DurableLink/SPEC change)

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
Surfaced during the owner's live GUI pass. Each is scoped + daemon-buildable unless flagged owner-decision/Tier-2. Legend as above.
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

### Owner dispositions — Morning-Review sweep, 2026-07-16
Owner went through the owner-only queue. Recorded here so none of it gets re-surfaced as an open ask:
- **Environment: TCC grants (Accessibility / Screen Recording / Automation) are SET, verified live.** Sessions can
  drive + screenshot the GUI themselves — see `AGENTS.md` → *GUI verification*. The Processor's Keychain
  "Always Allow" is **seeded**, so its GUI launches unattended. **Stop deferring visual checks to the owner as
  "GUI blocked"** — that claim was stale and cost the owner a lot of pointless eyeballing.
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
- [ ] **R13d REVERSED — remove `ArchiveSuite` stamping from Notes; drop the exclusion feature entirely
  (owner decision 2026-07-16: "Forget about excluding other tagged files. Notes should no longer tag things as
  ArchiveSuite").** The marker was only ever written, never consumed (no Reader filtering / Processor stamping /
  back-fill), so the whole feature goes rather than getting finished. Scope:
  - Stop stamping: drop `suiteMarker` from the managed vocabulary (`ArchiveNotes/Core/NotesTagVocabulary.swift:11`
    → `ArchiveSuiteMarker.tagName`) so `NotesTagProjector` neither adds **nor removes** it; the marker-filter in
    `Core/ItemSummaryDisplay.swift:39-43` then becomes dead and can go too.
  - **⚠️ Decide the projector semantics deliberately — this is the Tier-2 trap.** `NotesTagProjector` *manages*
    its token set: if the marker stays "managed" but merely "not desired", the next projection **strips
    `ArchiveSuite` from the owner's existing note files** (a real tag WRITE). Removing it from the managed set
    instead leaves existing stamps in place, inert. Default = **leave existing stamps alone** (no corpus write);
    only strip them if the owner explicitly asks. Whichever is chosen, prove it with a scratch-copy test.
  - Retire the now-unused marker surface: `packages/ArchiveCore/Sources/ArchiveCore/ArchiveSuiteMarker.swift`
    (check `Links/RootMarker.swift` — the root marker is a *separate* durable-link concern and must survive).
  - **SPEC** (`SPEC/tag-format.md:71`, the "Suite marker" row) — the tag/PDF contract is the **highest-risk shared
    surface**: update it in the SAME commit as the code. This also **inverts W9 Phase A's "finish the SPEC
    `ArchiveSuite` marker section"** — that sub-task is now "remove it".
  - Drop the `(later)` behavior/data follow-on's marker half (Reader hides `ArchiveSuite` / corpus back-fill /
    Processor stamping) — see that item below.
  **Tier-2** (tag-write path + the shared SPEC): adversarial review + a scratch-copy functional test; NEVER the
  real corpus. | files: ArchiveNotes Core/{NotesTagVocabulary,NotesTagProjector,ItemSummaryDisplay}.swift,
  packages/ArchiveCore/ArchiveSuiteMarker.swift, SPEC/tag-format.md | M | med | none

## Archive Notes — NEW APP (SHIPPED W0–W8, 2026-07; `execution-plans/archive-notes/00-overview.md` retained)
Owner-specced third Suite app; foundational decisions locked (D1–D10, `00-overview.md §2`). **All waves shipped;
the per-wave plans (`00a`, `01`–`08`) were deleted on ship** (git history + the W0–W8 `[x]` records below are the
account); only `00-overview.md` is retained as the authoritative interface contract. DevonThink informs **only**
the 3-pane browsing shell — everything else (note appearance, link/provenance UI, replication semantics) is
purpose-built for the historian's provenance-first workflow. **Owner decision points (early):** (a) **R13d** —
the `ArchiveSuite` *exclusion* effect is deferred to the later behavior/data follow-on (see `00 §2` call-out).
**Confirmed (owner):** the FULL **ArchiveCore extraction + Reader/Processor migration is W0 — done FIRST** (`00a`),
before any Notes-specific work.
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
- [ ] **W9 (gap-closure)** post-ship reconciliation from the 2026-07-16 plan-vs-build review (all W0–W8 verified
  substantially complete + data-safe; these are the promised-but-absent / partial / built-but-not-wired deltas)
  — `09-gap-closure.md` — mixed Tier-1/Tier-2 per item; ends with a **verification review (Phase E)** that gates
  deleting the plan:
  - **Phase A — docs/tracker (DOC):** write `ArchiveNotes/README.md` + `AGENTS.md`; add Notes to root `README.md`;
    finish the SPEC `ArchiveSuite` marker section (**Tier-2**); delete shipped plans `00a`/`03`/`07`/`08`; fix stale
    `SUITE_TODO`/`CLAUDE.md`-map entries; add `SMOKE_TEST.md`; drop `@testable` in `DocumentTagsTests`.
  - **Phase B — wire built-but-dead features (HIGH→MED):** Zotero auto-fill action + note-level chips (dead code,
    no UI); note retitle/tag-edit path; page-thumbnail render end-to-end (Reader passes `thumbnailer:nil`); consume
    `archivenotes://open`; embed image bytes on the extract menu path; guided root re-grant. Mostly **Tier-2**.
    **Verify the render items** (page-thumbnail end-to-end) with a headless render guard — the `RenderProbe`/
    `DocumentRenderGuardTests` pattern over Notes' in-app `PDFThumbnailer` — so a blank thumbnail can't pass.
  - **Phase C — safety-net tooling (MED):** add `archivecore` smoke step; Processor write-surface lint; extend the
    lint to ArchiveCore (uncaught `import AppKit` in Core) + run on Notes; scope Notes smoke to `-only-testing`;
    (opt) fix the documented tag-projector concurrent lost-update race. **Tier-2**.
  - **Phase D — secondary UI/polish (LOW–MED):** folder drag-reparent, richer row context menu, template-body
    editing, quality quick-edit, `roundup` UI-or-remove, raw-parse-failure banner, empty states, off-main
    large-paste parse + minor coverage/cosmetic. Tier-1.
  - **Phase E — verification review:** re-run the plan-vs-build gap analysis + drive the features at runtime to
    prove every A–D item is actually done + **wired** (not "built but dead" again) before flipping this checkbox.
    Use headless render guards (`RenderProbe`/`DocumentRenderGuardTests`) for pixel truth (thumbnail / PDF pane
    actually drew) and the live sighted loop (`ops/gui/`) for chip / empty-state / raw-parse-banner rendering.
- [ ] **(later)** behavior/data follow-ons (W0 already unified the *code*): **unified suite storage path** — Tier-2, separately gated.
  - ~~Reader parses/**hides** `ArchiveSuite` in-UI; corpus **back-fill** + Processor **stamping**~~ — **DROPPED
    (owner 2026-07-16).** The whole `ArchiveSuite` marker/exclusion feature is reversed: Notes stops stamping it
    (see the "R13d REVERSED" item above) and nothing will consume it, so there is nothing to hide, back-fill, or
    stamp. This also removes the only reason for a corpus-wide tag back-fill — the Suite's single
    highest-risk operation. Do not re-propose it.

## ✅ Document-viewer bugs (owner-reported 2026-07-06) — RESOLVED & owner-verified
All fixed and confirmed by the owner (round-3 commit `d4eedba`): open-maximized + remember-size with no
flash; text selection after cycling (fresh `PDFView` per page); zoom persistence across cycling *and* as
default incl. trackpad-pinch (`PDFViewScaleChanged` capture); top-anchored zoom; splitter persistence.
Files: `DocumentWindowView`/`DocumentViewerModel`/`PDFPaneView`/`AppSettings`/`ArchiveReaderApp`.

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

**→ Reader P2 is COMPLETE** (non-standard-PDF cluster · tag near-duplicate finder · document-viewer bugs · dup-filename; side-by-side dropped).

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
Captured verbatim from the owner; file hints are from the Reader/Processor Implementation Maps (verify
at implementation). Not yet scoped into execution plans — the **decades** item likely warrants one
(cross-app + SPEC). Legend as above (S/M/L · risk · needs).

### Archive Processor
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
- [ ] **De-dup sweep from the 2026-07-04 maintainability audit — REMAINDER ONLY** _(promoted 2026-07-15;
  re-scoped 2026-07-16 after finding suite-v1.2.0 already did most of it)_. **`f1d2263` (suite-v1.2.0) ALREADY
  SHIPPED 5 of the listed consolidations — do NOT redo:** `highestLeadingNumber` (→ `Capture/CollectionNumbering.swift`),
  `monthTag`/`englishMonthNames` (→ `GeneratedTags`), `acceptedImageExtensions` (→ `ImageEncoding`),
  `GatewayConfig.fromDefaults()`, `liveProcessingMode` **enum**. **GENUINE REMAINDER (~6, verified still duplicated
  in-tree 2026-07-16):** a shared transient-status friendly-message helper (4 OCR clients); a segment-JSON schema
  builder (2 sites); `OCRResult.with(...)` copy helpers; `LLMRotationDetector.rotate` → `ImageEncoding.rotate`
  (`LLMRotationDetector.swift:150` still a private copy — its own comment says "mirrors ImageEncoding.rotate");
  `ThinkingLevel.budgetTokens` + the Anthropic max_tokens bump (4 clients — `thinkingBudget` is 1024/4000,
  512/2000, and two `budget` vars, i.e. budgets differ **by call type**, so KEEP that difference — this one is
  request-body-affecting if mis-merged); Gemini `cancelBatch` via the shared URL builder.
  ⚠️ **VERIFICATION CONSTRAINT:** the Processor has **no unit-test target** and its only functional test needs an
  OCR API key (deleted W4.0.a) — so "prove equivalence" here = build-green + byte-identical diff inspection; the
  `budgetTokens` sub-item (request-body-affecting) should be done in a keyed/owner session, not guessed unattended.
  **Tier-1** (touches no write path). | files: OCR/*, Capture/LiveCaptureProcessor.swift, Views/* | M | low | none
  — **W12-dedup progress 2026-07-16 — 5 of 6 shipped** (byte-identical, build-clean, no new warnings):
  (1) `LLMRotationDetector.rotate` → shared `ImageEncoding.rotate` `af8cf66`; (2) shared
  `OCRErrorMessages.transientStatusMessage(_:)` across all 4 clients' `parseErrorResponse` + (3) Gemini
  `cancelBatch` via `makeBatchURL` `6c52dd4`; (4) `OCRResult.with(classification:rotationDegrees:)` copy helper —
  7 review/retry re-creations, preserves errorCode (the W9.1 footgun) `94d4ef6`; (5) **segment-JSON sidecar
  builder** — Tier-2 (file-WRITE format): new pure `OCR/SegmentJSONBuilder.swift` (`cf4f509`) that both
  `OCRProcessor.writeSegmentJSON` + `LiveCaptureProcessor.writeSegmentJSON` now delegate to — disk-write surface
  (sidecar-URL + atomic write) left unchanged; the OCRProcessor-only `box_label`/`folder_label` divergence is a
  `formatOverride:` param via `SegmentJSONBuilder.labelFormatOverride`. Proven byte-identical to BOTH originals
  by a $0 key-free 12-case / 30-assert driver (`SEGMENT_JSON_TEST=1` + `scripts/test-segment-json.sh`,
  `6d9a877`; call sites wired in the flip commit) — ALL PASS. **⏸️ 1 REMAINING is OWNER/KEYED — Wave-12 SKIP
  (do NOT attempt unattended):** (6) **`ThinkingLevel.budgetTokens`** — request-body-affecting (512/2000 vs
  1024/4000 differ by call type) → keyed/owner session per the VERIFICATION CONSTRAINT above (Processor has no
  unit target + its only functional test needs the deleted OCR key). See Morning Review.
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

### Capture companions (Android + iOS) — owner decisions 2026-07-15
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

### Archive Reader — layout & panels
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

### Archive Reader — tag cloud & filters
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

### Archive Reader — dates & decades (CROSS-APP + shared SPEC)
- [x] **Decade tags ("1970s", "1980s")** _(plan: `execution-plans/decades-date-facet.md`)_ — SHIPPED.
  SPEC + Reader parse/sort/display/topicalTags + write-path safety (year supersedes decade) +
  Processor Year-field help text. 12 new unit tests (182 total green). Tier-2 APPROVE. Defaults
  applied for the 4 open questions (italic=yes, no Reader decade editor, no hard validator, cloud/filter
  exclusion structural). Plan deleted. | done

### Archive Reader — search
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

### Archive Reader — sort & smart folders
- [x] **Drop the top-bar Sort button; sort via column headers** — removed the toolbar Sort menu; primary
  sort via native column-header click (already wired via `sortDescriptorPrototype`); right-click header →
  secondary sort (asc/desc) + remove-secondary + reset-to-default via `ColumnPickerHeaderView`. Dead
  SwiftUI-Table sort code removed (`ArchiveFileComparator`, `sortComparators`, `applyTableSort`). 191 tests
  green, 0 warnings. | done
- [x] **Smart folders behave like a scoped root** — selecting a saved search enters a base scope; user
  filters layer on top; Clear returns to the base set, not the whole root. Sidebar shows a durable
  highlight. Scope persists across relaunch. `LibraryFilter.effective` merge for Save/summary. 170 tests
  green. Tier-2 APPROVE. | done

### Archive Reader — viewer & preview
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
Correctness bugs from that run's review shipped (`848c9d2`, `f866a0f`, `14118c0`); the items below were
consciously deferred (perf-only / LOW / GUI infra / new idea). All armed in `.maintenance/AUTONOMOUS_PLAN.md`
as **Waves 7–10** for the next daemon run (relaunch the daemon to start it — `ops/autonomous/README.md`).
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
**Done:**
- [x] KNOWN_ISSUES #3: zoomed-image scroll monitor no longer swallows scroll app-wide — scoped to the image via a hit-test-transparent probe (`ZoomableImageView.swift`); SwiftUI drag/pinch intact, no OCR/output logic touched. Build clean. ✅  ← GUI-verify (zoom a page >100%, confirm the filmstrip scrolls).

**Heads-down doable now (macOS, build-verifiable, NOT phone-gated):**
- [x] **[A1 — SHIPPED; owner-gated live-verify remains]** **Owner-requested (2026-07-07): bring the Live Capture Processing pane up to the Process Files "Files" pane's level of detail — on shared central code.** Today the Processing pane in Live Capture is too sparse: when a document **fails OCR the user gets no reason**, and there's **no way to (re)process just one or two files**. It should show the same per-file detail as the Process Files "Files" pane (status, OCR text/error reason, per-file actions) and offer the same **granular fallback/retry options** (retry a single file, change model/rotation and re-run, etc.). The pane likely needs to be **larger** to fit this. **DRY — don't invent it twice:** factor the Process Files file-list + row + per-file action UI into a **shared component** so both the Process Files pane and the Live Capture Processing pane render from one central source, rather than two parallel implementations. Mostly build-verifiable; verify the failure/retry paths in a live run. **Tier-2** if it touches the finalize/retry write path. | files: Views/OCRView.swift (+OCRView+*), Views/LiveCaptureView.swift, Capture/LiveCaptureProcessor.swift, new shared row/pane component | L | med
  - **Progress (2026-07-07, A1 design `.maintenance/A1-shared-pane-design.md` steps 1–9):** SHIPPED — shared `Views/Shared/{ProcessableItem,ProcessableItemRow,ProcessableItemListView,ModelChoiceView}.swift`; Files pane adopts it (`FileItem` adapter, identical render); Live pane fully adopts it (`SegmentItem` adapter, reasons + per-item retry / retry-with-model / rotate-&-re-run / view-text / reveal + grown scrollable box); `LiveCaptureProcessor.retryFailed(groupIds:override:)` generalized (G1 = all-failed footer); failure taxonomy un-conflated (`succeededNoText` for filed image-only docs — labeling only, deletion path untouched); `OCRProcessor.retryOne(...)` extracted. Builds clean, no new warnings. **Files pane inline-disclosure action UI shipped** (overnight, commit `d068a99`): tap-to-expand rows surface retry / retry-with-model / rotate-&-re-run / view-text / reclassify via `OCRProcessor.retryOne(...)` + `ModelChoiceSheet` + `FileTextViewerSheet`; review-mode keyboard/tap gestures preserved (expand only outside review mode). `.fileAsImageOnly` not surfaced (auto-files via `succeededNoText`). **REMAINING:** live-run GUI verification of the new reasons/retry paths (owner-gated).
- [x] **shipped `f1d2263`, suite-v1.2.0** — Behavior-preserving de-dups (audit `wf_4373722d-e70`): shared text-completion client; small cluster (`highestLeadingNumber`, `monthTag`, `acceptedImageExtensions`, `GatewayConfig.fromDefaults`, `liveProcessingMode`); reconcile iOS(5)/Android(6) recent-years cap. **Correction 2026-07-18:** the **finalize/organize move helper** and the **box/folder color-retag** unification were listed here but `f1d2263`'s own commit body **DEFERRED both** (Tier-2, not provably identical — the `trashOrRemove`+`filedGroupIds` vs `fm.removeItem` paths differ, and 3 drifted color-retag copies remain in `OCRProcessor+ReviewFlows.swift`). They are **still open** and live in `ArchiveProcessor/POTENTIAL_FEATURES.md` → *Maintainability / refactor backlog*. | M | low
- [x] **shipped `b1fc5d4`, suite-v1.2.0** — No-API local features: processing profiles/presets + main-window global shortcuts (start / switch provider). | Views/SettingsView.swift, Views/OCRView.swift, new store | M | low
- [x] **shipped `782dfdd`, suite-v1.2.0** — Output-folder picker in the Live Capture pane (+`?` help + gray-out); unify with Process Files `outputDirectory`. **Tier-2** (output path) — add the picker + wire the EXISTING setting; don't change write/move logic. | M | low
- [x] **shipped `d2de49d`, suite-v1.2.0 (owner live-verified pairing).** **Remove the Mac Transport picker — auto-run both receivers.** The phone already chooses its transport at pairing (Wired/Wi-Fi/Cloud), so the Mac-side lan/cloud setting is redundant + a footgun (left on Cloud, Wi-Fi pairing silently dies, and vice-versa — hit live 2026-07-07). Instead: the Mac always runs the LAN `CaptureServer`, and *also* runs the Drive relay watcher automatically whenever it's signed into Google + a session is active (sign-in = the enablement, not a mode). Drop the Transport picker from `SettingsView` (keep the "Sign in to Google Drive" config); emit ONE combined pairing QR (host/port/token + relay token) so any phone-side choice works from a single scan; show dual status (Listening + Watching Drive). Gate the Drive poll to active sessions to save quota. **Tier-2** (Capture/Net/Views) — worktree + adversarial review; verify LAN via the android-ui-test-harness + the cloud path with a paired phone. | Capture/CaptureSession.swift, Views/SettingsView.swift, Views/LiveCaptureView.swift | M | low
- [x] Connectivity UX — **superseded/shipped** by the cloud-transport integration (legible Wi-Fi failure + reachability preflight landed; USB + Drive relay is now the direction). ✅

**Live-session / phone-gated (drive Live Capture — ideally a paired phone — to verify; do interactively, like the viewer bugs):**
- [x] **shipped `338dc1b`, suite-v1.2.0 (B2)** — Keep OCR/progress live while the per-segment tag card is open (looks hung today). | Views/LiveCaptureView.swift | S
- [x] Tag card: when the Spotlight tag index is still building, present UI saying so instead of silently-empty autocomplete. ✅ `SystemTagsProvider.isReady` (false until first gather) → SegmentTagCard shows a spinner + "building tag suggestions…" that clears when the query finishes. | Views/LiveCaptureView.swift (SegmentTagCard), Tagging/SystemTagsProvider.swift
- [x] After rotation review, if finalize/processing is still running, show a throbber so the gap before collection naming doesn't look hung. ✅ LiveCaptureView overlay: "Finishing — processing segments…" shown while `isFinalizing && no sheet` (the regen gap; gated off during the finalize move which has its own spinner). View-only — no Capture/ change needed. | Views/LiveCaptureView.swift
- [x] **shipped `6ea268a`, suite-v1.2.0 (B4)** — Re-pair coordination: auto re-show QR on phone re-pair; split "listening" vs "connected"; verify USBBridge re-runs `adb reverse`. | Net/, Views/LiveCaptureView.swift, companions | M
- [x] **shipped `6ea268a`, suite-v1.2.0 (B5; residual `resolvedGroupIds` resurface tracked as B9 in KNOWN_ISSUES)** — Streaming residuals (mostly shipped in the cloud-transport work — Finish drain-gate + phone queue-depth + "End segment = the only done action" landed): finish/verify any remainder — `needsResend` for P10/reclassify in-flight, `completedDocGroups` persistence across Mac restart. | Capture/LiveCaptureProcessor.swift, companions | M
- [x] **shipped `7aace39` + audit fix, suite-v1.2.0 (see KNOWN_ISSUES ✅ FIXED)** — KNOWN_ISSUES #2: merged multi-page docs leave exported originals loose — thread per-page image URLs into `organizeOutput`. **Tier-2 file-move**; needs a live pipeline run. | OCR/CollectionSegmenter.swift, Capture/LiveCaptureProcessor.swift | M

> **✅ INTEGRATED 2026-07-07.** The standalone clone's `feat/live-capture-cloud-transport` work — a full
> **Drive-relay cloud-transport** system (D1–D8: `DriveClient`/`DriveObjectStore`/`DriveAuth`/
> `DriveRelayTransport` for Mac+iOS+Android, `FileRelay`, phone queue-depth + Finish drain-gate;
> LIVE-validated, already adversarially reviewed) — was ported into the monorepo under `ArchiveProcessor/`
> as **27 commits (history preserved)** via `git am --directory`, merged to `main`, and pushed. Both apps
> build; offline invariant tests pass (RELAY GOLDEN ✅, FileRelay 8/8). The standalone clone was then
> **retired**: its 6.3 GB `Test Files` corpus moved into `ArchiveProcessor/Test Files/` (gitignored), the
> folder deleted, and the stale `com.archivereader.autobuild` launchd relic removed. This **supersedes** the
> "connectivity UX" item above (cloud/USB transport is the new direction). The architecture now lives in
> `ArchiveProcessor/CLAUDE.md` §Function 3; the relay contract in `SPEC/relay-object-format.md`; the
> on-device walkthrough in `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md`.

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

## Excluded (not "now": need cost / owner accounts)
- Processor Tier-1 `test-smoke.sh` / Tier-2 `test-tier2.sh` (real OCR → keys + API cost); Reader cloud-drive support; Reader creation-date-mirror (would write metadata onto the real corpus).
- ~~Processor App-Store / Play submission (Phase 4)~~ — **DROPPED (owner 2026-07-16: "we're not doing this any
  time soon").** Off the list entirely; don't re-surface it as an owner action item.
  - [x] **G5 — cheap Tier-1 smoke gate shipped (2026-07-07).** New Suite-root `./test-smoke.sh processor|reader|all` (mirrors `launch.sh`) → `ArchiveReader/test-smoke.sh` (build + full unit suite, **135 tests, free**) + `ArchiveProcessor/test-smoke.sh` (headless **2-image** OCR via `ProcessFilesTestDriver`, `gemini-2.5-flash-lite`, ~a few cents, `mktemp` scratch-isolated, key never printed). Distinct from the cost-heavy `scripts/test-smoke.sh` (raw per-provider calls) + `scripts/test-tier2.sh` (multi-case pipeline) above. Both verified PASS. ✅

## Processor/Capture — WS11 paced re-review findings (2026-07-18, autonomous)
Lean-review re-pass of `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/` (18 commits since the
2026-07-08 original review). 6 finder-level findings, **4 MED / 2 LOW, no HIGH** → none routed to the owner
HOLD queue. Every fix is **Tier-2** (Capture/ no-undo path): a fix session must adversarially re-confirm +
run a scratch-copy functional test before shipping. ⚠️ The Opus-max **refute-verify was budget-truncated**
(verifiers stopped to protect the session usage window — see memory `workflow-pacing-usage-window`); these are
finder-level candidates (only #1's premise manually confirmed). Report: `.maintenance/review/Processor-Capture.md`.

> **SHIP ORDER (set by the 2026-07-18 Live-Capture architecture review — see Wave 17 below).** Recommended:
> **r6 → r2 → r1 → r5 → r4 → r3.** `r6` is the only genuine recoverability hole in the subsystem (a straggler's
> processed output is discarded), and `r2` costs real money on every phone retry — those two are the highest
> value and between them retire most of the two now-closed deferred architecture entries. **Sequencing
> constraint:** do `r4` **before** `W17.stg1` (both touch `RetainedSegment`), which is enforced by a blocked-on.
- [ ] **W3.cap-r1 [MED · tag/PDF SPEC] — NOW TWO FIXES IN ONE COMMIT (see ⚠️ below)** `LiveCaptureProcessor.swift:640/647/673` — **(a) the SPEC subject-collision:** the live path writes tags via the raw `[String]` `MacOSTagger.applyTags` overload (no `colorIsAuthoritative`), so a document segment whose subject is literally "Red"/"Purple" is promoted to a Finder color label (Red=6/Purple=3) → the Reader mis-parses it as a box/folder photo. KNOWN_ISSUES #5's fix (derive authoritative color from classification) was applied to the batch merge path but **never to the live streaming path**. *(Premise manually confirmed: raw overload at all 3 call sites.)* **(b) tag-write failures are silently swallowed** (found by the 2026-07-18 review; was NOT in any KNOWN_ISSUES entry): all three sites are `_ = try? MacOSTagger.applyTags(...)`, so a PDF can land byte-perfect, count as **filed**, and have its **source photo trashed** while carrying no subject/date/priority tags at all — in the Reader that file is then invisible to tag-driven triage. **This is the only way today's "filed" verdict can be wrong without the operator ever knowing.** Owner decision 2026-07-18: record a per-artifact `tagsApplied` and **warn in the finalize summary**, but the file still counts as filed — the bytes are safe and retagging is possible, so withholding "filed" (and thus retaining the source) over-corrects. ⚠️ **THESE MUST BE ONE COMMIT.** (a) changes *which* overload is called; (b) changes *whether the result is discarded* — both rewrite the same three lines, so landing them separately means the second silently reverts part of the first. | Capture | Tier-2
- [ ] **W3.cap-r2 [MED]** `LiveCaptureProcessor.swift:333` — live-OCR dedup keys `pageTasks`/`startedPhotoIds` on the ephemeral `CapturedPhoto.id`, but `CaptureSession.ingest` mints a fresh `CapturedPhoto` (id) on the idempotent-replace/re-upload path (`CaptureSession.swift:516`); a phone auto-retry after a dropped ack bypasses the `!startedPhotoIds.contains(photo.id)` guard (line 301) → a **duplicate paid OCR call** + the prior Task orphaned. | Capture | Tier-2
- [ ] **W3.cap-r3 [LOW]** `CaptureSession.swift:539/549` — `removePhoto`/`removePhotoIfSafe` delete a photo from `session.photos` but never tell `liveProcessor` to cancel that photo's in-flight OCR Task → deleting/reclassifying a page mid-OCR leaves a paid OCR call running + Task/result orphaned in `pageTasks`. | Capture | Tier-2
- [ ] **W3.cap-r4 [MED · misfile]** `LiveCaptureProcessor.swift:385` — `backfillCollections` corrects `staged[i].collectionKey` for an out-of-order Box but never updates the parallel `retained[groupId].collectionKey`; the rotation-review regeneration path reads `collectionKey` from `retained` and overwrites the staged entry → silently reverts the correction → **misfiles the document into the wrong collection folder**. | Capture | Tier-2
- [ ] **W3.cap-r5 [MED · misfile]** `LiveCaptureProcessor.swift:409` — `finalizeSegment` pins `collectionKey` (line 409) before its OCR/tag awaits, but `backfillCollections` skips groups already in `finalizedGroups` yet not yet in `staged`; an out-of-order relay Box delivered during that await can never re-pin the in-flight document → **misfile**. | Capture | Tier-2
- [ ] **W3.cap-r6 [LOW · data-loss]** `LiveCaptureProcessor.swift:996` — `finalize()`'s allFiled branch trashes the whole `stagingDir` after the `executePlans` move await; a straggler segment that finalizes *during* that await writes fresh output into the same `stagingDir` and is not in `plans` → its processed output is discarded and a dangling `staged` entry points into the Trash. | Capture | Tier-2

## Processor/Net — WS11 paced re-review findings (2026-07-18, autonomous)
Lean **delta** re-review of the **LAN/USB surface** of `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/`
(owner carve-out, REVIEW.md L63–67: review CaptureServer/CaptureReceiver/CaptureValidation/USBBridge/
RelayObjectFormat + FileRelayReceiver's LAN path; **skip the cloud/Drive relay**). The 2026-07-09 findings
(W3.n1–n5) all hold, and the two deltas since — `53d04cc` (bound LAN request memory) + `1f58575` (persist
completion before ack) — are **clean** (serial-queue discipline intact, `close()` double-close-safe,
auth-before-disclosure, acks gated on durable returns). **1 finding, LOW, no HIGH/MED** → nothing routed to
the owner HOLD queue. Report: `.maintenance/review/Processor-Net.md`. ⚠️ The `lean-review` Opus/max fan-out
was budget-stopped before it emitted a single finding (~$4.5/min while still only reading — same failure as
the Capture re-pass); this unit was verified **INLINE** by the main-loop model. See the report.
- [ ] **W3.net-r1 [LOW · defense-in-depth]** `Net/CaptureValidation.swift:9-12` — the shared `isSafeGroupId("")`
  returns true (empty string passes the charset check vacuously; count 0 ≤ 128; no `..`), yet the "one shared
  predicate so the receivers can't drift" is relied on inconsistently: both LAN routes guard `!groupId.isEmpty`
  separately (`CaptureServer.swift:409/446`) while `FileRelayReceiver`'s photo branch (`FileRelayReceiver.swift:141`)
  does not → an empty `"group"` field in a same-token/same-epoch relay sidecar passes `safe` and reaches
  `CaptureSession.ingest(groupId:"")` (stages as `00005-.jpg`). **Not reachable via the phones** (they never emit
  an empty group) and benign if reached (filename suffix, not a path component → no traversal; `(group,seq)`
  keying stays idempotent), so LOW/hardening — but the shared predicate should reject empty to match its own
  docstring. Fix: add `!s.isEmpty` to `isSafeGroupId` (keep both receivers' explicit guards too). | Net | Tier-2
