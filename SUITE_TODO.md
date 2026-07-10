# Archive Suite — working to-do queue

The **near-term** to-do queue for both apps (see root `CLAUDE.md` §Docs & backlog convention). Long-term
ideas live in each app's `POTENTIAL_FEATURES.md`; detailed in-flight plans live in `execution-plans/`
(indexed below, deleted when shipped). Full-codebase review: the paced method in `REVIEW.md`. Unattended /
overnight runs: `ops/overnight/README.md` (durable plan → self-resume daemon), which drains this queue one
bounded item per fresh session.
Paths repo-root-relative; Reader source = `ArchiveReader/macOS/Sources/ArchiveReader/`,
Processor source = `ArchiveProcessor/macOS/Sources/ArchiveProcessor/`.

Legend — effort S/M/L · risk low/med/high · **needs:** none | gui (drive app at runtime) | owner
(account/manual) | corpus-write (safety-sensitive).

## 🎯 Project focus & ON-HOLD areas (owner, 2026-07-09)

**Focus now:** the **wired (USB) + wireless (LAN/Wi-Fi) phone↔Mac transmission** path and the **Android**
companion — plus the core Mac pipeline (OCR/tag/PDF/finalize) and the Reader, which continue as normal.

**ON HOLD — maintain-only** (keep them compiling / mirror shared-contract changes so they don't rot, but
**no new feature development, and NOT a code-review or bug-fix target**):
- **iOS companion** — `ArchiveProcessor/ArchiveCaptureiOS/`.
- **Cloud (Google Drive) relay transport** — Mac `Net/{DriveObjectStore,DriveClient,DriveAuth}.swift` + the
  `FileRelayReceiver`/`RelayObjectStore` cloud path (incl. the offline `FileRelay` stand-in); both companions'
  `DriveRelayTransport`/`DriveAuth`/`DriveClient`. The `RelayObjectFormat` wire contract stays frozen — only
  mirror it if a focused change forces it.

*Maintain-only* means: if a protocol/SPEC change on the focus path (LAN/USB, Android) requires it, mirror the
minimum into iOS/cloud so they still build — but don't invest effort or reviews there. **Code reviews + fixes
concentrate on:** LAN transport (`Net/CaptureServer.swift`, `CaptureReceiver`, non-Drive `Net/`), USB
(`Net/USBBridge.swift`), the **Android** app (`ArchiveCapture/`), and the Mac pipeline + Reader.

