# Known Issues (deferred)

Tracked bugs we've chosen to come back to later. Each entry has enough context to resume cold.

---

## B9 (LOW) — resolved tag cards re-surface after a mid-session Mac restart; re-entered tags on an already-staged segment are dropped

Found by the B4/B5 review (2026-07-08). `CaptureSession` persists `completedDocGroups` (B5-ii) but NOT
`resolvedGroupIds`, so after a mid-session Mac restart a group already resolved+finalized re-shows its tag
card (`pendingTagGroup`); re-tagging it no-ops on the already-baked staging output (the new tags never reach
it). **Pre-existing root cause** — the same fires at Finish via `completeAllOpenDocGroups` post-restart; B5-ii
merely triggers it mid-session too. **NO data loss / NO double-file** (guarded by `finalizedGroups.contains`
in `segmentResolved`). Fix: persist `resolvedGroupIds` (+ `macTags`) in the manifest, OR intersect the restored
`completedDocGroups` against the processor's persisted `finalizedGroups` on restore so a resolved group doesn't
re-surface. `Capture/CaptureSession.swift`, `Capture/LiveCaptureProcessor.swift`.

---

## Android capture screen controls lack accessibility labels  [LOW — a11y]

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
`LiveCaptureProcessor.executePlans`'s merged branch. Moves only, never overwrites (skips a colliding
destination rather than deleting). Non-merged / no-export / crash-resume paths are unchanged (the merged
branch fires only when `moveSiblingImages` is on AND >1 source maps to the same PDF AND ≥1 exported image
exists; the resume paths never populate `exportedImageMap`, so they pass the empty default). Proven by the
`$0` `CollectionOrganizeTestDriver` (`COLLECTIONORGANIZE_TEST=1`): 10/10 PASS, including the repro
(per-page images filed as `00001`/`00002` inside the collection folder, none left loose in the output
root) plus the non-merged, no-export, and no-overwrite regressions.

**Repro:** enable *output image file* (`exportOriginals`) **and** *merge documents* **and** collection
organization, then process a multi-page document.

**Root cause:** `exportOriginalImages` runs before merge, so it writes one `<pageBase>.jpg` per source page
(`page1.jpg`, `page2.jpg`, …). Merge then collapses the per-page PDFs into `page1_merged.pdf` and points the
sources' `outputURLMap` at it. In `CollectionSegmenter.organizeOutput`, the merged PDF is moved once (via the
`movedOutputs` dedup) and the sibling-image move searches for `<mergedBase>.jpg` (`page1_merged.jpg`) — which
doesn't exist — so the real page images stayed in the output dir, unmoved and unrenamed.

---

## 1. Live "Process live" rotation review skips segments restored from a legacy staging manifest

**Status:** deferred (2026-07-03). Low impact, no data loss, transitional. Does NOT recur for
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

**Status:** deferred (2026-07-06), from the FileRelay design adversarial review (hole H10, see
`../SPEC/relay-object-format.md` A11). Fix scoped to the Drive milestone.

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
