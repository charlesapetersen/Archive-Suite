# Archive Processor — Settings Redesign Proposal (`W49.proc-ui-design-review`)

**Date:** 2026-11-25 · **Baseline:** `main` @ `6d367a1e`  
**Owner Gate:** `W49.proc-settings-design-ok` — **APPROVED 2026-11-25: Option B** (Preset-First 5-Tab Settings + Unified `ResolvedRunConfig` + Optional Advanced Advisor)  
**Scope:** Archive Processor macOS Settings (`⌘,`) and its single underlying run-configuration model (`ResolvedRunConfig`). Process Files, Live Capture, and review dialogs stay out of scope except where duplicate settings controls are removed and both runners read from `ResolvedRunConfig`.

---

## 1. Executive Summary & Decision for `W49.proc-settings-design-ok`

### What happens today
Opening Settings (`⌘,`) in Archive Processor currently shows an **8-tab window** (`General`, `Collection`, `Reading`, `Documents`, `Dates and names`, `Pages and output`, `Capture`, `Accounts`) controlled by a global **Basic / Standard / Advanced** level switch, paired with two long modal interviews (`GeneralInterviewView`, `CollectionInterviewView`) and a separate 3-tab modal Settings Sheet (`Choices`, `Range`, `Rules`).

Underneath that UI, Settings is **split in two**:
1. **A layered benchmark advisor** (`SettingsLayers` / `SettingsSolver` / `SettingsSheetModel`) that computes "the app's pick" per collection and prints multi-paragraph benchmark explanations on stage cards.
2. **76 legacy app-wide `@AppStorage` keys** (`198` bindings across `Views/`) that actually control what Process Files and Live Capture run.

Because those two worlds are disconnected, the Reading card can tell you *"The app's pick: Apple Vision (built in)"* while the line directly underneath says *"Not switched on yet: Process Files now reads with Gemini 3.8 Flash. 'Read with this' switches it on"* — and clicking *"Read with this"* changes an app-wide global setting for every collection. Meanwhile, three overlapping runtime config structures (`SessionProcessingConfig`, `PendingRun`/`PendingRunRuntimeConfig`/`PendingBatch`, and `ResolvedSettingsSnapshot`) duplicate the same knobs across Process Files, Batch, Resume, and Live Capture.

### What was decided before, and what changed
- **Nov 4, 2026 (`12-settings-design.md`):** You chose the interactive **Shape-A** workbench concept (limits at the top driving per-stage cards, Pareto range charts one tab away, live General → Project → Collection inheritance saved in `<output>/.archivesuite/collection-settings.json`, and 4 starting points).
- **Nov 19, 2026 (`levels.md`, Owner Calls 15–16):** To keep lower-scoring/experimental options accessible without cluttering defaults (Call 13/15), the Settings window was split into **8 toolbar panels** and **3 global levels (Basic / Standard / Advanced)** — placing the Shape-A stage cards *above* the legacy backend, model, and segmentation controls rather than replacing them.
- **Nov 24, 2026 (`W49.proc-pipeline-prune-ok` & re-scoping):**
  - You rejected the 8-tab Settings UI and asked for a **Settings-only redesign proposal** before any further hands-on walkthrough (`W40.g3`).
  - You approved **six pipeline simplifications** (`execution-plans/processing-review/13-stage-rules/14-owner-calls.md` §3; applied by W49.proc-pipeline-prune-apply): (1) `hand-blla-ctc` handwriting placer defaults OFF in Advanced; (2) per-kind OCR simplifies to one clean **2-way split (Typed/Printed vs. Handwriting)** for both Mac and Cloud, dropping the 4-way matrix and deferring mixed-page switching to 2.0; (3) the app's bundled `settings-routes.json` drops the 91 unwired (`app_route: null`) bench rows (ArchiveOCRBench keeps all 118+ rows); (4) practical-floor-only tie rules (`0.5` NES Reading, `2.0` pts Segmentation); (5) a collection-level numeric date-order setting (`MM/DD` US vs. `DD/MM` International); and (6) rotation fallback uses the configured OCR model.
  - `W49.proc-local-model-supervisor` shipped (one unified local-model runtime) and `W49.proc-managed-local-ocr` + `W49.proc-local-ocr-onboarding` are queued to download and manage local OCR models directly in-app.

### Why this choice matters now
Before any Settings implementation or `W40.g3` walkthrough begins, we need to lock **which Settings model Processor should build**:

| Dimension | Option A: Restored Unified Shape-A Workbench | Option B (Recommended): Preset-First Clean Settings + Optional Advisor |
|---|---|---|
| **Primary mental model** | Constraint solver first: set spending ceiling, hours, priority weights, and document mix → solver picks all 4 stages | Workflow first: pick one of **4 clear starting workflows** (Fast & Free Mac / High-Accuracy Local / Cloud / Cluster) and adjust 4 direct one-row pickers |
| **Window shape** | Wide 2-column workbench (~1,020 × 720 pt) + 2 extra tabs for Output/Capture & Accounts/Advanced | Calm **5-tab native macOS Settings** (`Processing`, `Output`, `Capture`, `Accounts`, `Advanced`), fixed ~660 × 620 pt |
| **Benchmark charts & solver** | Always the main screen | One click away (**"Compare routes & trade-offs…"** Advisor sheet) with pruned runnable routes and one-click Apply |
| **Legacy controls** | Legacy pickers deleted; solver overrides directly write `ResolvedRunConfig` | Legacy stacked cards, 8-tab panels, and 3-level gate deleted; direct pickers write `ResolvedRunConfig` |
| **Per-collection inheritance** | Preserved (`collection-settings.json`, General → Project → Collection) | Preserved (`collection-settings.json`, General → Project → Collection) via a top scope bar on `Processing` |
| **Lower-scoring / experimental controls (Call 15)** | In an Advanced toggle/tab | Dedicated **`Advanced`** tab with factual 1-line notes + an `"N Advanced overrides active"` banner on `Processing` |
| **Everyday friction** | Higher: changing a model or trying a new local model means fighting or overriding solver constraints | Lowest: 1 click to switch workflow or reader; zero prose walls; zero split-brain |

**Recommendation: Option B (Preset-First Clean Settings + Unified `ResolvedRunConfig` + Optional Advanced Advisor).**  
It gives historians an immediately legible macOS Settings window (matching the calm style of Archive Reader and Archive Notes), deletes the stacked duplicate controls and 3-way config drift at the root, keeps every single Call 15 / Call 13 feature accessible in `Advanced`, and still preserves the full Shape-A Pareto frontier and per-kind benchmark advisor one click away for anyone comparing cost vs. accuracy.