## Active execution plans (`execution-plans/`)
- **`index-parallelization.md`** — parallelize + batch the Reader content-index build, **+ bm25
  relevance-ranked search + search-during-index refresh** (Reader/Core, 2026-07-09; design **verified &
  hardened** against the code by the `index-plan-verify` workflow — 4 readers + 3 adversarial reviewers;
  Tier-2, no SPEC/TagWriter change; est. ~4–8× on first-run/re-index over ~150k PDFs). **Approved
  (owner, 2026-07-09)** — checkbox under *P2 — Reader performance*. Defaults: `workers = cores − 2`,
  `synchronous = NORMAL`, WAL. *Verified gotchas folded in:* bm25 ranking is a 5-point change (SQL alone
  is a no-op — order is discarded at `ContentIndexer.search`'s `Set` wrap + `ftsPaths: Set`), full
  `optimize` must not run every pass (blocks the shared actor), and maintenance must be actor-isolated.
- **`index-pruning.md`** — prune the never-pruned content index (bound DB growth; make corpus-wide counts
  correct at source). **Approved (owner, 2026-07-09)**; do **after** `index-parallelization` (reuses its
  `existingMTimes`/batch patterns). Naive "delete paths not in `library.files`" is UNSAFE (wipes the
  index on every launch/root switch — `files=[]` fires mid-gather); ships only behind a settled +
  non-empty + two-emission-confirmed + root-scoped gate. Owner assumption: root rarely changes (so no
  per-root DB). Checkbox under *P2 — Reader performance*.
- **`decades-date-facet.md`** — NEW **decade** date facet (`1970s`) across both apps + the shared SPEC:
  Reader parses `NNNNs` → sortDate = decade start (interleaves with dated files) but the Date column still
  displays "1970s"; decades stay out of the tag cloud + tag filter. Processor authors one by typing
  "1970s" in the manual-tag **Year** field (already written verbatim → SPEC/help/tests only). **Tier-2**
  (shared SPEC + tag write path). Covers the *dates & decades* item. Owner decisions pending (italic for
  decade? Reader display-only? case strictness) — see the plan's Open questions.
- **`reader-smart-folders-scoped.md`** — smart folders as a **scoped root**: a base-scope (a held
  `SavedSearch`) distinct from user filters — selecting one shows exactly its set, **no filters render as
  "set"**, and *Clear filters* returns to the base set (not the whole root). Covers the smart-folder item.

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
- [ ] **Parallelize + batch the content-index build (+ bm25 ranked search)** — see
  `execution-plans/index-parallelization.md` (design verified against the code). *Part A (build speed):*
  bounded parallel `withTaskGroup` extraction (DB writes stay serialized through the `ContentIndex`
  actor) + batched `upsertBatch` transactions + WAL/`synchronous=NORMAL` + one-query `existingMTimes()`
  skip-map (also speeds warm reopen) + actor-isolated end-of-pass maintenance (incremental `merge` each
  pass, full `optimize` only on bulk build, then `wal_checkpoint(TRUNCATE)`). UI guard: `workers =
  cores − 2` + `.utility` QoS. *Part B:* auto-refresh the active FTS query on pass completion (mid-pass
  results under-report today). *Part C (bm25):* relevance-ranked search — a 5-point change (SQL `ORDER BY
  bm25` **+** drop the `Set` wrap in `ContentIndexer.search` **+** widen `ftsPaths` to carry rank **+**
  order `base` by rank in `recompute()` **+** a `.relevance` `LibrarySort` auto-selected while a query is
  active); **no** snippet previews (→ `POTENTIAL_FEATURES.md`). Est. ~4–8× build. **Tier-2** (actor
  isolation) — worktree + adversarial review + concurrent-extraction test on scratch PDFs (never the
  corpus). | files: Search/ContentIndex.swift, Search/ContentIndexer.swift, Views/NavigationModel.swift,
  Core/LibraryFilter.swift (+tests) | L | med · needs: none (GUI-verify relevance sort)
- [ ] **Prune the content index** — see `execution-plans/index-pruning.md`. Gated cache eviction of rows
  for files no longer under the current root (bounds DB growth; corrects corpus-wide counts at source).
  **Do after the parallelization item** (reuses `existingMTimes`/batch patterns). Ship ONLY behind the
  gate: `isGathering == false && !files.isEmpty` + absence confirmed across two post-gather emissions +
  scoped to `rootStore.root` (component-boundary, not `LIKE`) + batched deletes — a naive prune wipes the
  index on every launch/root switch. Its own gated pass, not folded into `startIndexing`. **Tier-2**
  (destructive cache op on live-query state). | files: Search/ContentIndex.swift, Search/ContentIndexer.swift,
  Views/NavigationModel.swift (+tests) | M | med · needs: none

## Owner-requested batch (2026-07-09) — Processor output + Reader UX/viewer
Captured verbatim from the owner; file hints are from the Reader/Processor Implementation Maps (verify
at implementation). Not yet scoped into execution plans — the **decades** item likely warrants one
(cross-app + SPEC). Legend as above (S/M/L · risk · needs).

### Archive Processor
- [ ] **Multi-column OCR output layout** — render the output PDF's text page in **multi-column** layout for
  newspapers / multi-column books (single-column today). Detect columns or let the user set the count;
  preserve cross-column reading order. **Tier-2** if it touches the PDF/finalize write path. | files: OCR/
  layout + PDF output/finalize | L | med · needs: gui (verify on a real multi-column source)

### Archive Reader — layout & panels
- [ ] **Adjustable + collapsible side panels** — left folder-nav column (`SidebarView`) and right tag-cloud
  column get draggable width **and** collapse/expand, each with a **keyboard shortcut** to toggle. | files:
  Views/NavigationWindowView.swift, Views/SidebarView.swift, ArchiveReaderCommands.swift | M | low
- [ ] **Add/remove columns in the file list** — user-toggled show/hide of nav-table columns (the map calls
  the table "customizable columns" — confirm what survived the AppKit swap, then wire a column picker). |
  files: Views/AppKitTableView.swift, Views/NavigationWindowView.swift | M | low
- [ ] **Make tags editable in the file list _again_** — inline tag editing (`SubjectTokenField` /
  `InlineEditCells`) **likely regressed** with the SwiftUI `Table`→AppKit `NSTableView` swap (`435b8c4`);
  those were SwiftUI cells. Re-host the inline editors in the NSTableView cell path. **Tier-2** (writes via
  `TagWriter`). | files: Views/AppKitTableView.swift, Views/SubjectTokenField.swift, Views/InlineEditCells.swift | M | med

### Archive Reader — tag cloud & filters
- [x] **No dates in the tag cloud** — exclude Year/Month/Day **and decade** facets; show subjects only
  (facet classification already exists in `DocumentTags`). | files: Views/NavigationWindowView.swift
  (tag-cloud panel), Core/DocumentTags.swift | S | low | done
- [x] **Remove date tags from the tag filter search** — months/years/decades must not appear as
  suggestions/targets in the tag filter field. | files: Views/TagFilterField.swift, Core/DocumentTags.swift | S | low | done
- [x] **Logarithmic tag-cloud sizing** — size by `log(count)` (or similar) so a 1000-count outlier doesn't
  crush the 2/10/20/100/1000 gradient into uniformly tiny text. | files: Views/NavigationWindowView.swift | S | low | done
- [ ] **Wrap (not clip) file tags in the list** — assess feasibility in the AppKit cell; **if hard → move to
  `ArchiveReader/POTENTIAL_FEATURES.md`** (owner). | files: Views/AppKitTableView.swift | S | low

### Archive Reader — dates & decades (CROSS-APP + shared SPEC)
- [ ] **Decade tags ("1970s", "1980s")** _(plan: `execution-plans/decades-date-facet.md`)_ — a NEW date facet spanning BOTH apps and the shared tag contract:
  - **SPEC first:** add the decade facet to `SPEC/tag-format.md` (both apps parse/write identically). **Tier-2.**
  - **Reader:** parse a decade tag → **sort** key = start of decade ("1970s" sorts as 1970-01-01, i.e. in
    sequence with dated files) but the **date column still displays "1970s"**, not a concrete date. | files:
    Core/DocumentTags.swift (parse / sortDate / displayDate)
  - **Processor:** let the user tag a decade by typing e.g. "1970s" into the **date field** of the tagging
    dialog. | files: Processor tagging dialog + `MacOSTagger`
  - Likely its own `execution-plans/` plan. | L | med · needs: none

### Archive Reader — search
- [ ] **Incremental (as-you-type) OCR search** — update results while typing, **debounced** (mirror the
  150 ms filter debounce) so it can't stall the UI at ~150k files; note bm25 scores the whole match set, so
  keep the per-keystroke path cheap. **If it can't be made cheap enough → `POTENTIAL_FEATURES.md`** (owner).
  | files: Views/NavigationWindowView.swift, Views/NavigationModel.swift | M | med

### Archive Reader — sort & smart folders
- [ ] **Drop the top-bar Sort button; sort via column headers** — remove the sort control; click a header to
  sort; **right-click a header to set a secondary sort**. | files: Views/NavigationWindowView.swift,
  Views/AppKitTableView.swift, Core/LibraryFilter.swift | M | low
- [ ] **Smart folders behave like a scoped root** _(plan: `execution-plans/reader-smart-folders-scoped.md`)_ — selecting a saved search shows exactly its filtered set;
  **no filters render as "set"**, and *Clear filters* returns to the smart folder's base set (not the whole
  root). | files: Search/SavedSearch.swift, Views/NavigationModel.swift, Views/SidebarView.swift,
  Core/LibraryFilter.swift | M | med

