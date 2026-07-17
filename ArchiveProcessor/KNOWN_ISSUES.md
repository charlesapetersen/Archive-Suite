# Known Issues (deferred)

Tracked bugs we've chosen to come back to later. Each entry has enough context to resume cold.

---

## ✅ FIXED (2026-07-12): dismissing the macOS live tag card silently acted as Skip [HIGH]

**FIXED:** interactive dismissal is disabled and the sheet binding no longer translates a nil write into
`skipMacTags`. A live segment is resolved only by the card's explicit Apply or Skip buttons, so Escape,
click-outside, or other dismissal attempts cannot discard typed metadata. Android already used this explicit
action policy; iOS already disabled interactive dismissal. macOS Debug build passes. (2026-07-12)

---

## ✅ FIXED (2026-07-12): controlled subject vocabulary was prompt-only and accepted invented tags [HIGH]

**FIXED:** parsed model subjects now pass through a pure enforcement boundary. With a configured vocabulary,
only case-insensitive, whitespace-trimmed matches survive; output uses the first configured canonical spelling,
deduplicates matches, rejects inventions, and retains the six-tag cap. Empty vocabulary preserves existing
free-form behavior. A standalone pure regression covers canonicalization, duplicates, inventions, blank
vocabulary entries, and free-form compatibility. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android capture thumbnails decoded on the UI thread [MEDIUM]

**FIXED:** each thumbnail now loads through a key-scoped Compose producer and performs file probing plus
downsampled `BitmapFactory` decoding on `Dispatchers.IO`. Removing/replacing an item cancels its producer;
composition only receives the finished `ImageBitmap`. The macOS collection and document review panes were
already using asynchronous thumbnail loaders. Android debug compilation and JVM tests pass. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android Clear raced uploads and manifest saves, then reused item IDs [CRITICAL]

**FIXED:** Clear now gates new captures/persistence, cancels and joins every tracked upload and segment
signal, deletes source files only after those jobs stop, and clears the manifest through the same ordered
persistence worker so a queued old save cannot resurrect it. Item IDs remain monotonic for the ViewModel lifetime, preventing stale
delayed callbacks from matching a new photo. Camera callbacks carry a session-generation token, so a shutter
started before/during Clear cannot populate the new session afterward. Android JVM tests cover that delayed
callback policy in addition to building the lifecycle changes. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android manifest fallback deleted the last good session before replacement [CRITICAL]

**FIXED:** session saves now write and `fsync` a unique temporary sibling, then publish it with replace
semantics (atomic when supported). The fallback never explicitly deletes `session.json`; if publishing fails,
the previous durable manifest remains intact and only the operation-owned temporary file is cleaned up.
Plain-JVM tests inject replacement failure and verify the good manifest survives byte-for-byte. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android reported zero pending while failed pages were auto-retrying [CRITICAL]

**FIXED:** the phone's status heartbeat now counts every page not yet confirmed `UPLOADED`, including
`FAILED` pages. Those pages are automatically retried every eight seconds, so excluding them could let the
Mac finish a session before the retry arrived. Deferred P10/reclassification resends transition atomically
back to `PENDING`, and one serialized/conflated writer prevents older heartbeat coroutines from arriving
after newer state. Crash restore normalizes a persisted resend marker to `PENDING` before uploaded-page
pruning. Plain-JVM queue-policy tests cover all states, deferred-resend transitions, and the between-saves
restore state, proving the count reaches zero only after required delivery is confirmed. (2026-07-12)

---

## ✅ FIXED (2026-07-12): failed merged-PDF tag transfer still deleted component PDFs [CRITICAL]

**FIXED:** merging now treats a successful, verified tag write as a prerequisite for retiring the
per-page PDFs. If tag reading, writing, coordination, or verification fails, the component PDFs remain,
the source-to-output mappings remain unchanged, and the merged recovery copy is preserved for inspection.
The implicit `Unread` tag is transferred even when generated tags are otherwise empty. Optional JSON is
reserved under the same collision-safe basename and copy-verified before component cleanup. The headless
merge-safety regression injects a tag-write failure and proves the sources remain retryable; its success,
empty-tag, and JSON-only-collision cases prove cleanup occurs only after all required artifacts are durable.
(2026-07-12)

---

## ✅ FIXED (2026-07-12): output generation and organization could overwrite prior files [HIGH]

**FIXED:** normal OCR now reserves against both current-run paths and files already on disk; dual-image
export chooses a distinct destination unless it intentionally reuses the pristine source; collection
organization preflights PDF/JSON/image destinations as a set and advances numbering instead of deleting a
collision. The actual exported-image path is carried through organization, including collision-renamed
images. Standalone destination tests plus the synthetic collection-organization driver cover prior-run PDF,
reserved-path, source-image reuse, JSON-only collision, and artifact alignment. (2026-07-12)

---

## ✅ FIXED (2026-07-12): pre-OCRed review removal deleted the original PDF [CRITICAL]

**FIXED:** pre-OCRed inputs map their source PDF as the output. Both manual and document-segmentation
removal flows previously deleted that mapped URL and its same-basename JSON sidecar. Removal now detaches
source-as-output mappings without deleting them, using a shared conservative file-identity guard with
standalone regression coverage. Cleanup removes only the explicitly tracked output—never an inferred JSON
sidecar—and retains failed cleanup mappings for retry. `OCR/OutputFileSafety.swift`, `OCRProcessor+Tagging.swift`,
`OCRProcessor+ReviewFlows.swift`.