**What priority would favour Option A:** Pick **Option A** if you want every user to configure Processor primarily by entering a dollar budget, hour limit, and document-kind percentages and letting the mathematical solver allocate models across stages on the main Settings screen itself, rather than choosing a workflow/reader directly and consulting the solver when comparing trade-offs.

---

## 2. Visual & Architectural Audit of Current Settings (`main` @ `6d367a1e`)

> **Verification note:** A live Tart VM run was queued behind the active `W46.ocr-gemma3-12b` benchmark holding `mac-heavy-lock`, so visual inspection examined all 16 off-screen VM screenshots in `~/.tart-mirror/vm-artifacts/processor/shots-attempt1/` (`settings-panel-*.png`, `settings-level-*.png`, `settings-panel-see-the-range.png`), cross-checked against every Settings commit since Nov 21 — notably `fd25093c` (`W40.fix-processor-reading-scan`, which collapsed Reading's figures under a disclosure) and `e5926a28` (`W40.fix-processor-general-padding`, raising General's height from 220 to 272 pt).

### 2.1 Measured Footprint Today
- **8 toolbar panels** (`SettingsView.swift`, fixed `720 pt` width, jumping between `272`, `560`, and `660 pt` height).
- **76 `DefaultsKeys` constants** (`Models/DefaultsKeys.swift`), bound across **198 `@AppStorage` properties** in `Views/`.
- **32 layered `SettingsKey` entries** (`10 generalOnly` + `22 anyLayer`) plus `override.<stage>.all` (`SettingsLayers.swift`).
- **48 `SettingsLevels.Row` entries** across Basic / Standard / Advanced (`SettingsLevels.swift`).
- **118 route rows** bundled in `ArchiveProcessor/segbench-results/settings-routes.json`, of which only **28 have a runnable `app_route`** (65 reading rows, only 17 runnable).
- **3 extra modal windows** duplicating Settings surfaces: `GeneralInterviewView` (600 × 700), `CollectionInterviewView` (640 × 760), and `SettingsSheetView` (780 × 720, `Choices` / `Range` / `Rules`).

### 2.2 Concrete Defects Seen in the Off-Screen VM Screenshots
1. **Split-brain contradiction on the very same screen (`settings-panel-reading.png`, `settings-panel-documents.png`, `settings-panel-collection.png`):**
   - **Reading** and **Documents** display a huge solver card saying *"The app's pick: Apple Vision"* / *"No model: you check every place yourself"*, followed immediately by *"Not switched on yet: Process Files now reads with Gemini 3.8 Flash."*
   - **Collection** shows `SheetLimitsAndTotals` (`$0 · Apple Vision · 45 of 100`) at the top and `SettingsEstimateStrip` (estimating `Gemini 3.8 Flash` from legacy `@AppStorage`) below the fold — two different cost estimators on one tab disagreeing with each other!
2. **Walls of benchmark prose burying controls (`settings-panel-reading.png`, `settings-panel-documents.png`, `settings-panel-datesAndNames.png`, `settings-panel-pagesAndOutput.png`):**
   - `Documents` fills the entire 660 px window with a ~300-word card explaining unknown boundaries, 3-second checking timing, and 5 unrunnable cloud/10 GB-RAM routes — pushing the actual Segmentation picker, Tagging mode, Merge, and Collection ID controls completely off-screen.
   - `Pages and output` spends the whole visible viewport on three prose boxes (`The copy you read`, `Where the text sits on the page image`, and `Stamps, signatures and notes in the margin` — a full box describing a feature that is *not offered yet*).
   - Even after `fd25093c` collapsed Reading's figures into a disclosure, `Documents`, `Dates and names`, `Pages and output`, and `Collection` remain prose-heavy.
3. **Stacked duplicate pickers (4 places to set Reading or Segmentation):**
   - Reading has: (1) `StageCardView` `"Use instead…"` menu, (2) `SettingsReadingPanel` `"OCR backend"` + `"Provider"` + `"Model"` pickers directly below it, (3) `SettingsSheetView` modal, and (4) Process Files per-page reader controls.
   - Segmentation has: (1) `StageCardView` `"Use instead…"`, (2) `SegmentationChooserView` directly below it, (3) Process Files Segmentation dropdown, and (4) `SettingsSheetView` modal.
4. **Fragmented, surprising navigation (`settings-panel-general.png`, `settings-panel-accounts.png`, `settings-panel-capture.png`):**
   - `General` is a stub (`272 pt` tall) holding only Appearance, a button to re-open the 600 × 700 setup interview, and the Basic/Standard/Advanced toggle; the 4 Starting Points live *inside* that modal interview instead of on Settings itself.
   - `Accounts › Plans › Check and sign in…` opens `GeneralInterviewView` (the entire setup interview!) instead of inline plan controls.
   - Local model downloads are scattered across 3 tabs: Gemma 3 12B in `Capture`, newspaper layout & ATRIUM in `Reading`, and `hand-blla-ctc` in `Pages and output`.
5. **Overcrowded Range chart (`settings-panel-see-the-range.png`):**
   - Because 91 unwired bench rows remain in `settings-routes.json`, the free band on the Reading chart renders an unreadable pile of ~25 overlapping hollow triangles and circles.
6. **Three overlapping runtime config surfaces in `OCRProcessor` & `Capture`:**
   - **Surface 1 (`SessionProcessingConfig`, 35 fields):** Built from `UserDefaults` via `fromDefaults()`, used by Live Capture and `OCRProcessor.activeRunConfig`.
   - **Surface 2 (`PendingRun` + `PendingRunRuntimeConfig` + `PendingBatch`, 50+ fields):** Duplicates almost every field of `SessionProcessingConfig` with slight naming/default drift (`exportOriginals` vs `outputImageFile`, `reviewDocumentSegmentation` vs `reviewWholeRun`, `PendingBatch` missing several `PendingRunRuntimeConfig` fields).
   - **Surface 3 (`ResolvedSettingsSnapshot` + ad-hoc `SettingsLayerStore` reads):** `ResolvedSettingsSnapshot` is frozen into runs with a comment stating *"read by nothing that decides how the run goes"*, yet `OCRProcessor` and `LiveCaptureProcessor` still call `SettingsLayerStore.shared.resolver(at:)` directly for `straightenReadingCopy`, `placeHandOnImage`, `dateImageEveryDocument`, `dateLocalImage`, `lowConfidenceNames`, `searchableFor`, `noTraining`, and `keepPreservationCopies`.
   - This split already causes live drift: on `main`, `test-settings-panels.sh` fails on a `reviewDocumentSegmentation` default mismatch (`true` in UI vs `false` in `SettingsLevels`), and `test-settings-layers.sh` fails because `CollectionSettingsVocabulary` lags new `SettingsKey` additions.

---

