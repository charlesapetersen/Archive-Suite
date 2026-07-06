# Archive Suite — working to-do queue

Actionable backlog we can pick up now (network restored 2026-07-06). Harvested from both apps'
`KNOWN_ISSUES`/`POTENTIAL_FEATURES`/`NEXT_STEPS`/UI docs + the merge follow-ups, deduped and classified.
Heavy overnight audit is tracked separately in `.maintenance/OVERNIGHT_QUEUE.md`; the full merge/publish
record is in `SUITE_MERGE_PLAN.md`. Paths are repo-root-relative; Reader source =
`ArchiveReader/ArchiveReader/Sources/ArchiveReader/`, Processor source =
`ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/`.

Legend — effort S/M/L · risk low/med/high · **needs:** none | gui (drive app at runtime) | owner
(account/manual) | corpus-write (safety-sensitive).

## ⚑ Document-viewer bugs (owner-reported 2026-07-06) — round-2 fixes, awaiting owner GUI-verify
Reader document window (`DocumentWindowView`, `DocumentViewerModel`, `PDFPaneView`, `AppSettings`, `ArchiveReaderApp`). Commit `78ec228`; 130 tests green. Round 1 (`08e59bb`) was insufficient per owner testing; round 2 below.
- [x] **DV-1 Open maximized + remember size + no flash.** `.defaultSize` opens at the remembered-or-screen size (no post-show resize flash); size persisted **on window close** (`onDisappear`) and restored on open. (Round 1's `setFrameAutosaveName` didn't persist under WindowGroup.) ← GUI-verify.
- [x] **DV-2 Persist zoom + split across cycling, and as the next-open default.** Split persisted on drag-end; per-pane zoom held on the controller + persisted on zoom; both reapplied on open (become defaults). ← GUI-verify.
- [x] **DV-2b Top-anchored zoom.** `scrollToTop` lays out the doc view then pins the page's top-left, so the top line stays at the top as you zoom. ← GUI-verify.
- [x] **DV-3 Text selection after cycling (real fix).** Each page now gets a **fresh `PDFView`** (`.id(index)`) — a reused view lost selection after a document swap; a fresh view is the known-good first-show state. Zoom survives via the controller. (Round 1's clearSelection+relayout did NOT fix it — confirmed by owner.) ← GUI-verify.

## P0 — Finish the Suite publish (network back)
- [x] Push merged history: `main` + `suite-v1.0.0` pushed to `origin` (0 diverged). ✅ 2026-07-06
- [x] Publish release: `suite-v1.0.0` LIVE with `ArchiveSuite-1.0.0.dmg` (4.48 MB) attached. ✅
- [x] Verify online: release published, asset `uploaded`; `origin/main` == locally build-verified tree. ✅
- [x] **Phase F DONE** — redirect banner pushed to the old `archiveprocessor` README; repo **archived** (read-only, `isArchived=true`). ✅ 2026-07-06

## P1 — Quick local wins (S, low-risk, no network)
- [x] Cite `SPEC/tag-format.md` as the shared-contract source of truth from BOTH per-app `CLAUDE.md`. ✅
- [x] Reconcile Reader `CLAUDE.md` prose to SPEC (doc-only; code already correct): page-2 line verbatim/any-ext/may-be-absent; Year 3–4 digits; BC note clarified; Box/Folder/OCR-Failed subjects noted. ✅
- [x] Regression test: `Box`/`Folder`/`OCR Failed` classify as plain subjects (SPEC #3) — added; **110 tests green**. ✅
- [x] Close stale checkbox: `PLAN_NEAR_TERM_UI` **E3** confirmed shipped & ticked. ✅
- [x] Processor: "Import tag vocabulary from CSV" — added `Import from CSV…` button + file drop target on the vocabulary editor (`SettingsView.swift`; NSOpenPanel + newline/comma parse, de-dupe). macOS build green, no new warnings. ✅
- [ ] **BLOCKED (not a quick win):** bump Android `targetSdk` 34→36. AGP is **8.6.1 / Gradle 8.9**, which can't compile `compileSdk 36` (needs AGP ≥8.9); also **no Android SDK/toolchain on this machine**. Requires: upgrade AGP+Gradle, install the API-36 platform, bump compile+targetSdk, then a build + on-device smoke for Android 15/16 behavior changes. Do in an Android-capable session before the ~2026-08-31 Play deadline. | files: ArchiveCapture/ (build.gradle.kts, gradle wrapper) | M | med
- [x] Reconcile Bonjour service-name mismatch — iOS now advertises `_archivecap._tcp` (matches the Mac) in both `ArchiveCaptureiOS/project.yml` + generated `Info.plist`; iOS project regenerates clean. ✅

## P2 — Reader features (no network; local build/test)
- [x] Non-standard-PDF **detection layer** — `Core/PDFFormatStatus.swift` (standard/unreadable/noTextLayer; page count is NOT a defect signal — merged >2-page PDFs are legit); persisted in the v2 content index. **117 tests green, lint clean.** ✅
- [x] Surface it — filter-bar "N need attention" toggle (`needsAttentionOnly` filter), health-popover row, per-row ⚠ badge. ✅  *(Remaining small piece: the two-up viewer banner in `DocumentWindowView` — "no OCR text layer" — not yet done.)*
- [x] Viewer banner for image-only docs ("no OCR text layer") in the document window — build green. ✅
- [x] Tag near-duplicate detection — `Core/TagSimilarity.swift` (union-find + length-scaled Levenshtein) + `SimilarTagsSheet` review UI (Merge drives the existing audited rename). 130 tests green, lint clean. ✅
- [ ] Duplicate-filename disambiguation — show containing folder/box for same-named files. | files: Views/NavigationModel.swift, Views/NavigationWindowView.swift | S | low
- ~~Side-by-side compare of two selected documents~~ — **dropped (owner: not doing this), 2026-07-06.**

## P2 — Processor (implement now; some need a phone/OCR run to fully verify)
- [ ] Live Capture connectivity UX (P1): legible Wi-Fi failure + reachability preflight + fix Android QR-analyzer latching. Offline-testable with the 192.0.2.1 / closed-port / wrong-token triad. | files: Net/CaptureServer.swift, Net/USBBridge.swift, companions | M | med
- [ ] Keep OCR/progress live while the per-segment tag card is open (looks hung today). | files: Views/LiveCaptureView.swift | S | low
- [ ] Re-pair coordination: auto re-show QR on phone re-pair; split "listening" vs "connected"; verify USBBridge re-runs `adb reverse`. | files: Net/CaptureServer.swift, Net/USBBridge.swift, Views/LiveCaptureView.swift, companions | M | med
- [ ] Output-folder picker in the Live Capture pane (+`?` help + gray-out); unify with Process Files `outputDirectory`. | files: Views/LiveCaptureView.swift, Capture/ | M | low
- [ ] Streaming residuals: defer segment-complete until all pages *uploaded*; `needsResend` for P10/reclassify in-flight; persist `completedDocGroups` across Mac restart. | files: Capture/LiveCaptureProcessor.swift, companions | M | med
- [ ] KNOWN_ISSUES #2: merged multi-page docs leave exported originals loose — thread per-page image URLs into `organizeOutput` (Tier-2, file-move path). | files: OCR/CollectionSegmenter.swift, Capture/LiveCaptureProcessor.swift | M | med
- [ ] KNOWN_ISSUES #3: zoomed-image scroll monitor swallows scroll app-wide — replace with a hosted NSView `scrollWheel` override. | files: Views/ZoomableImageView | M | low
- [ ] Behavior-preserving de-dups (per audit `wf_4373722d-e70`): shared text-completion client; shared finalize/organize helpers; unify box/folder color-retag; small cluster (`highestLeadingNumber`, `monthTag`, `acceptedImageExtensions`, `GatewayConfig.fromDefaults`, `liveProcessingMode`); reconcile iOS(5)/Android(6) recent-years cap. | files: Processor {OCR,Tagging,Capture,Models,Views}, companions | M | low
- [ ] No-API local features: processing profiles/presets + main-window global shortcuts (start / switch provider). | files: Views/SettingsView.swift, Views/OCRView.swift, new store | M | low

## P3 — Suite structural
- [ ] Add a tight Implementation Map to Processor's `CLAUDE.md` (Reader has one; Processor lacks it — token-efficiency directive C.7). | files: ArchiveProcessor/CLAUDE.md | M | low
- [ ] De-nest per app (do AFTER the P0 upload, build-verify each): `git mv <App>/<App> <App>/macOS`, update `launch.sh` `APPDIR` + `.gitignore`/doc paths + (Processor) `scripts/test-*.sh`; schemes/bundle IDs unchanged. | files: ArchiveReader/, ArchiveProcessor/ | M | med
- [ ] (Long-term / Phase G) Extract shared UI-free `ArchiveCore` SPM package so Reader `TagWriter` + Processor `MacOSTagger` can't drift; largely supersedes the "cite the spec"/drift items. | files: new ArchiveCore/, both project.yml | L | med

## Flagged — need the owner present / GUI / a scratch-corpus write
- [ ] GUI-verify Reader inline tag editor blur-vs-Return commit (synthetic input can't drive SwiftUI text fields). | files: Views/InlineEditCells.swift, Views/TagFilterField.swift | S | needs: owner
- [ ] Perf-check the nav Table at ~150k (synthetic scratch corpus; AppKit swap already possible). | files: Views/NavigationWindowView.swift, scripts/smoke-setup.sh | M | needs: gui
- [ ] Remove stray `InlineTest` tag on the SCRATCH corpus `~/Library/Application Support/ArchiveReader/AR-Smoke/Batch-A/00001` (scratch copy, NOT `Test files/`) — via TagWriter/xattr on the scratch copy only. | S | needs: corpus-write

## Excluded (not "now": need cost / owner accounts)
- Processor Tier-1 `test-smoke.sh` / Tier-2 `test-tier2.sh` (real OCR → keys + API cost); Processor App-Store/Play Phase 4 (owner accounts/assets); Reader cloud-drive support; Reader creation-date-mirror (would write metadata onto the real corpus).