### Archive Reader — viewer & preview
- [ ] **Single-page PDF with an embedded text layer → show its text as plain text (right pane)** — in both
  the document viewer and the navigator Preview, when a PDF has selectable text but no OCR page-2, render
  that text on the right. | files: Views/DocumentViewerModel.swift, Views/DocumentWindowView.swift,
  Views/PreviewSheet.swift | M | low
- [ ] **Preview gets its own default zoom** — independent of the document viewer's persisted zoom; default
  to **full page** until the user changes it; on open, **focus the image pane** so keyboard zoom works
  immediately. | files: Views/PreviewSheet.swift, Core/AppSettings.swift | S | low
- [ ] **⌘0 = "fit full page" everywhere zoom applies** — viewer panes **and** preview. | files:
  ArchiveReaderCommands.swift, Views/PDFPaneView.swift, Views/PreviewSheet.swift | S | low
- [ ] **View non-PDFs (e.g. JPG) in the viewer** — tagged non-PDF images currently degrade; add an image
  view path so they open in the viewer + preview. | files: Views/PDFPaneView.swift (or a new image pane),
  Views/DocumentWindowView.swift, Views/PreviewSheet.swift | M | low

## P2 — Processor (KI#3 done; rest bucketed by how it can be verified)
**Done:**
- [x] KNOWN_ISSUES #3: zoomed-image scroll monitor no longer swallows scroll app-wide — scoped to the image via a hit-test-transparent probe (`ZoomableImageView.swift`); SwiftUI drag/pinch intact, no OCR/output logic touched. Build clean. ✅  ← GUI-verify (zoom a page >100%, confirm the filmstrip scrolls).