## 3. Architectural Foundation (Shared by Both Options): One Unified `ResolvedRunConfig`

Whether Option A or Option B is chosen, the split-brain between Settings and execution must end permanently.

### 3.1 Single Resolution Pipeline
```text
  General Layer (Application Support)
       ↓  live inheritance (override only what is explicitly set)
  Project Layer (optional, Application Support)
       ↓
  Collection Layer (<output>/.archivesuite/collection-settings.json)
       ↓  SettingsResolver.resolveRunConfig(for: outputFolder, macMemoryGB:)
  ┌──────────────────────────────────────────────────────────────────┐
  │  ResolvedRunConfig (single immutable Codable + Sendable struct)  │
  └──────────────────────────────────────────────────────────────────┘
       ├──▶ Process Files (fresh run, paid batch, pre-OCRed, resume)
       ├──▶ Live Capture (locked at session start)
       ├──▶ Single Live Cost/Time Estimator (Settings footer & Process Files)
       └──▶ Frozen into .archivesuite/runs/<id>.json (Reader & Notes read this)
```

### 3.2 Structure of `ResolvedRunConfig`
One typed value replaces `SessionProcessingConfig`, `PendingRunRuntimeConfig`, and `ResolvedSettingsSnapshot.processing` (with **no migration code** per the 2026-08-01 no-production-material directive):

```swift
struct ResolvedRunConfig: Codable, Equatable, Sendable {
    var schemaVersion: Int = 2
    var provenance: Provenance          // runID, resolvedAt, collectionID, projectID/Name, macMemoryGB, perFieldSource
    var reading: ReadingConfig          // primaryRoute, handwritingRoute? (2-way split), cascade?, postCorrection, visionOptions, customPrompt
    var documents: DocumentsConfig      // taggingMode, segmentationRoute, reviewBoundaries, mergeDocuments, collectionID, confirmCollectionIDs, tagVocabulary, boxColour, folderColour
    var metadata: MetadataConfig        // numericDateOrder (.monthFirst / .dayFirst), dateImagePass (.undatedOnly / .everyDocument / .off), localDateImagePass, extractNames, lowConfidenceNames, macItemFields
    var output: OutputConfig            // keepPreservationCopies, pdfFormat (.imageAndText / .searchableWherePossible), searchableRules, pdfImageMB, exportSeparateImage, exportedImageMB, textColumns, straighten, rotationMode, reviewRotation, placeHandOnImage, skipAlreadyProcessed, exportSegmentJSON, writeLogFile
    var execution: ExecutionConfig      // staysOnMac, noTraining, batchMode, preOCRedInput, ocrWorkerCount, imageResolutionScale, standardImageMB, spendingCapUSD?, monthlyCapUSD?, institutionalImportFolder?
    var capture: CaptureConfig          // liveProcessingMode (.stage / .live), readContainerLabels
}
```
- **Credentials stay out of `ResolvedRunConfig`:** A separate non-`Codable` `RunCredentials` struct loads only the needed Keychain key(s) at run start, guaranteeing secrets never serialize into `pending_run.json`, `pending_batch.json`, or `.archivesuite/runs/`.
- **Reader & Notes compatibility (`SPEC/collection-settings.md`):** `<output>/.archivesuite/collection-settings.json` keeps the same safe, atomic, `O_NOFOLLOW`-guarded format (`CollectionSettingsFile`). `SPEC/collection-settings.md` and `ArchiveCore.CollectionSettingsVocabulary` are updated in the same commit as `ResolvedRunConfig` so Reader's Inspector and Notes' collection cards continue to show what produced every collection.
- **Per-collection scope actually works:** Setting `Reading = Gemini 3.8 Flash` or `Date format = DD/MM` on Collection A writes to Collection A's `collection-settings.json`, never touching Collection B or General defaults — eliminating the global-override footgun.

---

## 4. Detailed Comparison: Option A vs. Option B

### Option A — Restored Unified Shape-A Workbench (True Replacement)
- **What the owner sees:** Opening Settings (`⌘,`) shows a wide **3-tab window** (`Workbench`, `Output & Capture`, `Accounts & Advanced`) around `1,020 × 720 pt`.
  - **Workbench** reproduces `prototype.template.html`: left column (`300 pt`) holds Starting Points, detected Mac RAM/keys/plans, Spending ceiling, Hours, Document mix (`Measure sample…`), and Preference; right column (`720 pt`) has a segmented switch (`Picks` / `Range`) showing 4 compact stage cards (Reading, Boundaries, Dates, Names) with inline override dropdowns and direct Pareto charts over the pruned ~28 runnable routes.
  - Legacy `OCR backend` / `Provider` / `Model` / `SegmentationChooserView` pickers are **deleted**; choosing an override on a card writes straight to `ResolvedRunConfig`.
- **Workflow effect:** Every settings change flows through the solver. Great when exploring *"What happens if I give this box $3 instead of $0?"*, awkward when you already know *"Run Gemini 3.8 Flash on this folder"* or *"Use Apple Vision + Gemma 3 12B on this Mac"* (you must either tweak constraints until the solver picks it or override each card into a "Custom" state).
- **Trade-offs & dependencies:**
  - Large window footprint (`~1,020 pt` wide) feels unlike a native macOS Settings window on a laptop screen.
  - Still needs 2+ additional tabs for Output, Capture, Accounts, Local Model Downloads, and Advanced controls, so it does not actually fit in one screen.
  - Tightly couples routine model selection to benchmark JSON completeness (e.g., adding a custom OpenRouter model or new local model requires special-case bypasses around the solver).

### Option B (Recommended) — Preset-First Clean Settings (5 Tabs) + Optional Advanced Advisor
- **What the owner sees:** Opening Settings (`⌘,`) shows a calm, native **5-tab macOS Settings window** (`660 × 620 pt`, consistent height across tabs — no window jumping!):
  1. **`Processing`** — Scope bar (`General defaults` / `Collection: <name>`), **4 Workflow Presets** (`Fast & Free Mac`, `High-Accuracy Local`, `Cloud`, `Cluster`), 4 clean direct-control sections (**Reading** with 2-way Typed/Handwriting split, **Documents & Tagging**, **Dates & Names**, **Privacy & Spending**), `Appearance`, and a single live **Estimate & Advisor footer** with **`Compare routes & trade-offs…`**.
  2. **`Output`** — Preservation copies, PDF format & size (`1.5 MB`), optional JPEG export, columns, straightening, rotation, skip-processed, Finder colours, and controlled vocabulary.
  3. **`Capture`** — Live Capture mode (`Stage for later` / `Process live`), `Read box and folder labels`, and optional Google Drive cloud relay.
  4. **`Accounts`** — Unified **Local Models on this Mac** (`LocalModelSupervisor` downloads with RAM/disk size, progress, pause, remove), **API Keys** (Keychain + guided wizard), and direct **Claude & ChatGPT subscription** sign-in/status.
  5. **`Advanced`** — Clean, clearly labelled home for Call 15 lower-scoring/experimental options, optional downloads (`hand-blla-ctc` default OFF, newspaper layout), BYO server/gateway/CLI raw fields, and tuning/diagnostics. Whenever any Advanced setting is non-default, a 1-line pill on `Processing` says `"N Advanced overrides active — View / Reset"` so nothing ever runs invisibly.
