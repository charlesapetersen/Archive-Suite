# Known Issues (deferred)

Tracked bugs we've chosen to come back to later. Each entry has enough context to resume cold.

---

## 2. Merged multi-page documents leave their exported original images loose in the output dir

**Status:** deferred (2026-07-04). Found by the OCR-pipeline code review. **Misplacement, not data
loss** — the images are not deleted, just not moved into the collection folder / renamed.

**Repro:** enable *output image file* (`exportOriginals`) **and** *merge documents* **and** collection
organization, then process a multi-page document.

**Root cause:** `exportOriginalImages` runs before merge, so it writes one `<pageBase>.jpg` per source page
(`page1.jpg`, `page2.jpg`, …). Merge then collapses the per-page PDFs into `page1_merged.pdf` and points the
sources' `outputURLMap` at it. In `CollectionSegmenter.organizeOutput`, the merged PDF is moved once (via the
`movedOutputs` dedup) and the sibling-image move searches for `<mergedBase>.jpg` (`page1_merged.jpg`) — which
doesn't exist — so the real page images stay in the output dir, unmoved and unrenamed.

**Fix (for later):** pass the per-page exported-image URLs (keyed by source URL, or the segment's page-image
list) into `organizeOutput`, and for a merged document (one PDF, many page images) number + move EACH page
image into the collection folder — mirroring `LiveCaptureProcessor.executePlans`'s merged branch (which already
does exactly this). `organizeOutput` can't recover the per-page names from the merged PDF alone, so it needs
that mapping threaded in.

---

## 3. Zoomed image installs an app-wide scroll monitor that swallows scroll for other views

**Status:** deferred (2026-07-04). Found by the views code review. **Usability, not data loss.**

**Symptom:** in the Segment & Tag review, zoom a page past 100% (`+`), then try to scroll the filmstrip or
the tag-card thumbnail strip — the scroll is consumed to pan the zoomed canvas instead. Works again after `0`
(reset to 100%).

**Root cause:** `ZoomableImageView.startMonitor` uses `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)`
— an **app-wide** local monitor. While `pan.zoom > 1` it returns `nil` (consumes) for *every* scroll event in
the app, not just those over the image.

**Fix (for later):** replace the app-wide monitor with a hosted `NSView` subclass (via `NSViewRepresentable`)
that overrides `scrollWheel(with:)`, so only scroll events actually routed to that view are consumed. A
hit-test on the SwiftUI struct isn't directly possible because it holds no reference to its backing NSView.

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

## Live Capture Wi-Fi pairing fails **silently** when the network blocks device-to-device

**Severity: medium (UX / supportability).** When the phone scans a valid QR but then cannot reach the
Mac's `CaptureServer`, **nothing happens on the phone** — no spinner, no error, no explanation. The user
is left pointing the camera at a QR that will never connect. Discovered 2026-07-06 on **airport Wi-Fi**:
Mac server was confirmed healthy (`*:48627` LISTEN, firewall permits, stealth off, QR encoding the en0
IP), but the network had **client isolation** (AP isolation) — a phone-browser hit to
`http://<mac-ip>:48627/ping` also timed out. Common on public/guest/airport/hotel/CGNAT Wi-Fi.

The phone decodes the QR, fires the `/ping` handshake (`MacClient.ping`, ~5s connectTimeout), it times
out, and the failure is swallowed — the scanner just sits there.

**Fix (make the failure legible + actionable):**
1. On the scan→connect path, show explicit state: *"Found pairing code — connecting to <ip>:<port>…"* then
   on `/ping` failure a clear message: *"Can't reach the Mac at <ip>:<port>. This Wi-Fi may block
   device-to-device connections (common on public/guest networks)."*
2. Offer concrete fallbacks in that message: **use a USB cable**, **use a personal hotspot** (bypasses AP
   isolation), or a future cloud relay (see POTENTIAL_FEATURES).
3. Consider a tiny **reachability preflight**: right after decoding the QR, `GET /ping` with a short
   timeout and route straight to the diagnostic message on failure, so the user never stares at a dead
   scanner. Mirror the same on the iOS companion (`MacClient`).
4. Mac side could also help: the Live Capture tab could note "phone not connecting? your network may block
   device-to-device — try USB or a hotspot," and/or show the exact host:port it's advertising.

---

## Photos must stream to the Mac per-capture — NOT be held on the phone until "End segment"  [HIGH — data safety]