---

## ✅ FIXED (2026-07-08): resolved tag cards re-surfaced after a mid-session Mac restart (B9) [LOW]

**FIXED:** `SessionManifest` now also persists `resolvedGroupIds` + `macTags` (both optional → pre-B9
manifests still decode, to empty); `applyMacTags`/`skipMacTags` write the manifest on resolve, and
crash-recovery restore repopulates both — so a mid-session Mac restart no longer re-surfaces an
already-resolved tag card (nor drops its Mac-entered tags), and a resolve interrupted *before* staging now
recovers with its tags instead of being lost. `clear()`/`clearFiled()` keep the three co-dependent sets
(`completedDocGroups`/`resolvedGroupIds`/`macTags`) in sync. Verified: headless `ManifestPersistenceTestDriver`
round-trip + pre-B9 back-compat (13/13 PASS), Tier-2 adversarial review (APPROVE, 0 findings), build clean,
smoke PASS. `Capture/CaptureSession.swift`, `Capture/CaptureModels.swift`. Original report below.

Found by the B4/B5 review (2026-07-08). `CaptureSession` persisted `completedDocGroups` (B5-ii) but NOT
`resolvedGroupIds`, so after a mid-session Mac restart a group already resolved+finalized re-showed its tag
card (`pendingTagGroup`); re-tagging it no-oped on the already-baked staging output (the new tags never
reached it). **Pre-existing root cause** — the same fires at Finish via `completeAllOpenDocGroups`
post-restart; B5-ii merely triggered it mid-session too. **NO data loss / NO double-file** (guarded by
`finalizedGroups.contains` in `segmentResolved`).

---

## ✅ FIXED (2026-07-09): FileRelayReceiver.persistProcessed() return ignored — source deletion on persist failure [HIGH]

**FIXED:** Both call sites (post-ingest and post-tombstone) now check `persistProcessed()`'s return value.
On failure: revert the in-memory `processed` entries, skip receipt-write and source-deletion, and leave the
source objects for retry on the next scan. `ingest` is idempotent on `(group, seq)`, so re-processing is
safe. `Net/FileRelayReceiver.swift`. Found by lean-review (`.maintenance/review/Processor-Net.md`).