- **Optional Advanced Advisor (`Compare routes & trade-offs…`):** Clicking this button on `Processing` opens a clean, focused sheet containing the **pruned Shape-A solver and Pareto Range charts** (only the ~28 runnable app routes + supported local/cluster routes, using the unified practical-floor tie rule). Users can adjust budget, hours, document mix (`Measure sample…`), and priorities, see the frontier, and click **"Apply to <Collection / General>"** to write those concrete choices directly into `ResolvedRunConfig`.
- **Workflow effect:**
  - A Basic user picks one of 4 plain-English workflow presets (or keeps the default **Fast & Free Mac**) and is done in 5 seconds.
  - A Standard user edits any reader, 2-way handwriting split, tagging mode, date order (`MM/DD` vs `DD/MM`), or spending cap directly — no solver wrestling, no "Not switched on yet" mismatch.
  - A curious/budget-conscious user clicks **"Compare routes & trade-offs…"** and gets the full measured Pareto frontier and solver without cluttering everyday Settings.
- **Trade-offs & dependencies:**
  - The Pareto chart and solver are one click away instead of always open on the first screen.
  - Depends on `W49.proc-pipeline-prune-apply` (currently in flight) for the pruned `settings-routes.json`, 2-way reading split, unified tie rule, and date-order field; `Accounts › Local Models` integrates cleanly with `W49.proc-managed-local-ocr` once `W46.ocr-gemma3-12b` finishes.

---

## 5. Option B Screen-by-Screen Specification (Before & After + Sample Copy)

### 5.1 Tab 1: `Processing` (Replaces `General`, `Collection`, `Reading`, `Documents` picker, `Dates and names`)

**Before (today):** 5 separate tabs, ~1,200 words of inline benchmark prose, two competing cost estimators, two competing Reading pickers, two competing Segmentation pickers, `"Not switched on yet"` warnings, and a Basic/Standard/Advanced switcher hiding active settings across tabs.

**After (Option B — `Processing`, `660 × 620 pt`):**
```text
┌──────────────────────────────────────────────────────────────────────────┐
│  [Processing]   [Output]   [Capture]   [Accounts]   [Advanced]           │
├──────────────────────────────────────────────────────────────────────────┤
│  Editing: [ Collection: Letters 1962 ▾ ]   Project: [ None ▾ ]  (Reset)  │
│  ⓘ 1 Advanced override active (Post-correction)      [View]  [Reset]     │
│                                                                          │
│  WORKFLOW PRESET  (fills the choices below; edit any row freely)         │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐     │
│  │ Fast & Free  │ │ Local HD     │ │ Cloud        │ │ Cluster      │     │
│  │ Vision · $0  │ │ Mac VLM · $0 │ │ Best · API   │ │ Slurm / HPC  │     │
│  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘     │
│                                                                          │
│  READING                                                                 │
│  Reader             [ Apple Vision (this Mac) ▾ ]  (?)  Free · Offline   │
│  [x] Use a different reader for handwritten pages  (?)                   │
│      Handwriting    [ LightOnOCR-3 4B (this Mac) ▾ ]   Installed · 4 GB  │
│                                                                          │
│  DOCUMENTS & TAGGING                                                     │
│  Tagging mode       [ Automatic ▾ ] (?)                                  │
│  Document breaks    [ Propose with Gemini 3.8 Flash ▾ ] (?)              │
│  [x] Review boundaries before filing   [ ] Merge multi-page documents    │
│  [ ] Identify collections from box labels  ( [ ] Confirm before filing ) │
│                                                                          │
│  DATES & NAMES                                                           │
│  Numeric dates      (•) MM/DD (US)   ( ) DD/MM (International) (?)       │
│  Stamp/image dates  [ Only when text has no year ▾ ] (?)                 │
│  [x] Extract sender, recipient, and sending place (?)                    │
│                                                                          │
│  PRIVACY, SPENDING & APP                                                 │
│  [ ] Keep pages on this Mac (?)   [ ] Exclude routes that train (?)      │
│  Spending limit     [ Per month ▾ ]  [$20.00]  ($4.20 spent this month)  │
│  Appearance         [ System ▾ ]             [Re-run Setup Wizard…]      │
├──────────────────────────────────────────────────────────────────────────┤
│  1,000 pages: ~$1.85 (Batch ~$0.95) · ~14 min    [Compare routes…]       │
└──────────────────────────────────────────────────────────────────────────┘
```

**Sample copy (concise, plain language; long comparisons live in Handbook / ArchiveOCRBench):**
- **Scope bar `?` popover:** *"Each output folder is a collection with its own settings stored in `.archivesuite/collection-settings.json`. Anything you leave unchanged inherits live from its Project and General defaults. Changed rows show a Reset button."*
- **Workflow preset captions:**
  - **Fast & Free (Mac):** *"Apple Vision on typed and printed pages. Free, fast, completely offline. Flags handwriting unless a local reader is chosen."*
  - **Local HD (Mac):** *"Apple Vision for typed/printed pages and a downloaded Mac model for handwriting and document breaks. Free and offline."*
  - **Cloud:** *"Uses your API key or signed-in subscription for the highest accuracy on hard scans, handwriting, and metadata."*
  - **Cluster:** *"Imports bulk OCR runs prepared for a university Slurm cluster and runs finishing steps on this Mac."*
- **Reading picker:** One unified grouped menu replacing BOTH the backend picker (`Direct API / Gateway / Local CLI / Apple Vision`) AND the separate provider/model pickers:
  - *This Mac (Free, Offline)*: `Apple Vision`, installed managed local VLMs (e.g., `LightOnOCR-3 4B`, `Gemma 3 12B` if qualified), or configured BYO local server.
  - *Subscriptions (Included in plan)*: `Claude Sonnet 5.5 (Claude plan)` (shown when signed in).
  - *Cloud APIs (Pay per page)*: curated measured models grouped by provider (`Gemini 3.8 Flash`, `Claude Sonnet 5.5`, `Mistral OCR`, `OpenAI`, pinned `OpenRouter` routes, or configured Institutional Gateway), with an inline price hint (`~$1.40 / 1k pages`). Missing keys show `(Add key in Accounts)` instead of failing silently at Start.
