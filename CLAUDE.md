# Archive Processor — Project Guide

## Overview
A native macOS app for processing collections of historical archive photographs. Two primary functions: (1) OCR via LLM models, and (2) macOS filesystem tagging.

---

## Primary Function 1: OCR

### LLM Provider & Model Selection
Dropdown menus for provider and model. The **built-in** models are those listed below — don't silently add others to the built-in lists. Two shipped escape hatches exist for anything not built in (see "Custom models & OpenAI-compatible gateway" below): users can add extra model IDs, or point the app at an OpenAI-compatible endpoint.

**Anthropic**
- claude-sonnet-4-6
- claude-opus-4-6

**Google Gemini**
- gemini-3.1-flash-lite (default)
- gemini-3.5-flash
- gemini-3.1-pro
- gemini-3-flash-preview
- gemini-2.5-flash
- gemini-2.5-flash-lite
- gemini-2.5-pro

**Mistral**
- mistral-ocr-latest (Mistral OCR 3)
  - Note: Mistral returns markdown-formatted text

### Custom models & OpenAI-compatible gateway (shipped)
- **Custom models:** users can add extra Anthropic/Gemini model IDs via **Manage custom models…** in Settings (`Views/ManageModelsView.swift`, persisted by `Models/ModelSelectionStore.swift`) — so the dropdowns are not limited to the built-in lists above.
- **OpenAI-compatible gateway:** toggle **Use gateway** in Settings (`@AppStorage` `useGateway` + `gatewayBaseURL`/`gatewayModelID`, with a separate **Gateway** key in Keychain) to route OCR through any OpenAI-compatible chat-completions endpoint (self-hosted or proxied). Client: `OCR/OpenAICompatibleClient.swift` (reuses the shared `OCRPrompt.build`); config is carried as `GatewayConfig` (`Models/ProviderModels.swift`). The gateway path has **no** batch or LLM-rotation support (both are skipped when `useGateway` is on).

### Thinking Mode
For models that support low/high thinking, include a dropdown: Low / High.

### Cost Estimator
- Display estimated cost before processing based on file count and selected model
- Show standard vs. batch pricing side by side
- Update dynamically as files are added

### Batch Processing
- Toggle button to enable batch mode
- Batch processing: lower cost, significantly longer return time
- Cost estimator must reflect batch discount

### Concurrency
- Process files via multiple workers/threads for speed

---

## File Input
- Drag-and-drop onto the app
- File selection button (standard macOS open panel)
- Accepted formats: JPEG, PNG, TIFF, HEIC (standard image formats for archive photos)

---

## OCR Output Format

### Per-file output
Each input image → one PDF with the same base filename.

**Page 1:** The original image (full page)

**Page 2:** OCR text
- Header: `Extracted text.`
- Subheader: `[Provider] · [Model] · [Day Month Year]` (e.g., `Anthropic · claude-sonnet-4-6 · 9 March 2026`)
- Body: Full OCR text, well-formatted and laid out
- **Critical:** All text must fit on a single page. Page 2 must be arbitrarily tall — no text overflow to a third page.
- If no text returned: `No text returned by model.` followed by the error code/reason if provided.
- Gemini-specific: Gemini may refuse copyrighted text with error `"Recitation"` — handle and display this error clearly.

### Batch log file
After all files are processed, generate a `.txt` log file listing:
- All files that failed to produce OCR text
- Error reason for each

---

## Primary Function 2: Tagging

### Document Segmentation
Archive photos do not mark document boundaries. The app must infer them using heuristics.

**Certain break points:**
- Photographs of boxes → new box
- Photographs of folders → new folder

**Heuristic break points (documents):**
- Newspaper/magazine article: headline
- Letter: To/From lines, signature
- Memo: title line
- Report/Draft: title
- Text ending mid-page (document ends)
- Text continuing to fill the page (document continues)

Common document types: newspaper articles, magazine articles, letters, memos, reports, drafts.