**Root cause:** `persistProcessed()` returns `Bool` (false on encode/write failure) but both call sites
(lines 181, 190) discarded the result. If persist failed, the code proceeded to delete the source JPEG +
sidecar — losing track of the ingested photo on restart (the processed-set file didn't record it) while the
source was already gone. Low practical likelihood (local filesystem write to a known-writable directory) but
a **no-undo** data-loss path when it does fire (e.g. disk-full, permission change, sandboxing edge).

---

## ✅ FIXED (2026-07-08, Android UI-fixes batch) — Android capture-screen controls lacked accessibility labels  [LOW — a11y]

**FIXED:** `contentDescription` added to the shutter, captured thumbnails, and Box/Folder/End-segment/Re-pair controls. Landed with the connect-flow dark-mode + layout fixes (compile + review verified; on-device TalkBack confirmation deferred to the device visual check). Original report below.

Found in the 2026-07-08 on-device UI review (Pixel 9). The center shutter button (and the preview/status
controls) have no `contentDescription`, so VoiceOver/TalkBack announces an unlabeled button. No functional or
data impact. Fix: add content descriptions to the shutter + Box/Folder + End-segment + Re-pair controls
(`ArchiveCapture/.../ui/CaptureScreen.kt`). Part of the deferred "accessibility pass".

## ✅ FIXED (2026-07-07): Live "Process live" finalize deleted a run's originals — 0 files moved, sources gone

**Severity: CRITICAL data loss (no undo). Fixed; see the Recovery Core Directive in `CLAUDE.md`.**

**What happened (real run):** A Live-Capture run (LBJ, ~document photos) was shot, OCR'd, tagged, rotation-
reviewed, and the operator named the collection at Finish. Result: the destination collection folder was
**created but empty**, the backup folder held only `manifest.json` = `[]` (zero images), and every source
JPEG was gone. `finalizeSummary` showed "Finalized 1 collection · **0 files moved**" with **no error**.

**Root cause:** `finalize`'s success gate was `outcome.failedMoves == 0`, where `failedMoves` counted only a
real `moveItem` throw (`.failed`). A staged output that was **missing** (its file never existed at move time)
was classified `.absent` — *not* counted. Two facts combined into total loss:
1. `writeSegmentFiles` appended `stagedPDF` to `pdfURLs` **unconditionally**, even when `pdfGen.generate`
   silently failed (`try?`) and wrote nothing — a *phantom* output URL in the manifest.
2. `finalize` computed `filedSources` from **all** of `retained` (i.e. everything *staged*), not from what
   actually reached the destination, and then `clearFiled`-deleted those sources via `removeItem` (bypassing
   the Trash). So when every move was `.absent`: gate passed (`failedMoves == 0`), staging dir deleted, all
   source photos permanently deleted. The intent of the earlier "straggler" guard (below) was right —
   *delete only what was filed* — but it equated "filed" with "staged".

**Fix (this commit):**
- `executePlans` now reports `filedGroupIds` (segments whose **every PDF landed at the destination**, verified
  on disk) + `movedFiles` + `allFiled`. `finalize` deletes a source **only** for a segment in `filedGroupIds`;
  a missing/failed output keeps its source + staged output in the backup folder for retry/recovery.
- `writeSegmentFiles` records a PDF/JSON URL **only if the file exists on disk** (no phantoms). A segment that
  produced no PDF is marked `.failed` (retryable), never silently "staged".
- All post-processing deletions of capture data go to the **Trash** (`CaptureSession.trashOrRemove`), not `rm`.
- Staging moved **into the visible backup folder** (`<session>/_processed/`) so processed PDFs (with tags) are
  recoverable next to the raw sources if the app fails before finalize.
- Regression: `LiveCaptureRecoveryTestDriver` ($0, no OCR, `LIVECAPTURE_RECOVERYTEST=1`) asserts a missing
  output is never reported filed, and that `trashOrRemove` trashes rather than hard-deletes.

**Recovery note for the original run:** those source JPEGs were `removeItem`'d (Trash bypassed) so they are
**not** recoverable from this Mac. The only surviving copy would be the phone's manual **"Save to phone"**
gallery album (`Pictures/Archive Capture`) *if the operator tapped it* — the phone auto-deletes each page
~650ms after the Mac acks it, so the app's own queue no longer holds them.

---

## ✅ FIXED (2026-07-08): Merged multi-page documents left their exported original images loose in the output dir

**Status:** FIXED (2026-07-08). Found by the OCR-pipeline code review. Was **misplacement, not data
loss** — the images were not deleted, just not moved into the collection folder / renamed.

**Fix (this change):** `exportOriginalImages` now records a `source-URL → per-page exported-image URL`
map (`OCRProcessor.exportedImageMap`) at export time — i.e. BEFORE merge repoints `outputURLMap` to the
single merged PDF — and threads it into `CollectionSegmenter.organizeOutput`. For a merged multi-page
document (several source pages → one PDF) with dual output on, `organizeOutput` now NUMBERS + MOVES each
page image into the collection folder and gives the merged PDF the first image's number, mirroring
`LiveCaptureProcessor.executePlans`'s merged branch. The complete image/PDF/JSON set is now copied to
transaction-owned staging files, byte-verified, and installed without replacement before its sources are
removed; a collision advances the entire numbered set. Non-merged / no-export / crash-resume paths are
unchanged (the merged image branch requires every source page's tracked export; resume paths do not populate
`exportedImageMap`, so they use the empty default). Proven by the `$0` `CollectionOrganizeTestDriver`
(`COLLECTIONORGANIZE_TEST=1`): 17/17 PASS, including the repro (per-page images filed as
`00001`/`00002` inside the collection folder, none left loose in the output root), JSON-only collisions,
missing tracked exports, and the non-merged, no-export, and no-overwrite regressions.

**Repro:** enable *output image file* (`exportOriginals`) **and** *merge documents* **and** collection
organization, then process a multi-page document.

**Root cause:** `exportOriginalImages` runs before merge, so it writes one `<pageBase>.jpg` per source page
(`page1.jpg`, `page2.jpg`, …). Merge then collapses the per-page PDFs into `page1_merged.pdf` and points the
sources' `outputURLMap` at it. In `CollectionSegmenter.organizeOutput`, the merged PDF is moved once (via the
`movedOutputs` dedup) and the sibling-image move searches for `<mergedBase>.jpg` (`page1_merged.jpg`) — which
doesn't exist — so the real page images stayed in the output dir, unmoved and unrenamed.

---

## 1. Live "Process live" rotation review skips segments restored from a legacy staging manifest

