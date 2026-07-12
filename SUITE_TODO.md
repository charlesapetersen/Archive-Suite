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
- `local-agent-cli-provider.md` — **PROPOSED** (Processor): drive OCR/tagging through a locally installed,
  subscription-authenticated CLI — **Claude Code + Gemini CLI + OpenAI Codex CLI**, all first-class — for
  enterprise Claude / Gemini / ChatGPT(Edu) accounts with no API key. No key stored; auth lives in each
  CLI's login. Additive `localAgent` config sibling to the gateway (append-only, keeps resume-critical
  snapshots unchanged). Tier-2. Claude path validated on-machine 2026-07-10.
- `openai-chatgpt-provider.md` — **PROPOSED** (Processor): add OpenAI/ChatGPT as a first-class provider via
  (1) the **standard API** (native `LLMProvider.openai`, BYO OpenAI API key) and (2) an **OpenAI gateway
  preset** (turnkey config over the existing OpenAI-compatible gateway). Reuses `OpenAICompatibleClient`
  (already speaks OpenAI's format). The **API-key** counterpart to the CLI plan's subscription path. Tier-1
  + live OCR test.
- **`archive-notes/`** — **PROPOSED** (NEW APP): a third native macOS app, **Archive Notes** —
  provenance-first note-taking from archival PDFs (via Reader) + Zotero, at 100k-note / 2M-word scale.
  Markdown+assets files (title=filename, UUID-folder identity), YAML front-matter metadata (no tag
  pollution), purely-virtual folders + replication, WYSIWYG-over-Markdown editor, durable cross-app links
  (root-marker + relative path; `archivereader://reveal` + `archivenotes://open`), extracts, templates.
  Master plan + 8 wave plans live in `execution-plans/archive-notes/` (`00-overview.md` §16 = the
  **authoritative interface contract**). Built over a long unattended run. See the **Archive Notes** queue below.
- ~~`index-parallelization.md`~~ — **SHIPPED** (parallel+batched index build + bm25 ranked search +
  search-during-index refresh). Plan deleted.
- ~~`index-pruning.md`~~ — **SHIPPED** (gated content-index pruning). Plan deleted.
- ~~`decades-date-facet.md`~~ — **SHIPPED** (decade date facet). Plan deleted.
- ~~`reader-smart-folders-scoped.md`~~ — **SHIPPED** (smart folders as scoped root). Plan deleted.
- ~~`reader-gui-test-harness.md`~~ — **SHIPPED** (W7.1–W7.5). XCUITest target, accessibilityIdentifiers,
  DEBUG-gated fixture-root override, `make-gui-fixture.sh`, initial test suite (navigation, tag cloud,
  viewer, preview, filter, sort, degrade). Plan deleted.

## Archive Notes — NEW APP (planned 2026-07-10; `execution-plans/archive-notes/`)
Owner-specced third Suite app; foundational decisions locked (D1–D10, `00-overview.md §2`). Each wave maps to
one or more bounded autonomous sessions (sub-tasks listed inside each wave file). DevonThink informs **only**
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
  (S1 `7cddf60` → S2 `254fd73` → S3 `91c3c45` → S4 `220b582` → S5 docs)
- [x] **W2** store + front-matter I/O + virtual folders/replication + FTS5 index — `02-storage-model-and-index.md` — Tier-2 (writers)
  (S1 `64eaa9c` → S2 `02201f0` → S3 `2404852` → S4 `afd06c7` → S5 org graph + organization.json)
- [x] **W3** rich-text/Markdown editor (WYSIWYG + raw toggle, inline images) — `03-rich-text-markdown-editor.md` — Tier-1
  (S1 `0db7f61` → S2 `16e0f43` → S3 `1f740b3` → S4 `2261b1f` → S5 `78a9fb5` → S6 perf+cache+tests)
- [x] **W4** source blocks + page thumbnails + Reader URL scheme/reveal + durable links — `04-sources-and-cross-app-linking.md` — Tier-2 (Reader deep-link)
  (S1 `0b7b89d` → S2 `8a7012c` → S3 `1e81b71` → S4 `f477f3a` → S5 `15c690c` → S6 `0ddf88e` → S7 reveal+preview)
- [ ] **W5** Zotero metadata / citations / chips — `05-zotero-integration.md` — Tier-1
- [ ] **W6** viewers + search/filter/sort + replication UI + templates + dates/quality — `06-viewers-search-replication.md` — Tier-2 (delete path)
- [ ] **W7** extracts (snapshot + provenance, blocks→notes, jump-to-source) — `07-extracts.md` — Tier-1
- [ ] **W8** tests + XCUITest/cliclick GUI harness (scratch corpus) — `08-testing-and-gui-verification.md` — Tier-1
- [ ] **(later)** behavior/data follow-ons (W0 already unified the *code*): Reader parses/**hides** `ArchiveSuite` in-UI; corpus **back-fill** + Processor **stamping**; unified suite storage path — Tier-2, separately gated

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
- [x] **Reader GUI test harness (XCUITest)** — W7.1–W7.5 shipped. XCUITest target + accessibilityIdentifiers + fixture-root override + make-gui-fixture.sh + initial test suite (12 tests: table, tag cloud, sort, filter, preview, viewer, degrade). | L | med

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
