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

## 4. Android companion: reclassify's X-Replaces is lost on upload retry (stray duplicate on the Mac)

**Status:** deferred (2026-07-04). Found during the maintainability pass. **Real data-integrity bug**, kept
here (not fixed) so that pass stayed behavior-preserving — the **iOS twin was already fixed** in commit `8df6ef4`.

**Symptom:** reclassifying a photo into a Box/Folder marker while unpaired or during a network blip can leave
BOTH the original document-group copy AND the new marker on the Mac — a stray extra page in the segment.

**Root cause:** `reclassifySelected` (`ArchiveCapture/.../capture/CaptureViewModel.kt`) calls
`enqueueUpload(updated, replaces = oldGroupId)` so the Mac drops the old `(oldGroupId, seq)` copy. But
`replaces` is a transient parameter, not stored on the `CapturedItem`. The retry / resume / auto-retry paths
all call `enqueueUpload(it)` with the default `replaces = null`, so if the first attempt doesn't land, the
eventual successful upload omits `X-Replaces` and the Mac keeps the original (its idempotent replace is keyed
on group+seq, and the group now differs).

**Fix (mirror the iOS fix `8df6ef4`):** add `replacesGroupId: String?` to the Android `CapturedItem`, set it in
`reclassifySelected`, and have `enqueueUpload` read it from the item so every re-send keeps sending `X-Replaces`
until it lands. Persist it in `SessionStore` for durability across restart.
