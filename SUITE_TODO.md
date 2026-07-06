# Archive Suite — working to-do queue

Actionable backlog we can pick up now (network restored 2026-07-06). Harvested from both apps'
`KNOWN_ISSUES`/`POTENTIAL_FEATURES`/`NEXT_STEPS`/UI docs + the merge follow-ups, deduped and classified.
Heavy overnight audit is tracked separately in `.maintenance/OVERNIGHT_QUEUE.md`; the full merge/publish
record is in `docs/archive/SUITE_MERGE_PLAN.md`. Paths are repo-root-relative; Reader source =
`ArchiveReader/ArchiveReader/Sources/ArchiveReader/`, Processor source =
`ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/`.

Legend — effort S/M/L · risk low/med/high · **needs:** none | gui (drive app at runtime) | owner
(account/manual) | corpus-write (safety-sensitive).

## ⚑ Document-viewer bugs (owner-reported 2026-07-06) — round-2 fixes, awaiting owner GUI-verify
Reader document window (`DocumentWindowView`, `DocumentViewerModel`, `PDFPaneView`, `AppSettings`, `ArchiveReaderApp`). Commit `78ec228`; 130 tests green. Round 1 (`08e59bb`) was insufficient per owner testing; round 2 below.
- [x] **DV-1 Open maximized + remember size + no flash.** `.defaultSize` opens at the remembered-or-screen size (no post-show resize flash); size persisted **on window close** (`onDisappear`) and restored on open. (Round 1's `setFrameAutosaveName` didn't persist under WindowGroup.) ← GUI-verify.
- [x] **DV-3 Text selection after cycling.** Fresh `PDFView` per page (`.id(index)`). ✅ **Owner-confirmed working.**
- [x] Splitter width persists across cycling + as the next-open default. ✅ **Owner-confirmed.**
- [~] **DV-2 zoom persistence (round 3).** Round 2 only caught toolbar/keyboard zoom; trackpad **pinch** bypassed it, so zoom didn't persist. Round 3 (`d4eedba`): observe `PDFViewScaleChanged` → capture ANY zoom method → persist per pane → reapply to each fresh page + as default. ← RE-VERIFY (incl. pinch).
- [~] **DV-2b top-anchored zoom (round 3).** Now pins the page top on every scale change, after layout, + a deferred second scroll (was anchoring on stale pre-zoom geometry). ← RE-VERIFY.
- [~] **DV-1 flash (round 3).** `.defaultSize` now driven by `@AppStorage` so it tracks the remembered size → window opens at the right size instead of resizing after show. (Owner saw no flash only when remembered≈full-screen — confirmed the stale-defaultSize cause.) ← RE-VERIFY the shrink-then-reopen case.

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
- [x] Surface it — filter-bar "N need attention" toggle (`needsAttentionOnly` filter), health-popover row, per-row ⚠ badge. ✅
- [x] Viewer banner for image-only docs ("no OCR text layer") in the document window — build green. ✅
- [x] Tag near-duplicate detection — `Core/TagSimilarity.swift` (union-find + length-scaled Levenshtein) + `SimilarTagsSheet` review UI (Merge drives the existing audited rename). 130 tests green, lint clean. ✅
- [x] Duplicate-filename disambiguation — `Core/DuplicateNames.swift` + a dimmed containing-folder subtitle for rows sharing a base name. 135 tests green, lint clean. ✅
- ~~Side-by-side compare of two selected documents~~ — **dropped (owner: not doing this), 2026-07-06.**

**→ Reader P2 is COMPLETE** (non-standard-PDF cluster · tag near-duplicate finder · document-viewer bugs · dup-filename; side-by-side dropped).

## P2 — Processor (KI#3 done; rest bucketed by how it can be verified)
**Done:**
- [x] KNOWN_ISSUES #3: zoomed-image scroll monitor no longer swallows scroll app-wide — scoped to the image via a hit-test-transparent probe (`ZoomableImageView.swift`); SwiftUI drag/pinch intact, no OCR/output logic touched. Build clean. ✅  ← GUI-verify (zoom a page >100%, confirm the filmstrip scrolls).

**Heads-down doable now (macOS, build-verifiable, NOT phone-gated):**
- [ ] Behavior-preserving de-dups (audit `wf_4373722d-e70`): shared text-completion client; finalize/organize helpers; box/folder color-retag; small cluster (`highestLeadingNumber`, `monthTag`, `acceptedImageExtensions`, `GatewayConfig.fromDefaults`, `liveProcessingMode`); reconcile iOS(5)/Android(6) recent-years cap. | M | low
- [ ] No-API local features: processing profiles/presets + main-window global shortcuts (start / switch provider). | Views/SettingsView.swift, Views/OCRView.swift, new store | M | low
- [ ] Output-folder picker in the Live Capture pane (+`?` help + gray-out); unify with Process Files `outputDirectory`. **Tier-2** (output path) — add the picker + wire the EXISTING setting; don't change write/move logic. | M | low
- [ ] Connectivity UX — the macOS legible-Wi-Fi-failure + reachability-preflight parts (offline-testable via the 192.0.2.1 / closed-port / wrong-token triad). *Android QR-analyzer latch fix is device-gated (below).* | Net/CaptureServer.swift, Net/USBBridge.swift | M | med

**Live-session / phone-gated (drive Live Capture — ideally a paired phone — to verify; do interactively, like the viewer bugs):**
- [ ] Keep OCR/progress live while the per-segment tag card is open (looks hung today). | Views/LiveCaptureView.swift | S
- [ ] Re-pair coordination: auto re-show QR on phone re-pair; split "listening" vs "connected"; verify USBBridge re-runs `adb reverse`. | Net/, Views/LiveCaptureView.swift, companions | M
- [ ] Streaming residuals: defer segment-complete until all pages *uploaded*; `needsResend` for P10/reclassify in-flight; persist `completedDocGroups` across Mac restart. | Capture/LiveCaptureProcessor.swift, companions | M
- [ ] KNOWN_ISSUES #2: merged multi-page docs leave exported originals loose — thread per-page image URLs into `organizeOutput`. **Tier-2 file-move**; needs a live pipeline run. | OCR/CollectionSegmenter.swift, Capture/LiveCaptureProcessor.swift | M

> **⚠️ PENDING INTEGRATION — do not clobber.** The standalone clone `~/Desktop/Claude/Archive Processor`
> has unmerged work by another Claude instance: branch `feat/live-capture-cloud-transport` (`9c4334a` —
> consolidate Live Capture to USB + Google-Drive cloud transport + a cloud plan) + an uncommitted `CLAUDE.md`.
> **Plan (owner, 2026-07-06):** once that instance finishes, bring the branch into the monorepo (relocate its
> files under `ArchiveProcessor/`, land on a review branch), then retire the clone. Likely supersedes/feeds
> the "connectivity UX" item above.

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