### Tags Applied to Each File

Applied using macOS filesystem tags (via `xattr` / NSFileManager / `tag` CLI or similar).

**Date tags (most important)**
1. Year tag: e.g., `1968`
2. Month tag: e.g., `03 March` (format: `MM Month`)
- If date cannot be determined: estimate year from surrounding documents; never estimate month; always add tag `Date Uncertain`

**Subject tags**
- 2–6 tags per document
- General but not too general
- Examples: `Democratic Party`, `taxes`, `elections`, `education`, `transportation`, `business`, `literature`, `economics`

**Special tags**
- Photographs of **boxes** → macOS `Red` tag
- Photographs of **folders** → macOS `Purple` tag
- Every output (PDF **and** any exported original image) → a trailing **`Unread`** tag, applied **last**, for triage. Only in real-tagging modes (`.automatic`/`.autoDate`/`.autoDateManualSeg`/`.human`) — never for "No tagging" or "Copy source tags". Implemented via `MacOSTagger.stampUnread` (armed from `TaggingMode.stampsUnread`).

### API Efficiency for Tagging
- Minimize API calls — batch OCR results where possible before making tagging calls
- Reuse OCR output; do not re-query the image for tagging if text is already extracted

---

---

## Primary Function 3: Live Capture (phone companion + streaming)

Photograph documents with a phone companion app — **Android** (`ArchiveCapture/`, Kotlin + Compose + CameraX) or **iPhone** (`ArchiveCaptureiOS/`, SwiftUI + AVFoundation, XcodeGen, Swift 5 language mode) — and stream them to the Mac's Live Capture tab. Both companions speak the same `CaptureServer` protocol and share the segment-transfer UX (photos leave the phone as segments are confirmed on the Mac). The iPhone companion holds no API keys and pairs over the LAN (QR or manual host/port/token).