- **2-way handwriting toggle `?` popover:** *"Checks on this Mac whether a page is typed/printed or handwritten (~0.6 s/page, free) and sends handwritten pages to the second reader. Saves money on cloud runs and saves time on Mac runs."*
- **Numeric dates `?` popover:** *"Controls how ambiguous numeric dates like 04/07/1962 are read: April 7 (MM/DD) or July 4 (DD/MM). Stored per collection."*
- **Footer:** Always computed from the exact `ResolvedRunConfig` shown above (one estimator, zero discrepancy). When **Keep pages on this Mac** is checked, cloud/plan routes in the pickers are disabled with a single inline note: *"Cloud readers are hidden while 'Keep pages on this Mac' is on."*

---

### 5.2 Tab 2: `Output` (Replaces `Pages and output` + filing controls from `Documents`)

**Before (today):** 3 huge grey rule boxes occupying the entire viewport (`The copy you read`, `Where the text sits`, `Stamps and signatures — not offered yet`), followed by an interleaved mix of `Pre-OCRed`, `Batch mode`, `Image resolution %`, `Standard image size MB`, `PDF image size MB`, `Exported image size MB`, `Workers`, `Log file`, and a 6-format × 5-kind searchable checkbox matrix.

**After (Option B — `Output`):**
```text
┌──────────────────────────────────────────────────────────────────────────┐
│  PRESERVATION & PDF FORMAT                                               │
│  [x] Keep full-resolution originals in a Preservation folder (?)         │
│  PDF format         [ Image + separate text page (default) ▾ ] (?)       │
│  PDF image target   [ 1.5 ] MB  [−|+] (?)      Text columns   [1|2|3]    │
│  [ ] Also export a separate JPEG image  ( Target: [ 3.0 ] MB [−|+] )     │
│                                                                          │
│  PAGE ORIENTATION & CLEANUP                                              │
│  [x] Straighten sloping pages (?)                                        │
│  Detect rotation    [ Local, checked (recommended) ▾ ] (?)               │
│  [ ] Review rotation before saving (?)                                   │
│                                                                          │
│  FILING & SUBJECTS                                                       │
│  [ ] Skip files already processed in the output folder (?)               │
│  Box Finder colour  [ None ▾ ]        Folder Finder colour  [ None ▾ ]   │
│  Subject vocabulary  Free-form (none set)     [Edit / Import CSV…]       │
└──────────────────────────────────────────────────────────────────────────┘
```
- **Deleted/moved out of main Output:**
  - The 3 giant prose `RuleStageBox`es (including the *"Stamps, signatures and notes in the margin: not offered yet"* box) are **deleted**. One-sentence explanations move to `?` popovers; full rules move to the Handbook (`ArchiveProcessor/REFERENCE.md`).
  - `hand-blla-ctc` handwriting placer moves to **`Advanced › Optional Downloads`** (default OFF per Nov 24 call #1).
  - `Image resolution %` and `Standard image size MB` (unmeasured sizes outside the 2,048 px bench rule), `Parallel OCR workers`, `Write log file`, `Batch mode` (or kept as an inline checkbox on Cloud preset / `Advanced`? Wait: let's keep **"Use overnight batch pricing (~50% cheaper)"** right in `Processing › Privacy & Spending` when a batch-capable cloud provider is selected, since half-price overnight batch is a primary historian cost choice!), `Pre-OCRed PDF input` (belongs on Process Files or `Advanced`, not mixed into image sizing!), and the per-format `SearchableFormatControls` matrix move to `Advanced`.
  - `Tag vocabulary` moves from an always-open 60 pt `TextEditor` to a clean summary row + modal editor/CSV drop sheet.

---

### 5.3 Tab 3: `Capture` (Cleaned-up Live Capture Settings)

**Before (today):** Mixed Gemma 3 12B download UI + Google Drive OAuth raw fields + a giant grey `Taking photos with the phone` prose box.

**After (Option B — `Capture`):**
```text
┌──────────────────────────────────────────────────────────────────────────┐
│  LIVE CAPTURE                                                            │
│  When capturing     (•) Stage for later   ( ) Process live (?)           │
│  [x] Read box and folder labels (?)                                      │
│      Label reader: Gemma 3 12B installed (manage in Accounts & Models)   │
│                                                                          │
│  CLOUD RELAY (GOOGLE DRIVE — OPTIONAL)                                   │
│  Status             Not connected                                        │
│  ▸ Configure Google Drive relay…  (Client ID, Client Secret, Sign in)    │
│    LAN and USB work automatically without Google Drive.                  │
└──────────────────────────────────────────────────────────────────────────┘
```
- Gemma 3 12B download/pause/remove moves to **`Accounts & Models › Local Models`** so every multi-GB download lives in one place (Capture shows a 1-line status + link to `Accounts`).
- `Taking photos with the phone` prose box is **deleted** from Settings (belongs in Live Capture help / Handbook).
- Google Drive OAuth fields fold cleanly behind a disclosure when not configured (stay expanded automatically if a Client ID or sign-in exists).

---

### 5.4 Tab 4: `Accounts` (Unified Local Models, API Keys & Subscriptions)

**Before (today):** API keys in `Accounts`, Plans button redirecting to `GeneralInterviewView`, CLI fields in `Accounts`, Gemma download in `Capture`, newspaper/ATRIUM downloads in `Reading`, hand placer download in `Pages and output`.

**After (Option B — `Accounts`):**
```text
┌──────────────────────────────────────────────────────────────────────────┐
│  LOCAL MODELS ON THIS MAC  (Apple M3 Pro · 18 GB unified memory)         │
│  Apple Vision (built-in)           Ready · 0 GB · Typed & printed        │
│  LightOnOCR-3 4B (OCR)             Installed · 4.1 GB       [Remove]     │
│  Gemma 3 12B (Labels / OCR*)       Not installed · 7.8 GB   [Download…]  │
│  Newspaper layout helper           Not installed · 0.4 GB   [Download…]  │
│  *All app-managed models run one at a time via LocalModelSupervisor.     │
│                                                                          │
│  SUBSCRIPTIONS (NO PER-PAGE FEE)                                         │
│  Claude subscription (CLI)         Signed in               [Recheck]     │
│  ChatGPT subscription              Not signed in           [Sign in…]    │
│                                                                          │
│  API KEYS (STORED IN MACOS KEYCHAIN)          [Guided Key Setup…]        │
│  Gemini       [••••••••••••••••••••]  ✓ Validated                        │
│  Anthropic    [Not set — paste key ]                                     │
│  OpenAI       [Not set — paste key ]                                     │
│  Mistral      [Not set — paste key ]                                     │
│  OpenRouter   [Not set — paste key ]                                     │
│  Gateway      [Not set — paste key ]                                     │
└──────────────────────────────────────────────────────────────────────────┘
```
- **Single home for every local model** (`W49.proc-managed-local-ocr` + `ManagedGemma` + newspaper layout helper), showing exact disk/RAM requirements before download and sharing one `LocalModelSupervisor` status view.
- **Direct subscription controls** right in `Accounts` (no longer opening `GeneralInterviewView`!).
- **No Set/Clear/Add buttons beside key fields** (preserves the 2026-11-05 UI convention).

---

### 5.5 Tab 5: `Advanced` (Replaces Global Basic/Standard/Advanced Switch + 15 Hidden Level Groups)

Every control here carries a short factual caption (and `?` popover for benchmark details). Any non-default setting triggers the calm `"N Advanced overrides active — View / Reset"` banner on `Processing` so a user never forgets an active override.

1. **Experimental & Lower-Scoring Options (Owner Call 15 — all preserved, off by default):**
   - `Use Apple macOS on-device model (apple-fm-27)` — *"Scored 42.4 vs. Vision's 83.1 on 96 pages."*
   - `Image-grounded OCR post-correction (OpenRouter)` — *"Extra paid call; tied on 96 pages (−0.42), +1.47 on 120 public pages; worsened 14/177."*
   - `Search page images for dates on this Mac (Qwen3-VL 8B)` — *"No measured gain on 90 undated docs; ~12 s/doc."*
   - `Find names on small Macs / pre-modern material (low confidence)` — *"Every result marked low confidence."*
   - `Scanned-newspaper detector: DocLayout-YOLO` — *"Optional download; +4.6 pts on 15 scanned newspapers, unmeasured on photos."*
   - `Trained segmentation models under kit gate minimums` — *"Shows exact manifest gate rate (`W47.settings-trained-label`)."*
2. **Optional Heavy Downloads:**
   - `Place handwritten text directly on page image (hand-blla-ctc)` — **Default OFF** (`W49.proc-pipeline-prune-ok` #1; *"~7.5 s/page, up to 8.5 GB RAM; requires ~1 GB download; handwritten pages already get a full text page"*), with Download/Remove button.
3. **Custom Endpoints, Bring-Your-Own Local Server & CLI:**
   - `OpenAI-compatible / Institutional Gateway` (URL, Model ID, Display Name, Input/Output $/1M, Cost Profile, OpenAI preset button).
   - `Bring-your-own local server (LM Studio / Ollama / mlx-vlm)` (per `W49.proc-local-ocr-onboarding`: URL, model ID, Check server, optional escalate-failed-pages toggle).
   - `Local CLI Agent overrides` (CLI tool picker, custom binary path, model override, Guided CLI Setup).
   - `Local segmenter server & online check partner` (server URL, model ID, partner picker).
   - `Manage custom models…` button & `Custom OCR prompt` editor.
4. **Pipeline Tuning & Diagnostics:**
   - `Thinking level` (Low / High, for supporting models).
   - `Escalate failed pages to` (cascade model picker + experimental Vision word-count disagreement toggle).
   - `Apple Vision tuning` (Languages, Fast recognition, Minimum confidence, Custom vocabulary).
   - `Pre-OCRed PDF input` (also reachable from Process Files drop options).
   - `Per-format searchable PDF overrides` (compact editor for `searchableFor` rules).
   - `Send previous page image` (manual-segmentation per-page context).
   - `Image send size` (`Image resolution %`, `Standard image size MB` — note: bench uses 2,048 px @ 0.85).
   - `Parallel OCR workers` (stepper 1–12, or read-only note for Vision/CLI).
   - `Export legacy .json sidecars` (default OFF per `W49.proc-catalogue-cutover`).
   - `Write processing log file` (diagnostic).
   - `Reset all Advanced settings to defaults` button.

---

### 5.6 Optional Sheet: `Compare Routes & Trade-Offs…` (Advanced Advisor)
- Opened from the footer of `Processing` (or from Process Files' estimate strip).
- Built on the pruned `settings-routes.json` (~28 runnable + supported local/cluster routes — **zero** overlapping pile of 91 unrunnable bench rows!) and the unified practical-floor tie rule (`0.5` NES Reading, `2.0` pts Segmentation; 95% CIs shown honestly).
- **Compact layout (2 tabs inside one `820 × 680` sheet):**
  1. **Advisor:** Top strip with `Batch pages`, `Budget ceiling`, `Allowed hours`, `Document mix` (with **`Measure from files…`** button), and `Preference` (`Best accuracy` / `Cheapest within 1 pt` / `Fastest within 1 pt`). Below: 4 concise stage rows (Reading, Boundaries, Dates, Names) with measured score, cost, time, and 1-line *"Next step up"* note.
  2. **Range Charts:** Clean Pareto frontier charts (accuracy vs. cost per 1,000) for Reading, Boundaries, Dates, and Names, with clickable marks and a sortable comparison table.
- **Primary action button:** **`Apply to <Collection / General>`** — writes the Advisor's chosen routes directly into the active layer (`ResolvedRunConfig`) and closes the sheet. Zero split-brain!
- **Footer link:** *"Full 118-route research benchmark & methodology → Open ArchiveOCRBench / Handbook"*.

---

## 6. "Delete When You Replace" — Complete Inventory of Deletions & Dispositions

### 6.1 Swift Files Deleted or Replaced
| Current File(s) | Action | Replaced By |
|---|---|---|
| `Views/SettingsPanels/SettingsGeneralPanel.swift`, `SettingsCollectionPanel.swift`, `SettingsReadingPanel.swift`, `SettingsDocumentsPanel.swift`, `SettingsDatesNamesPanel.swift`, `SettingsPagesOutputPanel.swift`, `SettingsCapturePanel.swift`, `SettingsAccountsPanel.swift` (8 files) | **DELETE** | 5 clean views: `SettingsProcessingTab`, `SettingsOutputTab`, `SettingsCaptureTab`, `SettingsAccountsTab`, `SettingsAdvancedTab` |
| `Views/SettingsStageCards.swift` | **DELETE** | Direct pickers in `SettingsProcessingTab` + optional `SettingsAdvisorSheet` |
| `Views/SettingsPanels/SettingsEstimateStrip.swift` | **DELETE** | Unified `SettingsEstimateFooter` driven by `ResolvedRunConfig` |
| `Views/SettingsPanels/SettingsLevelGate.swift` + `Settings/SettingsLevels.swift` | **DELETE** | Dedicated `Advanced` tab + lightweight `AdvancedOverridesSummary` |
| `Settings/SettingsPanels.swift` | **DELETE** | New 5-tab enum; no 8-panel key-ownership matrix needed once `ResolvedRunConfig` is single source |
| `Views/CollectionSettingsSection.swift` | **DELETE** | Compact scope bar + per-row Reset pill in `SettingsProcessingTab` |
| `Views/LocalModelSettingsView.swift` | **DELETE** | Unified `LocalModelsSection` (`Accounts`) + compact BYO server group (`Advanced`) |
| `Views/SegmentationChooserView.swift` (Settings copy) | **DELETE from Settings** | One `Document breaks` picker in `SettingsProcessingTab`; Process Files keeps a thin 1-line read-only summary + Settings shortcut |
| `Views/GeneralInterviewView.swift` | **DELETE** (after `W49.proc-local-ocr-onboarding`) | Streamlined first-run onboarding wizard (Vision default + optional local model downloads) |
| `Views/CollectionInterviewView.swift` | **DELETE** | Inline `Measure from files…` popover + compact collection fields in `Processing` / `Advisor` |
| `Views/SettingsSheetView.swift` (`Choices`/`Rules` prose boxes) | **REPLACE** | Clean `SettingsAdvisorSheet` (Advisor + pruned `SettingsRangeView`) |
| `Capture/SessionProcessingConfig.swift` + `OCRProcessor.PendingRunRuntimeConfig` + `ResolvedSettingsSnapshot.processing` | **REPLACE** | Single `ResolvedRunConfig` (+ non-serialized `RunCredentials`) |
| `Tests/ArchiveProcessorUITests/SettingsPanelsUITests.swift`, `SettingsLevelsUITests.swift`, `Settings/SettingsPanelsTestDriver.swift`, `scripts/test-settings-panels.sh` | **REPLACE** | Focused tests for the 5-tab Settings UI, Advisor sheet, and `ResolvedRunConfig` single-source contract |

### 6.2 Disposition of All 76 `DefaultsKeys` Constants
- **Migrated into `ResolvedRunConfig` (stored in General/Collection layers — 36 keys unified):**
  - *Reading (12):* `selectedProvider`, `useAppleVision`, `useGateway`, `useLocalAgent`, `ModelSelectionStore.selectedModelId_*` → unified into `ReadingConfig.primaryRoute` + optional `handwritingRoute` (2-way split replaces `ocrPageKindRouting`). `visionLanguages`, `visionUseLLMJudgment`, `selectedThinking`, `ocrCascadeRoute`, `ocrCascadeOnDisagreement`, `ocrPostCorrection`, `customOCRPrompt`.
  - *Documents & Metadata (11):* `taggingModeRaw`, `segmentationApproach`, `segmentationClaudeRoute`, `segmentationChatGPTRoute`, `reviewDocumentSegmentation`, `mergeDocuments`, `enableCollectionSegmentation`, `confirmCollectionIDs`, `tagVocabulary`, `itemTypeColourBox`, `itemTypeColourFolder`, `macItemFields`, `sendPreviousImage` (+ new `numericDateOrder` from `W49.proc-pipeline-prune-apply`).
  - *Output & Execution (13):* `outputImageFile`, `pdfImageSizeMB`, `exportedImageSizeMB`, `textColumns`, `rotationModeRaw`, `reviewRotation`, `skipAlreadyProcessed`, `batchMode`, `preOCRedInput`, `ocrWorkerCount`, `imageResolutionPercent`, `standardImageSizeMB`, `enableSegmentJSON` (default OFF per `W49.proc-catalogue-cutover`), `writeLogFile`.
- **Moved cleanly to `Accounts` / `Advanced` app-level preferences (15 keys — machine/account setup, not per-collection):**
  - `gatewayBaseURL`, `gatewayModelID`, `gatewayDisplayName`, `gatewayInputCost`, `gatewayOutputCost`, `gatewayUpstreamProvider`, `gatewayLocalModel`, `gatewayLocalEscalates`, `localAgentTool`, `localAgentBinaryPath`, `localAgentModel`, `localSegmenterBaseURL`, `localSegmenterModelID`, `localSegmenterPartner`, `driveClientId`.
- **Kept as app-state / Capture / Tools / UI state (14 keys — not Settings controls):**
  - `outputDirectory`, `liveProcessingMode`, `readContainerLabels`, `liveRelayDir`, `chatGPTHostID`, `chatGPTPlanWelcomeShown`, `segmentationPlanCalibration`, `hasSeenKeyOnboarding`, `keychainExplained`, `hasSeenGeneralInterview`, `modelTestSelections`, `processingHistory`, `containerLabelGemmaRequest`, plus `AppAppearance.defaultsKey`.
- **Explicitly DELETED (11 legacy/obsolete keys, zero migration needed per 2026-08-01):**
  - `settingsLevel` (replaced by dedicated `Advanced` tab)
  - `segmentationApproachPreselected` (no longer needed once solver/preset writes cleanly)
  - `ocrHandwritingOnTyped` (mixed-page switch deferred to 2.0 per `W49.proc-pipeline-prune-ok` #2)
  - `contextCharCount` (already dead — comment literally says *"context slider removed; kept 0"*)
  - `contextRemovedMigratedV1`, `rotationDefaultMigratedV1` (dead migration flags — no production data to migrate)
  - `visionFastRecognition`, `visionMinimumConfidence`, `visionCustomVocabulary` → **Wait:** per Call 13, do *not* silently drop these; move them into `Advanced › Apple Vision tuning` (so **6** strictly dead keys are deleted from storage, while **3** Vision tuning keys stay in `Advanced`). *Net count: 6 dead keys deleted + 4 mutually-exclusive backend booleans (`useAppleVision`/`useGateway`/`useLocalAgent`/`selectedProvider`) collapsed into 1 typed `ReadingRoute` enum + 15 raw-field keys isolated in `Advanced`.*

### 6.3 Disposition of All 32 `SettingsKey` Entries (`SettingsLayers.swift`)
- **Kept in `ResolvedRunConfig` & `collection-settings.json` (22 keys):** `keys`, `plans`, `cluster`, `gpusPerJob`, `keepPreservationCopies`, `downloadsAllowed`, `moneyHabit`, `monthCeilingUSD`, `batchCeilingUSD`, `hours`, `trainingOff`, `staysOnMac`, `noTraining`, `straightenReadingCopy`, `placeHandOnImage` (default OFF), `dateImageEveryDocument`, `dateLocalImage`, `lowConfidenceNames`, `scanNewspapersDocLayoutYOLO`, `searchableFor`, `excludedModelFamilies`, plus new `numericDateOrder`.
- **Moved to Advisor-only state (not cluttering main Settings — 10 keys):** `mix`, `strata`, `period`, `languages`, `scripts`, `preference`, `priorities`, `weights`, `checkingMinutes`, `fineTuning`, `readingFallback`, and `override.<stage>.all` (retired once `ReadingConfig`/`DocumentsConfig` hold direct routes).

### 6.4 Long Prose Moved Out of Settings UI
The following multi-paragraph inline blocks are **deleted from Settings** and linked/hosted in `ArchiveProcessor/REFERENCE.md` (Handbook) and `ArchiveOCRBench`:
- All 6 `RuleStageBox` essays (`ocr-input`, `layout`, `reading-copy`, `placement`, `marks`, `capture` — including *"Stamps, signatures and notes in the margin: not offered yet"*).
- The 4 inline stage-card methodology paragraphs (`"All routes use the same documents whose boundaries could be settled..."`, `"conditional on the truth: the correct text of these pages was first drafted..."`, `"at about 3 seconds a place, timed on one person checking 92 places..."`).
- The inline `"What a better figure would need"` 5-bullet boxes on main Settings tabs (kept concise inside the optional **Advisor** sheet only, limited to runnable routes).
- The 180-word `handwritingOnTyped` replay popover (control deferred to 2.0 per Nov 24 call #2).
- Inline post-correction benchmark paragraphs (summarized in 1 line in `Advanced`, full numbers in `?` popover / Handbook).

---

## 7. Ordered Implementation Plan, Dependencies & Acceptance Checks

Every item below is filed in `SUITE_TODO.md` and `.maintenance/AUTONOMOUS_PLAN.md` with **default model routing** and **`(blocked-on: W49.proc-settings-design-ok)`** so zero Settings code is written before your approval.

```text
W49.proc-settings-design-ok (OWNER GATE)
       │
       ├── (+ W49.proc-pipeline-prune-apply)
       ▼
1. W49.proc-settings-config-unify [M · Tier-2] — SHIPPED 2026-11-25 (SUITE_TODO_DONE.md)
       │  One ResolvedRunConfig + RunCredentials; retire 3 overlapping config surfaces;
       │  update SPEC/collection-settings.md + ArchiveCore CollectionSettingsVocabulary
       ▼
2. W49.proc-settings-redesign-core [M-L] — SHIPPED 2026-11-25 (SUITE_TODO_DONE.md)
       │  Build approved 5-tab Settings UI (or Option A if chosen), delete 8 legacy panels,
       │  level gate, dual estimator, and stacked pickers; wire Process Files & Live Capture
       ▼
3. W49.proc-settings-advisor-advanced [M]
       │  Build optional "Compare routes…" Advisor sheet over pruned settings-routes.json,
       │  finish Advanced tab (Call 15 routes + W47.settings-trained-label + hand-blla-ctc OFF),
       │  add "N Advanced overrides active" banner on Processing
       ▼
4. W49.proc-settings-docs-tests-cleanup [S]
       │  Replace old SettingsPanels/Levels UITests & drivers, move long prose to Handbook,
       │  verify light/dark + accessibility in off-screen VM
       ▼
W40.g3 (Processor & Live Capture guided walkthrough)
```

### Interaction with Existing Open Items
- **`W49.proc-pipeline-prune-apply`:** Runs ahead of step 1 and supplies the pruned `settings-routes.json`, 2-way reading split, unified tie rule, `hand-blla-ctc` default OFF, `numericDateOrder`, and rotation fallback.
- **`W49.proc-managed-local-ocr` & `W49.proc-local-ocr-onboarding`:** Plug directly into Tab 4 (`Accounts › Local Models`) and replace `GeneralInterviewView` with the streamlined Vision-default first-run wizard. Neither is blocked by Settings, and `Accounts › Local Models` renders `ManagedGemma` + layout helpers immediately even if `W49.proc-managed-local-ocr` lands later.
- **`W47.settings-trained-label`:** shipped 2026-11-26 on its own (`SettingsAdvanced.why(_:trained:)`, the Advanced Model field's note); step 3 reuses `LocalSegmenter.gateClause` for Advisor route notes.
- **`W49.proc-catalogue-cutover`:** Defaults `enableSegmentJSON = false`, matching its placement in `Advanced`.
- **`W49.proc-metadata-unified-apply` (post-Dec 1):** Consumes `ResolvedRunConfig.metadata` cleanly with zero Settings layout changes.

### Acceptance Checks (Across Steps 1–4)
1. **Clean Debug build, 0 new warnings** across `ArchiveProcessor`, `ArchiveReader`, `ArchiveNotes`, and `swift test` in `packages/ArchiveCore` (since `CollectionSettingsVocabulary` is shared).
2. **Single-source config proof (Tier-2, scratch copies only):** Changing a collection's Reading route, Date format (`DD/MM`), or Tagging mode in Settings immediately updates the live estimate footer, writes only that collection's `.archivesuite/collection-settings.json`, and runs Process Files (fresh, interrupted resume, paid batch) and Live Capture with the exact `ResolvedRunConfig` — leaving other collections untouched.
3. **Zero split-brain & zero stacked pickers:** Static check + UI test confirm there is no `"Not switched on yet"` / `"Read with this"` disconnect, no duplicate Reading/Segmentation pickers, and no dead legacy `SettingsPanels/*` files left in the target.
4. **Non-default Advanced safety:** Setting any control in `Advanced` shows the `"N Advanced overrides active"` pill on `Processing` with working View and Reset actions.
5. **Off-screen Tart VM visual & accessibility verification:** Screenshots of all 5 tabs + Advisor sheet in Light and Dark mode, checked by eye for zero clipped text, consistent window geometry, high contrast, and passing `AccessibilityAuditUITests`.
6. **Zero regressions on existing contracts:** `test-settings-layers.sh`, `test-settings-routes.sh`, `test-settings-solver.sh`, `test-local-models.sh`, `test-date-route.sh`, `test-live-capture.sh`, and `ArchiveReader/scripts/lint-write-surface.sh` all pass.

---

## 8. Locked Owner Decision (2026-11-25 — `W49.proc-settings-design-ok`)

- **Approved option:** **Option B** — Preset-first 5-tab native macOS Settings (`Processing`, `Output`, `Capture`, `Accounts`, `Advanced`) + one unified `ResolvedRunConfig` (replacing `SessionProcessingConfig`, `PendingRunRuntimeConfig`, and `ResolvedSettingsSnapshot.processing` + ad-hoc `SettingsLayerStore` lookups) + optional `Compare routes & trade-offs…` Advisor sheet over pruned runnable routes.
- **Unblocked items:** `W49.proc-settings-config-unify` (still waits on `W49.proc-pipeline-prune-apply`), `W49.proc-settings-redesign-core`, `W49.proc-settings-advisor-advanced`, `W49.proc-settings-docs-tests-cleanup`, and `W47.settings-trained-label`.