**Severity: HIGH — violates the core "never lose a photo" invariant.** Observed 2026-07-06 (USB
Process-live session): took one shot; the phone showed it captured, but after several minutes — with
`adb reverse` up and `/ping` healthy — the photo had **not** reached the Mac (empty backup folder, no
receive in the app log). The photo **bytes stay on the phone until the user taps "End segment."**

**Why this is dangerous:** a single segment can be **hundreds of photos** long. Holding an entire
in-progress segment on the phone means a phone crash / drop / dead battery / app-kill *before* End
segment loses **all** of those pages at once — irreplaceable archival photos that can't be re-shot.
Live Capture's whole promise is that a captured photo is never lost.

**Required behavior:** each photo's **bytes** must transfer to the Mac and be written to the durable,
user-visible backup folder **as it is captured** (streamed continuously), backed by the existing durable
disk-queue + auto-retry + idempotent re-upload (group+seq) for guaranteed eventual delivery. **"End
segment" is only the logical/visual grouping** — the moment the on-phone thumbnails "leave" and the
document boundary is confirmed — and must NOT gate the byte transfer. By the time the user ends a
segment, the Mac should already hold every page; End segment just finalizes/assembles it.

**Acceptance:** during a long (e.g. 100+ shot) segment, the Mac backup folder fills **continuously** as
shots are taken, not in one burst at End segment; killing the phone mid-segment loses nothing already
shot. Tier-2 (Net/ + the phone↔Mac protocol + never-lose-a-photo path) → adversarial review; verify on
**both** companions (Android + iOS).

---

## Live Capture main-window OCR/progress text is stale while the per-segment tag card is open  [LOW — UX]

**Severity: low (cosmetic/UX).** Observed 2026-07-06 (Process-live, Mac): while the per-segment tag card
dialog is open, the left-pane status ("0/1 segments processed", "OCR…") does **not** update — it looked
frozen on "OCR…" for minutes even though OCR had actually completed. It refreshed to "Staged" only after
the tag card was submitted. Harmless (OCR was fine; provider=Gemini, key present, Mac reaches the API),
but it makes OCR look **hung** during tagging and cost real diagnosis time in the walkthrough. Fix: keep
the progress/OCR status live while the tag card is presented (the `@Published` progress updates aren't
re-rendering behind the modal, or the sheet blocks the main-window refresh). `Views/LiveCaptureView.swift`.

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

---

## Per-capture streaming — implemented; residual refinements (from the 2026-07-06 Tier-2 review)

Per-capture streaming is now implemented (photos stream to the Mac as shot; End segment sends
`POST /segment/complete` with the tags; Mac gates the tag card on `completedDocGroups`). An adversarial
Tier-2 review confirmed one **critical** data-loss path, now **guarded**, plus refinements. **All of this
needs the on-device Wi-Fi/Run C walkthrough to verify — implemented build-verified only, not yet run on a phone.**

**FIXED (guard shipped): straggler page permanently deleted.** If the tiny `segment/complete` (or
`session/complete`) signal outraced a still-uploading page, the Mac finalized the segment without it, then
`session.clear()` deleted its backup → permanent loss of an irreplaceable page. Guard: `finalize` now calls
`session.clearFiled(filedSourceURLs)` (from `retained[].pages.sourceURL`) — deletes only pages actually
filed into output and **keeps any un-filed (straggler) page** in the backup folder + Captured pane. No page
is ever deleted before it's filed. (`LiveCaptureProcessor.finalize`, `CaptureSession.clearFiled`.)

**Residual refinements (next session, device-verify):**
1. **Straggler still omitted from finalized output (HIGH, not data-loss).** With the guard a straggler isn't
   lost but isn't auto-filed into its collection either — it lingers unfiled in the Captured pane. Full fix:
   the phone defers `sendSegmentComplete` (and `finishSession`'s `/session/complete`) until **every page of
   the segment is confirmed UPLOADED**, so the Mac never finalizes a partial segment. Both companions (record
   a pending-complete group; flush when all its pages hit UPLOADED, from the upload-success path + auto-retry).
2. **Per-page P10 toggled while a page is UPLOADING never reaches the Mac (MEDIUM).** `toggleP10` re-uploads
   only when `state == UPLOADED`. Fix: a `needsResend` flag the upload-completion handler honors. Both companions.
3. **Reclassify of a doc page whose `/photo` is in-flight is dropped (MEDIUM).** The `inFlightUploads` guard
   suppresses the reclassify re-enqueue. Same `needsResend` fix. Both companions.
4. **`completedDocGroups` not persisted across a Mac restart (LOW).** After a mid-session Mac restart, no
   document tag card appears until Finish. Fix: persist it in the manifest, or on restore treat every
   restored document group as complete.