**Status:** ✅ **FIXED in code 2026-07-17 (W14.5 — Fix option 1).** `LiveCaptureProcessor.loadStagingManifest()`
now migrates a legacy manifest instead of restoring it verbatim: via the new
`migrateLegacyManifestSegments(_:sourcesPresent:)`, each legacy segment **whose source photos all still exist**
is DROPPED (its stale staged output deleted) so the existing `activate()` resume path re-processes it from
scratch (re-OCR + re-tag → a proper `retained` entry → the end-of-session rotation review now includes it);
the manifest is then rewritten in the current `StagingManifest` format so recovery is idempotent (a crash
before re-finalize won't re-enter the legacy branch). This is exactly Fix option 1 below (cleanest correctness),
and deliberately NOT the "show all staged pages" non-fix (which would regenerate at 0° and un-rotate an
auto-rotated page). **Data-safety guard (Recovery Core Directive):** a legacy segment whose source is *gone*
(e.g. the operator hit Clear before recovering) is KEPT as-is — staged, un-reviewable, filed exactly as today —
because we must never delete regenerable output we can no longer rebuild; the raw sources always remain in the
visible backup folder, so a dropped-but-not-yet-reprocessed segment is fully recoverable. **Tier-2 gate met
unattended:** build clean (0 new warnings) + `LiveCaptureRecoveryTestDriver` ($0, no OCR) asserts the drop /
keep / delete-stale / preserve-unrecoverable behavior (ALL PASS) + adversarial self-review. **Deferred to owner
(Morning Review):** the full end-to-end verify — stage a session with a real legacy build, recover, Process,
Finish with "Review rotation" on, and confirm every page (incl. the former legacy segments) appears — needs a
legacy manifest + an OCR key to actually reprocess. The "Related, milder" `resolvedGroupIds` sub-issue below is
already independently resolved (it IS persisted + restored now — `CaptureSession.swift`), which is what lets the
resume path re-finalize a dropped document without re-popping its tag card unnecessarily.

The original analysis (kept for context; superseded by the fix above):

**Original status:** deferred (2026-07-03). Low impact, no data loss, transitional. Does NOT recur for
sessions created by the current build.

**Symptom (as reported):** After recovering an unprocessed live session and clicking *Process*, the
end-of-session rotation review showed only 2 of 6 pages — yet **all 6 files were output correctly**.

**Root cause (confirmed in code):**
- `LiveCaptureProcessor.finishSession()` (in `Capture/LiveCaptureProcessor.swift`) builds `rotationReviewPages`
  by iterating `retained.values`. `retained` holds the per-segment inputs needed to
  regenerate a segment (source URLs, `OCRResult` incl. `rotationDegrees`, tags, model, …).
- `retained[groupId]` is written **atomically with every `staged.append(...)`** in `finalizeSegment`,
  so for any segment the current build finalizes, `staged` and `retained` stay in sync.
- The **only** way `staged` can contain a segment with no `retained` entry is `loadStagingManifest()`
  restoring a **legacy-format** staging manifest — a bare `[StagedSegment]` array written
  before retained-persistence (commit `c0312f4`). The new format is `StagingManifest { staged, retained }`;
  the legacy branch restores `staged` + `finalizedGroups` but leaves `retained` empty for those segments.
- Result on recovery of such a session: legacy segments are re-staged/output (they're in `staged`) but
  **excluded from the rotation review** (not in `retained`), while freshly-processed segments appear.

**Impact:** minor. Output is correct — legacy segments keep the rotation that was baked when they were
first staged (auto-detected). The user just can't *manually re-review* those pages' orientation.

**Why not fixed now (the trap):** faithfully regenerating a legacy segment with a corrected rotation
needs its original `rotationDegrees` + OCR text + tags + model. A legacy manifest has none of these.
Reconstructing from `staged` + the segment JSON + `session.groups` still lacks the **original
`rotationDegrees`**, so regenerating a page seeded at 0° would *un-rotate* a page that had been
auto-rotated — strictly worse than today. So a naive "show all staged pages in the review" change is
unsafe unless regeneration is gated.

**Fix options for later:**
1. On legacy-manifest recovery, DROP those segments from `staged`/`finalizedGroups` so they're
   re-processed from scratch (re-OCR + re-tag → proper `retained`). Guarantees a complete review;
   cost = redoes OCR + re-prompts tagging for already-staged segments. Cleanest correctness.
2. Drive `finishSession` from `staged` (authoritative), include legacy segments in the review, but in
   `applyRotationReviewAndFinalize` **skip regeneration for any segment lacking `retained`** (they keep
   their staged output). Review is then complete, but rotating a legacy page does nothing — needs a
   clear UI affordance so it isn't confusing.
3. Persist `rotationDegrees` (and enough to regenerate) in the per-segment staging JSON going forward,
   so any future format gap is recoverable. Doesn't help already-written legacy manifests.

**Related, milder:** on recovery `session.resolvedGroupIds` isn't persisted, so already-staged document
groups can re-pop their tag card. No data harm — `finalizeSegment` guards `!finalizedGroups.contains`,
so re-saving is a no-op — but it's confusing UX. Seeding `resolvedGroupIds` from restored staged groups
in `loadStagingManifest` would fix it.

**Repro (approx):** stage a live session with an older build (legacy manifest) → force a restart so the
session is recovered → *Process* → *Finish session* with "Review rotation" on → review shows only the
segments finalized in the current run.

---

## Live Capture main-window OCR/progress text is stale while the per-segment tag card is open  [LOW — UX]

**Severity: low (cosmetic/UX).** Observed 2026-07-06 (Process-live, Mac): while the per-segment tag card
dialog is open, the left-pane status ("0/1 segments processed", "OCR…") does **not** update — it looked
frozen on "OCR…" for minutes even though OCR had actually completed. It refreshed to "Staged" only after
the tag card was submitted. Harmless (OCR was fine; provider=Gemini, key present, Mac reaches the API),
but it makes OCR look **hung** during tagging and cost real diagnosis time in the walkthrough. Fix: keep
the progress/OCR status live while the tag card is presented (the `@Published` progress updates aren't
re-rendering behind the modal, or the sheet blocks the main-window refresh). `Views/LiveCaptureView.swift`.

**FIXED in code (pending owner GUI-verification).** The Processing status/segment list was extracted into a
dedicated `LiveProcessingBox` view that **owns** the `@ObservedObject` subscription to `LiveCaptureProcessor`
(and `CaptureSession`). Because the child subscribes to `liveProc` directly, SwiftUI invalidates it on each
published phase/progress change even while the parent presents the tag-card sheet — so it no longer freezes
behind the modal. View-only change (`Views/LiveCaptureView.swift`).

---

## Live Capture "Clear" empties the Captured pane but leaves the Processing pane's segments  [LOW — UX]

**Severity: low (cosmetic/UX; no data loss).** Reported by the owner (2026-07-07). In Live Capture, clicking
**Clear** empties the **Captured** pane (the shot photos disappear) but the **Processing** pane's segment
rows **remain** — so the two panes disagree about session state after a Clear. Expected: Clear resets both
panes to empty together. Likely the Clear action resets `CaptureSession`'s received-photos/captured state but
not the `LiveCaptureProcessor`'s staged/segment list that drives the Processing pane; wire Clear to also reset
(or reconcile) the processor's segment state so both panes clear as one. `Views/LiveCaptureView.swift`,
`Capture/LiveCaptureProcessor.swift`, `Capture/CaptureSession.swift`.

**FIXED in code (pending owner GUI-verification).** The Clear button now calls a new
`LiveCaptureProcessor.clearSessionState()` alongside `CaptureSession.clear()`, so the Processing pane's
in-memory segment/staged state resets together with the Captured pane. It is a **pure in-memory/UI reset** —
no on-disk deletion beyond what `session.clear()` already did (received photos → Trash); any already-staged
`_processed` output stays recoverable in the backup folder, so the Recovery Core Directive is unchanged.

---

## Mac doesn't detect a phone-side Re-pair — stale "paired" state, QR must be re-shown manually  [LOW–MED — UX]

**Severity: low–medium (UX / confusion).** The **Re-pair control on the phone works** (returns the phone
to the scanner — verified 2026-07-06). But the phone↔Mac protocol has **no disconnect signal**, so when
the phone re-pairs the Mac keeps its "connected / QR hidden" state; the operator must know to click **Show
QR** to re-display it. The "listening" status dot staying green further reads as "still paired," which
confused the operator into thinking Re-pair hadn't worked. **Fix ideas:** (1) when the phone re-pairs,
have it fire a lightweight `POST /session/disconnect` (or the Mac infers a drop from ping-timeout) so the
Mac auto-re-shows the QR; (2) distinguish "server listening" from "phone connected" in the status UI
(e.g., last-seen heartbeat). Also observed alongside: the **`adb reverse` USB forward is torn down** on
re-pair, so a subsequent **Wired** re-pair needs it re-established (the Mac's `USBBridge` should re-run
`adb reverse` on reconnect; verify it does). `Net/CaptureServer.swift`, `Net/USBBridge.swift`,
`Views/LiveCaptureView.swift`, + both companions' capture screens.

**FIXED in code (B4 — pending owner live-verify).** (i) `POST /session/disconnect` now calls a new
`CaptureSession.phoneDidDisconnect()` (instead of just `unpairDisplay()`), which resets the pairing +
connection indicators (`paired`, `phoneConnected`, `lastPhoneContactAt`, `connectedDeviceName`) and
re-shows the QR automatically; received photos + session state are untouched (they re-upload idempotently).
(ii) The Connection box now splits **"No phone connected" vs "Connected · <device>"** from mere receiver
"Listening (Wi-Fi / USB)"/"Watching Drive" (A5 rows kept), driven by a new `phoneConnected` — a published
liveness flag set on any phone contact (ping / `/phone/status` heartbeat / ingest) and expired by a 5s
freshness timer (25s window) so a stale green dot no longer reads as "still paired." (iii) `USBBridge`
already re-asserts `adb reverse` on a 5s heal timer (so a wired re-pair self-heals); added
`USBBridge.reassertNow()`, fired from `phoneDidDisconnect()`, so it re-asserts immediately instead of
waiting up to 5s. The live re-pair walkthrough (incl. wired) is owner-GUI-gated.

---

## Per-capture streaming — implemented; residual refinements (from the 2026-07-06 Tier-2 review)

Per-capture streaming is now implemented (photos stream to the Mac as shot; End segment sends
`POST /segment/complete` with the tags; Mac gates the tag card on `completedDocGroups`). An adversarial
Tier-2 review confirmed one **critical** data-loss path, now **guarded**, plus refinements. **All of this
needs the on-device Wi-Fi/Run C walkthrough to verify — implemented build-verified only, not yet run on a phone.**

**FIXED (guard shipped): straggler page permanently deleted.** If the tiny `segment/complete` (or
`session/complete`) signal outraced a still-uploading page, the Mac finalized the segment without it, then
`session.clear()` deleted its backup → permanent loss of an irreplaceable page. Guard: `finalize` now calls
`session.clearFiled(filedSourceURLs)` — deletes only pages actually filed into output and **keeps any
un-filed (straggler) page** in the backup folder + Captured pane. No page is ever deleted before it's filed.
(`LiveCaptureProcessor.finalize`, `CaptureSession.clearFiled`.) **⚠️ Update 2026-07-07:** this guard derived
`filedSourceURLs` from `retained[].pages.sourceURL` — i.e. everything *staged*, which is **not** the same as
*filed at the destination*. That gap caused the CRITICAL total-loss bug now fixed at the top of this file
(`finalize` deleted a run's originals). Deletion now keys off `executePlans.filedGroupIds` (confirmed on disk).

**Residual refinements (next session, device-verify):**
1. **Straggler still omitted from finalized output (HIGH, not data-loss).** With the guard a straggler isn't
   lost but isn't auto-filed into its collection either — it lingers unfiled in the Captured pane. Full fix:
   the phone defers `sendSegmentComplete` (and `finishSession`'s `/session/complete`) until **every page of
   the segment is confirmed UPLOADED**, so the Mac never finalizes a partial segment. Both companions (record
   a pending-complete group; flush when all its pages hit UPLOADED, from the upload-success path + auto-retry).
   **FIXED in code (`ce55511`, 2026-07-07; verified + reconciled 2026-07-17 as W14.1 — pending owner device-verify).**
   Both companions record ended-but-unacked segments (`endedSegments`) and emit the completion signal only via
   `trySendSegmentComplete`, which early-returns unless **every page of the group is `UPLOADED`** (Android
   `CaptureViewModel.kt:527` / iOS `:369`) — the sole caller of the transport `segmentComplete(...)`. It's flushed
   from the upload-success handler (Android `:622` / iOS `:456`), the 8s auto-retry loop (Android `:229` / iOS
   `:524`), and reconnect/resume (`:209`/`:508`), so a straggler that finishes late still completes its segment.
   The `session/complete` half is moot on the phone: the transport `sessionComplete()` has **no caller** (the phone
   "Finish" action that once sent it was removed — End segment is the only phone-side "done"), and whole-session
   force-completion is a Mac-side backstop. An adversarial re-read of both companion trees (2026-07-17) could not
   break the gate. **Owner device-verify tail:** `scripts/e2e-phone-mac.sh` (Gemini key + `ap_test` emulator).
2. **Per-page P10 toggled while a page is UPLOADING never reaches the Mac (MEDIUM).** `toggleP10` re-uploads
   only when `state == UPLOADED`. Fix: a `needsResend` flag the upload-completion handler honors. Both companions.
   **FIXED in code (B5-i — pending owner device-verify):** both companions gained a persisted `needsResend`
   field on `CapturedItem`. `toggleP10`/`reclassifySelected` now call `resendOrEnqueue`: enqueue if idle, else
   set `needsResend`. The upload-completion handler, on success, honors `needsResend` by re-sending with the
   CURRENT fields (and NOT removing the photo) instead of confirming — so a change made mid-upload is never
   dropped. (iOS `Capture/CaptureViewModel.swift`, Android `capture/CaptureViewModel.kt`.)
3. **Reclassify of a doc page whose `/photo` is in-flight is dropped (MEDIUM).** The `inFlightUploads` guard
   suppresses the reclassify re-enqueue. Same `needsResend` fix. Both companions. **FIXED in code (B5-i, same
   `resendOrEnqueue`/`needsResend` path as #2 — pending owner device-verify).**
4. **`completedDocGroups` not persisted across a Mac restart (LOW).** After a mid-session Mac restart, no
   document tag card appears until Finish. Fix: persist it in the manifest, or on restore treat every
   restored document group as complete. **FIXED in code (B5-ii):** the session manifest is now a
   `{photos, completedDocGroups}` object (was a bare `[ManifestEntry]` array); `decodeManifest` accepts both
   shapes so legacy in-flight sessions still recover (completion set empty). `markSegmentComplete`/
   `completeAllOpenDocGroups` persist the set, and restore rehydrates it. Proven headlessly by
   `ManifestPersistenceTestDriver` (`LIVECAPTURE_MANIFESTTEST=1` — round-trip + legacy + corrupt-bytes).

---

## Cloud/relay: reclassify a page whose original document group already finalized → duplicate output  [MEDIUM — relay-amplified]

**Status:** partially mitigated (2026-07-09); post-finalize race remains deferred to Drive milestone.

**Partial fix (2026-07-09):** the `replaces` reclassify chain divergence is fixed — both iOS and Android
now **append** the old group to the existing chain (SPEC A3: `"G,H"` not just `"H"`), and the Mac's HTTP
receiver (`CaptureServer`) now splits the comma-joined chain and tombstones each prior group individually
(matching `FileRelayReceiver`). A chained reclassify G→H→I no longer strands G. The **post-finalize race**
(A11: reclassify after the original group is already staged/finalized → `removePhotoIfSafe` no-ops) remains
deferred — see below.

`removePhotoIfSafe` no-ops when the old group `isFinalized` (`CaptureSession.swift:231`). Over HTTP this is
nearly unreachable (uploads are consumed immediately). With a **relay** (objects persist until the Mac drains
them) the sequence is reachable: a page uploads into group G; the phone's `postPhoto` times out (or its receipt
is swept) before the phone marks it UPLOADED, so it stays on the phone; G finalizes with the page; the operator
then reclassifies the still-held page to a Box → the Mac ingests the new marker but `removePhotoIfSafe(G,seq)`
no-ops (G finalized) → the photo exists in **both** G's collection AND the new marker (duplicate output of an
irreplaceable photo + wrong classification).

**Fix (Drive milestone):** on ingesting a late `replaces=G` object where G isFinalized, reconcile — remove the
reclassified page from G's already-staged output (+ renumber), or refuse the reclassify and signal the phone.
Touches the Tier-2 finalize/staging path + needs a phone-signal channel, hence deferred. For the FileRelay
milestone the Mac logs the collision and does not expand the existing no-op.

---

## Collection pinned in arrival order on relay transport  [MEDIUM — FIXED]

**Status:** FIXED (2026-07-09).

On relay transport, network reordering could cause a document to arrive before its Box marker. The Mac
pinned `groupCollectionKey` at arrival time, so such a document was assigned to the *previous* collection
(or `__unfiled__`), then its source photos were trashed at finalize — filed under the wrong box.

**Fix:** `LiveCaptureProcessor.backfillCollections()` — when a Box arrives, re-resolve collection assignments
for all not-yet-finalized groups AND already-staged segments using the phone's capture sequence (`CaptureGroup.order`)
as the source of truth. Also corrects `currentCollectionKey` to the highest-seq box (not the most-recently-arrived).
Persists the corrected manifest so a crash doesn't revert the fix. (`LiveCaptureProcessor.swift:347–379`.)

---

## ✅ FIXED (2026-07-09): data race on `MacOSTagger.stampUnread`  [MEDIUM — concurrency]

**Status:** FIXED. `nonisolated(unsafe) static var stampUnread` was written on `@MainActor` (from
`OCRProcessor.taggingMode.didSet` and `LiveCaptureProcessor.startProcessing`) and read from detached
OCR tasks in `applyTags`. Under Swift 6 strict concurrency the `nonisolated(unsafe)` annotation suppressed
the diagnostic but did not provide a memory-ordering guarantee — the write on MainActor could be invisible
to a reader on another thread, causing a live document to be mis-tagged (e.g., Unread stamp missing or
applied in copy-source mode).

**Fix:** replaced the bare `nonisolated(unsafe) static var` with an `OSAllocatedUnfairLock`-backed computed
property — same `Bool` get/set interface, zero call-site changes. The lock guarantees the MainActor write is
visible to any detached-task reader. (`Tagging/MacOSTagger.swift`.)

---

## ✅ FIXED (2026-07-09): idle-connection leak in `CaptureServer`  [MEDIUM — resource leak]

**Status:** FIXED. `CaptureServer.handle(_:)` started an `NWConnection` and entered the `readRequest` loop,
but if the remote peer never sent data (or sent only partial data and stalled), the connection was never
cancelled — leaking its file descriptor, receive buffers, and associated Network.framework state for the
process lifetime. Over a long Live Capture session with network churn (port scans, half-open TCP connects,
or a phone that opens a connection then loses Wi-Fi), this could accumulate leaked FDs and memory.

**Fix:** added a 30-second idle timeout (`DispatchWorkItem` on the serial `queue`). If no complete HTTP
request arrives within the deadline, the connection is cancelled. The timeout is cancelled on every terminal
path (successful parse, error, too-large, bad request) so well-behaved clients are unaffected. The timeout
work item captures the connection weakly to avoid preventing deallocation. All dispatch happens on the same
serial queue, so there is no race between the timeout and the receive callback.
(`Net/CaptureServer.swift`.)

---

## ✅ FIXED (2026-07-09): review-sweep Tier-A batch — 7 file-safety / data-loss / SPEC fixes  [MED–HIGH]

**Status:** FIXED. Found by the parallel review sweep (`.maintenance/review/sweep-raw-2026-07-09.md`),
each verified against the actual code before fixing. All Tier-2 (adversarial review + build clean).

1. **Merged-PDF overwrite-by-basename** (`OCRProcessor+Tagging.swift:785`): two multi-page segments sharing
   a first-page source basename would overwrite each other's merged PDF (sources already deleted). Fix: name
   the merged PDF after the dedup'd OUTPUT URL, not the raw source.
2. **`try?`-swallowed PDF write error** (`OCRProcessor+OCR.swift:787`): `handleOCRResult` marked a job
   `.succeeded` based on OCR text alone; a failed `PDFGenerator.generate` was invisible. Fix: `do/try/catch`;
   on write failure mark `.failed` + log.
3. **JSON-sidecar wrong-file rename** (`OCRProcessor+Tagging.swift:804`): the merge renamed JSON by the raw
   source basename, not the dedup'd output name — moving the wrong file when output URLs were dedup'd. Fix:
   derive the JSON path from the first output PDF.
4. **`readTags` coerced read-failure → `[]`** (`MacOSTagger.swift:23`): the read→append→rewrite callers
   (priority tags, image tag mirroring) would WIPE existing tags on a read failure. Fix: `readTags` now
   `throws`; callers bail on error instead of writing empty tags.
5. **Raw `applyTags` promoted subject "Red"/"Purple" to Finder color** (`MacOSTagger.swift:64`): the merge
   path called the `[String]` overload without `colorIsAuthoritative`, so a subject tag "Red" was promoted to
   a color label. Fix: derive the authoritative color from the job's classification.
6. **Numeric month/day coercion** (`TagGenerator.swift:263`): `stringField` turned a JSON number `3` into
   the bare string `"3"` — a SPEC-nonconforming month tag. Fix: normalize to "MM Month" / "Day N" format.
7. **Free-text manual date tags** (`ManualTaggingSheet.swift:164`): user-typed bare month/day values were
   written verbatim as Finder tags. Fix: normalize through the same `monthTag`/`dayNumber` helpers.

Files: `OCRProcessor+OCR.swift`, `OCRProcessor+Pipeline.swift`, `OCRProcessor+Tagging.swift`,
`MacOSTagger.swift`, `TagGenerator.swift`.

---

## ✅ FIXED (2026-07-09): data race on `CaptureServer.listener` between `stop()` and `retryWithSystemPort()`  [HIGH — concurrency]

**Status:** FIXED. The class comment claimed `listener` is "only touched on the serial `queue`," but
`start()` and `stop()` accessed it directly from whatever thread called them (typically `@MainActor` via
`CaptureSession`), while `retryWithSystemPort()` ran on `self.queue` from the NWListener state callback.
A MainActor call to `stop()` concurrent with a queue-dispatched `retryWithSystemPort()` was an unsynchronized
read/write on the same mutable property.

**Fix:** `start()` and `stop()` now dispatch their `listener` access onto `self.queue`, making the class
comment true — all `listener` reads and writes serialize on the single serial queue. Both methods are
fire-and-forget from the caller's perspective (no return value, no completion), so the async dispatch is
transparent. (`Net/CaptureServer.swift`.)

---

## ✅ FIXED (2026-07-09): iOS/file relay segmentComplete/sessionComplete return true without confirming write  [HIGH — silent tag loss]

**Status:** FIXED. Both `DriveRelayTransport` and `FileRelayTransport` returned `true` from
`segmentComplete()` and `sessionComplete()` immediately after writing, without checking whether the
write succeeded. The underlying `upsert` (Drive) and `writeAtomic` (file) swallowed all errors via
`try?`. The caller (`CaptureViewModel.trySendSegmentComplete`) removes the group from `endedSegments`
on `true`, stopping all retries — so a silently-failed write meant the Mac never received the
segment-complete signal, and the document's tags were permanently lost.

Contrast with `postPhoto`, which correctly gates `true` on a Mac-written receipt (receipt-wait loop).

**Fix:** `writeAtomic` and `upsert` now `throw` instead of silently swallowing errors.
`segmentComplete` and `sessionComplete` wrap the write in `do/try/catch` and return `false` on
failure — triggering the caller's 3-attempt retry. `postPhoto` callers use `try?` on the write
(receipt-wait is the true confirmation). (`Net/FileRelayTransport.swift`, `Net/DriveRelayTransport.swift`.)

---

## ✅ FIXED (2026-07-09): iOS `accessTokenBlocking()` deadlock risk + unbounded semaphore wait  [HIGH — concurrency]

**Status:** FIXED. `DriveAuth.accessTokenBlocking()` used `DispatchSemaphore.wait()` with no timeout,
bridging to a `Task { @MainActor in }` for token refresh. Two bugs: (1) if called from the main thread
(e.g., a future call-site mistake), the semaphore blocks the main thread while the `@MainActor` Task
needs the main thread to run — instant deadlock; (2) if the Google token endpoint is unreachable or
stalls, the semaphore waits forever, hanging the upload thread permanently.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** added `dispatchPrecondition(condition: .notOnQueue(.main))` to trap immediately if called from
the main thread (instead of silently deadlocking), and changed `sem.wait()` to
`sem.wait(timeout: .now() + 65)` with a `DriveError.tokenRefreshTimedOut` throw on timeout — matching
the Android `CountDownLatch.await(30, SECONDS)` pattern and the macOS `DriveClient` semaphore timeout
(W3.n4). (`Net/DriveAuth.swift`, `Net/DriveClient.swift`.)

---

## ✅ FIXED (2026-07-09): iOS deleteItem has no upload-state guard — un-uploaded photos irrecoverably lost  [HIGH — data loss]

**Status:** FIXED. `CaptureViewModel.deleteItem()` unconditionally deleted the local JPEG and removed the
item from the model, regardless of upload state. If a photo was `.pending`, `.uploading`, or `.failed`
(never confirmed on the Mac), the tap-to-delete cycle (select → arm → delete) permanently destroyed it
with no confirmation and no recovery path.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** `deleteItem` now checks `items[i].state`: if `.uploaded`, delete immediately (the Mac has it);
otherwise, set `pendingDeleteId` to trigger a destructive confirmation dialog ("This photo hasn't reached
the Mac yet. Deleting it here loses it forever."). The user must explicitly confirm before an un-uploaded
photo is removed. (`Capture/CaptureViewModel.swift`, `UI/CaptureScreen.swift`.)

---

## ✅ FIXED (2026-07-09): iOS clearSession confirmation doesn't distinguish uploaded from un-uploaded photos  [MED — data loss risk]

**Status:** FIXED. The "Clear all photos?" confirmation dialog showed a generic message regardless of
whether any photos had NOT been uploaded to the Mac. A user could tap Clear thinking everything was
safely on the Mac when `.pending`/`.failed` items still existed only on the phone.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** The confirmation message now branches: if all items are `.uploaded`, it says "All photos have
been uploaded to the Mac"; otherwise it warns with the exact count of un-uploaded photos that will be
permanently lost. (`UI/CaptureScreen.swift`.)

---

## ✅ FIXED (2026-07-09): DriveRelayTransport epoch cached, not re-read per iteration  [MED — correctness]

**Status:** FIXED. `DriveRelayTransport.postPhoto` resolved the Mac-published epoch once
(`if ep == nil { ep = epoch(f) }`) and cached it for the entire receipt-wait loop. If the Mac
restarted mid-transfer with a new epoch, the phone kept using the stale value — receipts (which carry
the new epoch) would never match, and sidecars were written with the wrong epoch. The photo would time
out and retry, but the retry re-entered the same `postPhoto` call with a fresh `ep = nil`, so it
would eventually recover — but only after a full 20s timeout per photo per Mac restart.

By contrast, `FileRelayTransport` correctly calls `currentEpoch()` every iteration and tracks
`wroteForEpoch` to re-write the sidecar if the epoch changes mid-loop.

Same bug existed in the Android Kotlin mirror.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** Both iOS and Android `DriveRelayTransport.postPhoto` now re-read `epoch(f)` every iteration
(matching `FileRelayTransport`), and use `wroteForEpoch` (string, not bool) so the sidecar is
re-written with the correct epoch if it changes mid-loop.
(`Net/DriveRelayTransport.swift`, `net/DriveRelayTransport.kt`.)