- **On the phone:** full-res shutter; **Box** (red) / **Folder** (purple) markers; **End segment** finishes a document. Minimal on-phone tagging: priority (P7–P10 + per-page P10) and year/month. Durable disk queue with auto-retry — a photo is never lost (archival photos can't be re-taken). Idempotent re-upload on the Mac (same group+seq → replace).
- **Pairing:** QR (host/port/token, Bearer-auth). LAN or **USB** (`adb reverse` → `127.0.0.1`, auto-run by the Mac). Stable token + pinned port survive Mac restarts; the QR hides once paired.
- **Mac tagging:** an auto-advancing, keyboard-driven **tag card** per document segment (subjects via `SystemTagsProvider` autocomplete; editable date/priority).
- **Two modes (chosen in Settings, `liveProcessingMode`):**
  - **Stage for later** — captures collect, then hand off to Process Files for a batch run.
  - **Process live** — each segment is OCR'd **on arrival**, tagged, turned into a **PDF + renamed original image** (dual output), merged if multi-page, and staged as you shoot. At **Finish session**, confirm each collection's name (auto-suggested from the box-label OCR, **fuzzy-matched against existing folders** to append; new files continue that folder's `NNNNN` numbering). Durable + resumable (staging manifest; failed-OCR retry).
- **Key files (Mac):** `Capture/{CaptureModels,CaptureSession,SessionProcessingConfig,LiveCaptureProcessor}.swift`, `Net/{CaptureServer,USBBridge}.swift`, `Views/{LiveCaptureView,CollectionFinalizeSheet,KeyboardTokenField}.swift`.
- **Key files (iPhone, `ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/`):** `Net/{MacEndpoint,MacClient}.swift`, `Capture/{CaptureModels,SessionStore,CaptureViewModel}.swift`, `Camera/CameraController.swift`, `UI/{ConnectScreen,CaptureScreen,QRScannerView,CameraPreview,SegmentTagSheet}.swift`. Its own `project.yml` (`xcodegen generate` after adding files); camera capture needs a physical device (the simulator has no camera).

---

## Settings & Tools

- **Settings window (⌘,)** — `Views/SettingsView.swift`, a `Settings { }` scene. All durable settings (provider/model/API mode+key, input/batch/resolution, rotation, tagging options, custom models, live-capture mode) in a grouped `Form`, with a **pinned live cost-estimate pane** (1,000 files ≈ 3 MB). Shared with the main window via `@AppStorage`/UserDefaults + Keychain. The **tagging-mode dropdown** and **output folder** stay in the Process Files view.
- **Tools tab** — `Views/ToolsView.swift`: **Compare Models** + **Test Resolution** (one-off diagnostics via `OCRProcessor.performResolutionTestCall`).

---

## Test Files
- Located in `Test Files/` directory within the project
- Contain a wide range of document types
- **Do not delete or modify any test files**
- Only create new output files

---

## API Keys & LLM Calls
- **LLM/API calls are allowed and expected** — this app is built around them, and running them is a normal part of development and verification. The constraint is **cost, not permission**: keep spending low and get a key first.
- **Do not store API keys in code or config files** — Keychain, or user-provided at runtime, only.
- Before any **paid** run: (1) write a short test plan, (2) estimate the cost, (3) request the appropriate API key from the user. Once you have the key, proceed with the run.
- Keep costs low: prefer the cheapest capable model for tests (e.g., `gemini-2.5-flash-lite`, `claude-sonnet-4-6`) and the smallest input set that proves the behavior.

---

## Architecture Notes (macOS Native)
- Language: Swift (macOS app + iPhone companion, `ArchiveCaptureiOS/`) + Kotlin (Android companion, `ArchiveCapture/`)
- UI framework: SwiftUI (AppKit where needed); iPhone companion is SwiftUI + AVFoundation; Android is Jetpack Compose + CameraX
- Concurrency: Swift concurrency (async/await + TaskGroup) for parallel OCR workers; **Swift 6 strict concurrency** (`@MainActor`, `Sendable`, `nonisolated(unsafe)` for the few write-once statics)
- PDF generation: Core Graphics (dynamic page sizing for the text page)
- Filesystem tagging: `NSFileManager` extended attributes (`NSURLTagNamesKey`, `NSURLLabelNumberKey`)
- Networking: URLSession for LLM API calls; an `NWListener` HTTP receiver for Live Capture (`Net/CaptureServer.swift`)
- Settings: durable settings in `UserDefaults`/`@AppStorage` (shared across the main window and the ⌘, Settings scene) + Keychain for keys
- Build: XcodeGen — `project.yml` is authoritative; the generated `.xcodeproj` is **not committed** (gitignored). After cloning run **`./bootstrap.sh`** (installs XcodeGen if missing and regenerates every project); thereafter run `xcodegen generate` whenever files are added (never hand-edit `.pbxproj`). Prerequisite if not using bootstrap: `brew install xcodegen`.

---

## Concurrent / multi-agent development

Multiple people or AI instances can work in parallel **as long as each gets its own git worktree** — never run two instances in the same working directory (they clobber each other's uncommitted edits and race on the build cache).

**Worktree lifecycle** (paths contain a space — always quote):
```bash
git worktree add "../ap-wt-<lane>" -b <branch>   # isolated sibling checkout on its own branch
cd "../ap-wt-<lane>/ArchiveProcessor" && xcodegen generate   # required: .xcodeproj isn't committed
# ...work, build (below), commit...
git worktree remove "../ap-wt-<lane>"   # ./build is gitignored, so it doesn't block removal
```

**Per-worktree build isolation** — give each worktree its own DerivedData so concurrent builds don't collide:
```bash
xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build
# iOS: xcodebuild -scheme ArchiveCaptureiOS -sdk iphonesimulator -configuration Debug -derivedDataPath ./build/DD build
```
`./build` is already gitignored, so per-worktree DerivedData is never committed. Note: `-derivedDataPath` isolates DerivedData and module caches but **not** the shared user-level Clang cache (`CACHE_ROOT`) — treat it as "separate DerivedData per worktree," not fully sandboxed.

**Ownership lanes** — avoid two instances editing the same lane at once:
- **Android** — `ArchiveCapture/` (Gradle, Kotlin). Fully independent.
- **iPhone** — `ArchiveCaptureiOS/` (Swift 5). Independent *except* the phone↔Mac protocol.
- **macOS OCR core** — `Sources/ArchiveProcessor/{OCR, Models, Capture, Net}`.
- **macOS Views + Tagging** — `Sources/ArchiveProcessor/{Views, Tagging}`.

**Shared hotspots that force cross-lane coordination:**
- **`Models/ProviderModels.swift` enums** (`LLMProvider`, `ThinkingLevel`, `DocumentClassification`, `TaggingMode`, `RotationMode`): **append cases only — never renumber, reorder, or change rawValues** (they are `Codable`/persisted; reordering corrupts users' saved settings).
- **Phone↔Mac protocol:** `Net/CaptureServer.swift` (routes `GET /ping`, `POST /photo`, `POST /session/complete`, `Authorization: Bearer`) ↔ `ArchiveCaptureiOS/.../Net/MacClient.swift`. Change both sides together.
- **The two `project.yml` files.**

**Rules:** never hand-edit `.pbxproj` (edit `project.yml` + `xcodegen generate`, now also required after clone); keep commits small and rebase often; build-verify before every commit.

---

## Verification & review policy (no human in the loop)

This project is maintained by Claude with **no human reviewer, no CI, and minimal automated tests**, yet it
writes **irreplaceable data** (archival photos that can't be re-shot), uses strict Swift-6 concurrency, and
spends real money on API calls. So verification is **deliberate and tiered by risk** — not the same effort on
every change. **Decision (2026-07-04): yes, do adversarial review before pushing — but tier it as below** so
the cost matches the risk instead of running a heavy review on every trivial edit.

**Tier 1 — every commit (always):** build clean with **no new warnings** (`xcodegen generate` + `xcodebuild … build`),
and self-review the diff (`/code-review`, or read your own diff critically). Cheap; catches most regressions.

**Tier 2 — high-blast-radius changes (adversarial, regardless of diff size):** any change touching a class of
bug that has **no undo** gets a multi-agent *adversarial* review — independent skeptic agents that try to
break it — plus a targeted functional test where feasible. This tier is triggered by edits to:
- `Capture/`, `Net/` (Live Capture durability, the phone↔Mac protocol, crash-recovery/manifest logic),
- file-writing tag/output code (`Tagging/MacOSTagger.swift`, PDF/image output, collection numbering that could **overwrite** files),
- batch/manifest persistence, or anything changing `@MainActor`/`Sendable`/actor isolation.

**Tier 3 — before every push or release (the batch):** run a **multi-agent adversarial review of the whole
accumulated diff** (the *find → refute* pattern: finders propose defects, a second set of agents tries to
refute each, only survivors are real), and a **live smoke test** if the OCR/tagging/PDF path changed. Push
only after it comes back clean. (Batching pushes is the standing cadence — commit locally often, push rarely.)

**Always adversarially *verify* findings before acting on them.** With no human to sanity-check, a plausible-
but-wrong "fix" is its own risk: have a second agent try to *refute* each finding (default to "not a bug" when
uncertain) before you change code. The `Workflow` tool's find→verify pattern is the intended vehicle; a durable
example script lives at `.maintenance/` during active maintenance sessions.

---

## Releasing (macOS DMG + GitHub release)

Versioning is by **git tag** (`vMAJOR.MINOR.PATCH`, e.g. `v3.8.1`) — the tag is the source of truth; `Info.plist` `CFBundleShortVersionString` is left at "1.0". Patch bump for internal-only changes (refactors), minor for user-facing features. Distribution is **owner-only** (ad-hoc signed `CODE_SIGN_IDENTITY "-"`, not notarized) — a fresh macOS may need right-click→Open the first time.

**GitHub CLI gotcha:** the real CLI is **`/opt/homebrew/bin/gh`** — call it by full path, because a shadowing Python tool named `gh` is first on `PATH` (bare `gh` fails with an argparse error). It is authenticated as `charlesapetersen` (`repo` scope), so `gh release create` can publish and upload assets.

Build → package → publish:
```bash
cd ArchiveProcessor && xcodegen generate
xcodebuild -scheme ArchiveProcessor -configuration Release -derivedDataPath ./build/rel build
APP="ArchiveProcessor/build/rel/Build/Products/Release/ArchiveProcessor.app"   # from repo root
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE"/; ln -s /Applications "$STAGE/Applications"   # drag-install layout
hdiutil create -volname "Archive Processor <ver>" -srcfolder "$STAGE" -ov -format UDZO "/tmp/ArchiveProcessor-<ver>.dmg"
/opt/homebrew/bin/gh release create v<ver> "/tmp/ArchiveProcessor-<ver>.dmg" \
  --title "Archive Processor <ver>" --target main --notes "…"
```
The `.dmg` is a build artifact — never commit it (build under gitignored `build/` or `/tmp`).

---

## Project Structure
```
Archive Processor/
├── CLAUDE.md, README.md, AGENTS.md, prompts.md, POTENTIAL_FEATURES.md, KNOWN_ISSUES.md, CODE_REVIEW_PLAN.md
├── ArchiveProcessor/                  # macOS app (XcodeGen: project.yml)
│   └── Sources/ArchiveProcessor/{Models, OCR, Tagging, Capture, Net, Views}/
├── ArchiveCapture/                    # Android companion app (Gradle)
├── ArchiveCaptureiOS/                 # iPhone companion app (XcodeGen: project.yml)
│   └── Sources/ArchiveCaptureiOS/{Net, Capture, Camera, UI}/
└── Test Files/                        # Do NOT modify; write outputs only
```

**Two former "god files" are split for concurrent work** (behavior unchanged):
- `OCR/OCRProcessor.swift` — the `@MainActor` class now holds only stored state + member types; its methods live in `OCRProcessor+{Pipeline,OCR,Tagging,ReviewFlows}.swift` (extensions) and its top-level model types in `OCRProcessor+Types.swift`. When adding a method, put it in the extension matching its concern; **all stored properties stay in `OCRProcessor.swift`** (Swift extensions can't add stored properties).
- `Views/OCRView.swift` — the main view; its sheets/rows/diff engine are separate `OCRView+*.swift` files (FileRowView, the review/model/resolution sheets, WordDiff).

**Refactor notes (behavior-preserving splits).** The `OCRProcessor` split is deliberately **coarse** (4 concern-extensions, not one-file-per-method): related state-mutating logic stays together, which lowers cross-file tracing cost for an agent — so there is intentionally no `+Persistence`/`+BatchOCR`/`+MainPipeline`. When verifying a future large move-only refactor: run the git move-proof (`git show --color-moved | grep …`) **tty-independently** — piping makes it pass for *any* commit, so it proves nothing on its own; audit access-level changes by **census-diffing** private members rather than grepping (Swift `internal` is keyword-less, so a grep can't see it); gate on a **warnings delta** to catch Swift-6 isolation drift (and beware an initial "0 warnings" that is really a cached build masking pre-existing ones). Testing-coverage gap to remember: the batch/instance-method GUI path (`startProcessing → review → performTaggingPhase → finalize`) is **not** exercised by `LiveCaptureTestDriver`, which only drives the live-staging `nonisolated` statics.

See the README's "Project Structure" for the full annotated file tree, and the **Concurrent / multi-agent development** section above for ownership lanes and shared hotspots.