**Heads-down doable now (macOS, build-verifiable, NOT phone-gated):**
- [x] **[A1 — SHIPPED; owner-gated live-verify remains]** **Owner-requested (2026-07-07): bring the Live Capture Processing pane up to the Process Files "Files" pane's level of detail — on shared central code.** Today the Processing pane in Live Capture is too sparse: when a document **fails OCR the user gets no reason**, and there's **no way to (re)process just one or two files**. It should show the same per-file detail as the Process Files "Files" pane (status, OCR text/error reason, per-file actions) and offer the same **granular fallback/retry options** (retry a single file, change model/rotation and re-run, etc.). The pane likely needs to be **larger** to fit this. **DRY — don't invent it twice:** factor the Process Files file-list + row + per-file action UI into a **shared component** so both the Process Files pane and the Live Capture Processing pane render from one central source, rather than two parallel implementations. Mostly build-verifiable; verify the failure/retry paths in a live run. **Tier-2** if it touches the finalize/retry write path. | files: Views/OCRView.swift (+OCRView+*), Views/LiveCaptureView.swift, Capture/LiveCaptureProcessor.swift, new shared row/pane component | L | med
  - **Progress (2026-07-07, A1 design `.maintenance/A1-shared-pane-design.md` steps 1–9):** SHIPPED — shared `Views/Shared/{ProcessableItem,ProcessableItemRow,ProcessableItemListView,ModelChoiceView}.swift`; Files pane adopts it (`FileItem` adapter, identical render); Live pane fully adopts it (`SegmentItem` adapter, reasons + per-item retry / retry-with-model / rotate-&-re-run / view-text / reveal + grown scrollable box); `LiveCaptureProcessor.retryFailed(groupIds:override:)` generalized (G1 = all-failed footer); failure taxonomy un-conflated (`succeededNoText` for filed image-only docs — labeling only, deletion path untouched); `OCRProcessor.retryOne(...)` extracted. Builds clean, no new warnings. **Files pane inline-disclosure action UI shipped** (overnight, commit `d068a99`): tap-to-expand rows surface retry / retry-with-model / rotate-&-re-run / view-text / reclassify via `OCRProcessor.retryOne(...)` + `ModelChoiceSheet` + `FileTextViewerSheet`; review-mode keyboard/tap gestures preserved (expand only outside review mode). `.fileAsImageOnly` not surfaced (auto-files via `succeededNoText`). **REMAINING:** live-run GUI verification of the new reasons/retry paths (owner-gated).
