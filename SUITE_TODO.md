# Archive Suite — working to-do queue

Actionable backlog we can pick up now (network restored 2026-07-06). Harvested from both apps'
`KNOWN_ISSUES`/`POTENTIAL_FEATURES`/`NEXT_STEPS`/UI docs + the merge follow-ups, deduped and classified.
Heavy overnight audit is tracked separately in `.maintenance/OVERNIGHT_QUEUE.md`; the full merge/publish
record is in `SUITE_MERGE_PLAN.md`. Paths are repo-root-relative; Reader source =
`ArchiveReader/ArchiveReader/Sources/ArchiveReader/`, Processor source =
`ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/`.

Legend — effort S/M/L · risk low/med/high · **needs:** none | gui (drive app at runtime) | owner
(account/manual) | corpus-write (safety-sensitive).

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
- [ ] Processor: re-add "Import tag vocabulary from CSV" (`loadTagVocabularyFromURL` + file picker + drop target) — pure local, no API. | files: Processor Views/vocabulary editor, Tagging/ | S | low
- [ ] Processor: bump Android `targetSdk` 34→36 (mandatory ~2026-08-31 for Play updates). | files: ArchiveCapture/app/build.gradle.kts | S | low
- [ ] Reconcile Bonjour service name mismatch (iOS `_archiveproc._tcp` vs Mac `_archivecap._tcp`) before any mDNS work. | files: companions + Processor Net/ | S | low

## P2 — Reader features (no network; local build/test)
- [ ] Non-standard-PDF **detection layer** (non-2-page / no-OCR-layer / corrupt / non-PDF) — land this first; the next three consume it. | files: Views/NavigationModel.swift, Search/PDFTextExtractor.swift, Search/ContentIndexer.swift | S | low
- [ ] Surface it: counts in a Library-Health popover · "Non-standard format" filter chip + "Needs attention" smart folder · per-row warning badge · viewer banner ("1 page · no OCR text layer"). | files: Core/LibraryFilter.swift, Search/SavedSearch.swift, Views/NavigationWindowView.swift, Views/DocumentWindowView.swift | S–M | low
- [ ] Tag near-duplicate detection (e.g. `Environment` vs `Environtment`) — read-only analysis; rename already ships via TagWriter. | files: Views/NavigationModel.swift, new view | M | low
- [ ] Duplicate-filename disambiguation — show containing folder/box for same-named files. | files: Views/NavigationModel.swift, Views/NavigationWindowView.swift | S | low
- [ ] Side-by-side compare of two selected documents (beyond ↑/↓ cycling). | files: Views/DocumentWindowView.swift, new view | L | low

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
