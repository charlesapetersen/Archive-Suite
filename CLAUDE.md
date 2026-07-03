# Archive Processor — Project Guide

## Overview
A native macOS app for processing collections of historical archive photographs. Two primary functions: (1) OCR via LLM models, and (2) macOS filesystem tagging.

---

## Primary Function 1: OCR

### LLM Provider & Model Selection
Dropdown menus for provider and model. No models other than those listed below.

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
- Build: XcodeGen — `project.yml` is authoritative; run `xcodegen generate` after adding files (never hand-edit `.pbxproj`)

---

## Project Structure
```
Archive Processor/
├── CLAUDE.md, README.md, POTENTIAL_FEATURES.md, DISTRIBUTION_PLAN.md
├── ArchiveProcessor/                  # macOS app (XcodeGen: project.yml)
│   └── Sources/ArchiveProcessor/{Models, OCR, Tagging, Capture, Net, Views}/
├── ArchiveCapture/                    # Android companion app (Gradle)
├── ArchiveCaptureiOS/                 # iPhone companion app (XcodeGen: project.yml)
│   └── Sources/ArchiveCaptureiOS/{Net, Capture, Camera, UI}/
└── Test Files/                        # Do NOT modify; write outputs only
```
See the README's "Project Structure" for the full annotated file tree (Capture/, Net/, and the Views split into OCRView / SettingsView / ToolsView / LiveCaptureView / etc.).