- [x] **shipped `f1d2263`, suite-v1.2.0** — Behavior-preserving de-dups (audit `wf_4373722d-e70`): shared text-completion client; finalize/organize helpers; box/folder color-retag; small cluster (`highestLeadingNumber`, `monthTag`, `acceptedImageExtensions`, `GatewayConfig.fromDefaults`, `liveProcessingMode`); reconcile iOS(5)/Android(6) recent-years cap. | M | low
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
  - *(`ArchiveCore` shared-package extraction moved to `ArchiveProcessor/POTENTIAL_FEATURES.md` — deferred, 2026-07-08.)*

## Flagged — need the owner present / GUI / a scratch-corpus write
- [x] **GUI-verified 2026-07-08 (owner-driven, on the AR-Smoke scratch corpus, checked at the on-disk xattr level):** Reader inline tag-editor commit — Return-commit ✓, blur-commit of a completed token ✓. Found the half-typed-fragment case *dropped* the word (the documented no-lost-tag safety) yet left a misleading phantom chip; owner chose **WYSIWYG** instead, so `SubjectTokenField` now commits the field's tokens on blur (typed text sticks). Adds route through `TagWriter` (no tag loss); Tier-2 APPROVE. | files: Views/SubjectTokenField.swift | done
- [x] **Perf-checked the nav Table 2026-07-08 (owner-driven GUI, 40k synthetic scratch corpus): the SwiftUI `Table` JANKS at scale.** Scroll stutters; filter-box *keystrokes* lag + can beachball (per keystroke it re-filters 40k AND re-diffs the whole Table on the main thread); sort is slow. Discovery/load of 40k was fine — it's the Table view layer. At the ~150k production target this would be worse. → spawned the follow-up below.
- [x] **Reader: swap the nav SwiftUI `Table` → AppKit `NSTableView`** — `AppKitTableView.swift` (`NSViewRepresentable` wrapping `NSScrollView`+`NSTableView` with `NSTableViewDiffableDataSource`): virtualized rows + cell reuse (fixes scroll); incremental snapshot apply (fixes sort); debounced `filterSearchText` (150 ms, fixes the typing beachball). `ContextMenuTableView` subclass for right-click menu; `ContextMenuActions` trampoline bridges NSMenu items to `NavigationModel`. Model + `TagWriter` untouched (no data-safety surface). Build clean, 161 tests green. **Full GUI re-verify deferred → Morning Review (owner-gated).** ✅
- [x] Remove stray `InlineTest` tag on the SCRATCH corpus — **N/A: scratch corpus (`AR-Smoke/Batch-A/00001`) no longer exists on disk** (directory empty, file cleaned up). No action needed. ✅

## Excluded (not "now": need cost / owner accounts)
- Processor Tier-1 `test-smoke.sh` / Tier-2 `test-tier2.sh` (real OCR → keys + API cost); Processor App-Store/Play Phase 4 (owner accounts/assets); Reader cloud-drive support; Reader creation-date-mirror (would write metadata onto the real corpus).
  - [x] **G5 — cheap Tier-1 smoke gate shipped (2026-07-07).** New Suite-root `./test-smoke.sh processor|reader|all` (mirrors `launch.sh`) → `ArchiveReader/test-smoke.sh` (build + full unit suite, **135 tests, free**) + `ArchiveProcessor/test-smoke.sh` (headless **2-image** OCR via `ProcessFilesTestDriver`, `gemini-2.5-flash-lite`, ~a few cents, `mktemp` scratch-isolated, key never printed). Distinct from the cost-heavy `scripts/test-smoke.sh` (raw per-provider calls) + `scripts/test-tier2.sh` (multi-case pipeline) above. Both verified PASS. ✅
