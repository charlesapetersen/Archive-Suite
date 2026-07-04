# Archive Processor

A native macOS application for processing historical archive photograph collections. Archive Processor performs OCR on scanned documents using multiple LLM providers, generates searchable PDFs, applies intelligent filesystem tags, and organizes files into archival collections.

Built for archivists, historians, and researchers working with large digitized document collections.

The app has three areas, selectable at the top of the window, plus a native Settings window:

- **Process Files** — drop in images (or a folder) and run OCR + tagging + organization as a batch.
- **Live Capture** — photograph documents with an **Android or iPhone** companion app and stream them to the Mac; optionally OCR/tag/PDF **each segment as you shoot** so processing finishes with capture.
- **Tools** — one-off diagnostics: compare OCR across models, and test how image resolution affects OCR.
- **Settings (⌘,)** — all durable settings (provider, model, API key, rotation, tagging options, live-capture mode) in one place, with a live cost estimate for 1,000 files that updates as you change settings.

## Features

### Multi-Provider LLM OCR

Process scanned images through any of three LLM providers:

| Provider | Models | Thinking Mode | Batch Processing |
|----------|--------|---------------|------------------|
| **Anthropic** | Claude Sonnet 4.6, Claude Opus 4.6 | Low / High | Yes |
| **Google Gemini** | 3.1 Flash Lite (default), 3.5 Flash, 3.1 Pro, 3 Flash Preview, 2.5 Pro, 2.5 Flash, 2.5 Flash Lite | Low / High | Yes |
| **Mistral** | Mistral OCR 3 | — | Yes |

- Also supports an **OpenAI-compatible API Gateway** (custom base URL + model ID) for self-hosted or proxied endpoints, with user-supplied pricing for cost estimates
- Switch providers and models at any time (in **Settings**)
- API keys stored securely in macOS Keychain
- Cost estimation displayed before processing (standard and batch pricing)
- Custom OCR prompts — append additional instructions to the default OCR prompt
- Image resolution scaling — **size-based** (target a fraction of a standard image size; see below) to lower API cost and time, downscaling large files more

### Guided API-Key Setup

You bring your own API keys, and the app makes that easy. A **first-run wizard** (and a **Set up keys**
button in Settings) walks you through creating and pasting a **free** Gemini and Mistral key — both
providers offer an OCR-capable free tier with **no credit card required**:

- Step-by-step instructions with the exact console page to open for each provider
- Paste-and-validate: each key is format-checked, then confirmed with a live call (a synthetic
  sample-OCR test) before it's saved — so a mistyped or wrong-provider key is caught immediately
- Per-provider status chips in Settings show at a glance which keys are set and working
- Keys are stored only in the macOS Keychain — never in code, config files, or logs

### PDF Output

Each input image produces a two-page PDF:

- **Page 1:** The original image, correctly oriented (rotation detected and applied automatically)
- **Page 2:** Extracted OCR text with provider, model, and date metadata. Page height adjusts dynamically — text never overflows to a third page.

### Multi-Page Document Merging

When enabled, continuation pages are merged into a single PDF with their document start page. A multi-page letter produces one multi-page PDF rather than separate files per page.

### Image Orientation Correction

The LLM detects if images are rotated sideways or upside down. Output PDFs always show correctly oriented images. For folder photographs, orientation is based on the folder tab rather than document text.

Users can manually correct rotation during the segmentation review dialog — radio buttons for 0°, 90°, 180°, 270° with live thumbnail preview. Keyboard shortcuts (`[`/`]`) rotate the focused image in 90° increments.

### Document Classification

Every image is automatically classified as one of:

- **Box Label** — photograph of an archival storage box
- **Folder Label** — photograph of a folder tab or divider
- **Document Start** — first page of a new document
- **Document Continuation** — subsequent page of the same document

Mistral (which uses a dedicated OCR endpoint without prompt support) classifies via text heuristics instead.

### Contextual OCR

Optionally send context from the previous page to improve classification accuracy:

- **Previous text context** — configurable character count (0–1000) from the prior page's OCR text
- **Previous image** — send the full previous page image alongside the current one

Setting previous text to 0 enables parallel OCR processing (4 concurrent workers). Any non-zero value requires sequential processing.

### Batch Processing

All three providers support batch processing for lower-cost, asynchronous OCR:

- Toggle batch mode in the UI
- Batch state persists to disk — survives app restarts
- Resume pending batches with a single click
- Cancel running batches (server-side cancellation)
- Cost estimator shows batch discount (50% for all providers)

### Automatic Retry

- **Auto-retry:** Files that fail due to rate limits or server overload (429, 503, 529) are automatically retried with exponential backoff
- **User retry dialog:** After auto-retry, remaining failures prompt a dialog where you can retry with a different provider/model/API key. The retry loop continues until all files succeed or you choose to continue.

### Document Segmentation & Tagging

When tagging is enabled, the app:

1. **Segments** files into logical documents based on classifications (box/folder labels create boundaries; continuation pages are grouped with their document start)
2. **Generates tags** for each segment via LLM, including:
   - Year and month tags (e.g., `1968`, `03 March`)
   - `Date Uncertain` when dates cannot be determined
   - 2–6 subject tags (e.g., `Democratic Party`, `taxes`, `education`)
   - Document format (letter, memo, report, etc.)
   - Author and recipient information
3. **Applies macOS Finder tags** to output PDFs:
   - Text tags via `NSURLTagNamesKey`
   - Color labels: Red for boxes, Purple for folders
   - An **`Unread`** tag as the **last** tag on every output — but only in real-tagging modes (not "No tagging" or "Copy source tags") — so freshly processed files are easy to spot and triage
4. **Exports JSON metadata** per segment (optional, toggleable)

### Custom Tag Vocabularies

Define a controlled vocabulary for subject tags to ensure consistent tagging across a collection:

- **Manual entry** — type tags directly, one per line
- **CSV file loading** — load vocabularies from CSV files via file picker
- **Drag and drop** — drop CSV files directly onto the vocabulary editor

When a vocabulary is defined, the LLM is constrained to choose only from the provided terms.

### Collection Segmentation & Organization

When collection segmentation is enabled:

1. Identifies archival collections from box label OCR text via LLM
2. Clusters similar collection names (handles variations in case, abbreviation, punctuation)
3. Normalizes names to title case with consistent formatting
4. Organizes output PDFs into collection folders with sequential naming (`00001 Collection Name.pdf`)

### Interactive Review Workflow

The processing workflow includes multiple interactive review points with pause/resume control:

#### 1. Segmentation Review (after OCR)
A full-screen dialog showing all files with:
- Scrollable thumbnail grid with adjustable size slider (60–800px)
- Classification radio buttons per file (New Document, Continuation, Box, Folder)
- Rotation correction radio buttons (0°, 90°, 180°, 270°) with live preview
- Full keyboard navigation:
  - `1`–`4` — set classification
  - `[`/`]` — rotate counter-clockwise/clockwise
  - `↑`/`↓` — navigate between files
  - `Return` — confirm and proceed

#### 2. Tagging Review (after tag generation)
Review generated tags in the file pane. Double-click any file to edit its classification. Options to:
- **Redo tagging** — regenerate tags with updated segmentation
- **Complete** — proceed to collection organization

#### 3. Collection Name Review (final step)
Review and correct LLM-extracted collection names for box images before files are organized into collection folders.

### Tools tab

Diagnostics live in the **Tools** tab (next to Process Files and Live Capture):

- **Compare Models** — run one image through several provider/model combinations side by side, with diff highlighting, and adopt a model directly from the results.
- **Test Resolution** — OCR one image at 10–100% resolution to see how downscaling trades accuracy against cost, then adopt a resolution.

### Settings window (⌘,)

All durable settings live in a native macOS Settings window: provider/model/API mode, a **separate API-key field per provider** (Anthropic / Gemini / Mistral / Gateway, each in the Keychain), input & processing (pre-OCR, batch, image resolution), rotation, tagging & segmentation options, custom models, and the Live Capture processing mode. The tagging **mode** dropdown and the output folder stay in the Process Files view for quick access.

A **pinned pane on the right** recomputes live for 1,000 files (at your standard image size) as you change settings:

- **Cost** — broken out by phase: OCR, **rotation** (LLM rotation calls, which weren't counted before), tagging, and collection ID, with standard and batch totals.
- **Time** — an estimate of *processing* time (network + LLM generation only, not human interaction), broken out per phase, calibrated from measured latencies and the pipeline's concurrency (OCR 4-wide, tagging 6-wide; rotation overlaps OCR). Interactive (non-batch) processing; batch mode returns asynchronously.

### Size-based image resolution

The image-resolution slider is a **target fraction of a standard image size** (default 3 MB, configurable in Settings), not a fixed percentage of each file's dimensions. At 100% it targets the standard size, so **larger files are downscaled more** while average/small files are left full-resolution — evening out cost and time across a collection.

### Pre-OCRed PDF Input

Process PDFs that already contain OCR text (e.g., from a previous run):

- Extracts text without API calls
- Classifies via text-only LLM calls (no image processing)
- Applies tagging and collection segmentation normally
- Useful for re-tagging or re-organizing previously processed files

### File Input

- **Drag and drop** images onto the app window
- **File selection** via standard macOS open panel
- **Directory selection** — recursively finds all images in the selected folder
- Supported formats: JPEG, PNG, TIFF, HEIC, BMP, GIF, PDF

### Other Features

- **Cost estimator** — shows estimated cost before processing, updated dynamically as options change
- **Source tag pass-through** — optionally copy existing Finder tags from source files to output PDFs
- **Progress tracking** — real-time status messages and progress bar
- **Error display** — full error text visible in the file pane
- **Log file** — generated after processing, listing all failures with reasons
- **Secure networking** — ephemeral URLSession, retry with backoff on transient errors, cellular network support

## Live Capture (phone companion + streaming)

Photograph documents with a phone and stream them straight into the pipeline — no scanner, no manual import. This is the **Live Capture** tab plus a companion app for **Android** (`ArchiveCapture/`, Kotlin + Jetpack Compose + CameraX) or **iPhone** (`ArchiveCaptureiOS/`, SwiftUI + AVFoundation). Both companions speak the same streaming protocol and offer the same capture workflow; pick whichever phone you have.

**On the phone:** shoot document pages with a full-resolution shutter; mark **Box** (red) and **Folder** (purple) with dedicated buttons; **End segment** finishes a document. Minimal on-phone tagging per segment: **priority** (P7–P10, with a per-page P10 override via long-press) and **year/month**. Photos and their grouping/tags are written to disk immediately and uploaded via a durable, auto-retrying queue — so a photo (which can't be re-taken) is never lost, even across an app crash or an unplugged cable. As each segment is confirmed on the Mac, its photos **leave the phone** (with a transfer animation), so images stream to the Mac in segments rather than piling up on the device.

**Pairing:** the Mac shows a QR code (host / port / token); the phone scans it (or you can enter host/port/token manually). Works over the LAN; **Android** additionally supports **USB** with no shared Wi-Fi (the Mac auto-runs `adb reverse` so the phone reaches `127.0.0.1`). Pairing is stable across Mac restarts (persisted token + pinned port); the QR hides once a phone is paired.

**On the Mac**, each completed document segment pops an **auto-advancing tag card** — add subject tags (with autocomplete from your existing Finder tags) and adjust the phone's date/priority. The card is fully keyboard-driven (↑/↓ to pick a suggestion, ⇥ to complete, ⏎ to add / save, ⌫ to delete the previous tag).

**Two processing modes** (chosen in Settings):

- **Stage for later** — captures collect in Live Capture; send them to Process Files for a normal batch run.
- **Process live** — each segment is **OCR'd on arrival**, tagged (Mac subjects, or the LLM), turned into a **PDF + a renamed copy of the original image** (dual output), merged if multi-page, and staged — all while you keep shooting. At **Finish session** you confirm each collection's name (auto-suggested from the box label's OCR, **fuzzy-matched against existing output folders** so you can append to one). New files are numbered continuing an existing collection's sequence. Processing is durable and resumable: a mid-session crash reloads the staging manifest and never re-OCRs already-processed segments; failed-OCR segments can be retried.

## Architecture

- **Language:** Swift (macOS app + iPhone companion), Kotlin (Android companion)
- **UI:** SwiftUI (macOS native + iPhone companion), Jetpack Compose + CameraX (Android); iPhone capture uses AVFoundation
- **Concurrency:** Swift async/await with TaskGroup for parallel processing (Swift 6 strict concurrency)
- **PDF Generation:** Core Graphics with DCTDecode JPEG embedding and CTFramesetter for text layout
- **Filesystem Tagging:** NSFileManager extended attributes (`NSURLTagNamesKey`, `NSURLLabelNumberKey`)
- **Networking:** URLSession with automatic retry and exponential backoff; a lightweight `NWListener` HTTP receiver for Live Capture (Bearer-token auth; `GET /ping`, `POST /photo`, `POST /session/complete`)
- **Settings sharing:** durable settings persist in `UserDefaults`/`@AppStorage` (shared across the main window and the Settings window) + Keychain for API keys
- **Key Storage:** macOS Keychain via Security framework
- **Project Generation:** XcodeGen (`project.yml`)

## Building

**Prerequisite:** install XcodeGen once — `brew install xcodegen`.

The `.xcodeproj` is **generated and not committed** (`project.yml` is authoritative). So a fresh clone has no project file: you **must** run `xcodegen generate` before opening or building — otherwise Xcode/`xcodebuild` will report a missing project.

**macOS app:**

```bash
cd ArchiveProcessor
xcodegen generate                 # required after clone, and whenever files are added
open ArchiveProcessor.xcodeproj   # build & run in Xcode (macOS target)
```

Headless build (CI / quick check):

```bash
cd ArchiveProcessor && xcodegen generate && \
  xcodebuild -scheme ArchiveProcessor -configuration Debug build
```

Regenerate with `xcodegen generate` whenever files are added — `project.yml` is authoritative; never hand-edit the `.pbxproj`.

**Android companion (optional, for Live Capture):**

```bash
cd ArchiveCapture
./gradlew assembleDebug        # → app/build/outputs/apk/debug/app-debug.apk
```

Sideload the APK to an Android phone, then pair by scanning the QR shown in the Mac app's Live Capture tab (LAN, or USB via `adb reverse`).

**iPhone companion (optional, for Live Capture):**

```bash
cd ArchiveCaptureiOS
xcodegen generate
open ArchiveCaptureiOS.xcodeproj
```

Build and run on an iPhone with Xcode (iOS 17+; camera capture needs a physical device — the simulator has no camera), then pair by scanning the QR shown in the Mac app's Live Capture tab (LAN). `project.yml` is authoritative; regenerate after adding files.

## Project Structure

```
ArchiveProcessor/Sources/ArchiveProcessor/
├── ArchiveProcessorApp.swift          # App entry point (+ Settings scene, ⌘,)
├── ContentView.swift                  # Root view: Process Files / Live Capture / Tools tabs
├── Models/
│   ├── ProviderModels.swift           # LLMProvider, LLMModel, TaggingMode, RotationMode, OCRResult
│   ├── CostEstimator.swift            # Pre-processing cost calculation
│   └── KeychainHelper.swift           # Secure API key storage
├── OCR/
│   ├── OCRProcessor.swift             # Main batch processing orchestrator
│   ├── OCRPrompt.swift                # Prompt builder and response parser
│   ├── AnthropicClient / GeminiClient / MistralClient / OpenAICompatibleClient (gateway)
│   ├── BatchOCR.swift                 # Batch clients for all three providers
│   ├── PDFGenerator.swift             # Output PDF creation
│   ├── PDFTextExtractor / PDFToImageConverter
│   ├── RotationDetector / LLMRotationDetector   # local Vision + LLM rotation
│   └── NetworkSession.swift           # URLSession with retry logic
├── Tagging/
│   ├── DocumentSegmenter.swift        # Document boundary detection
│   ├── TagGenerator.swift             # LLM-based tag generation
│   ├── CollectionSegmenter.swift      # Collection identification and organization
│   ├── MacOSTagger.swift              # macOS Finder tag application (+ trailing "Unread")
│   └── SystemTagsProvider.swift       # Finder-tag autocomplete (background Spotlight)
├── Capture/                           # Live Capture
│   ├── CaptureModels.swift            # CapturedPhoto, CaptureGroup, MacSegmentTags
│   ├── CaptureSession.swift           # Session state, durable manifest, pairing, mode
│   ├── SessionProcessingConfig.swift  # Snapshot of settings for a live session
│   └── LiveCaptureProcessor.swift     # Streaming coordinator (OCR→tag→PDF→stage→finalize)
├── Net/
│   ├── CaptureServer.swift            # NWListener HTTP receiver (Bearer token)
│   └── USBBridge.swift                # adb reverse tunnel for USB pairing
└── Views/
    ├── OCRView.swift                  # Process Files UI + review sheets
    ├── SettingsView.swift             # Settings window (⌘,) + live cost pane
    ├── ToolsView.swift                # Compare Models + Test Resolution
    ├── LiveCaptureView.swift          # Live Capture UI (pairing, status, tag card)
    ├── CollectionFinalizeSheet.swift  # End-of-session collection naming
    ├── KeyboardTokenField.swift       # Keyboard-driven tag entry
    └── DropReceiver.swift             # Native NSView drag-and-drop handler

ArchiveCapture/                        # Android companion app (Kotlin + Compose + CameraX)
└── app/src/main/java/com/archiveprocessor/capture/  # capture/, data/, net/, ui/

ArchiveCaptureiOS/                     # iPhone companion app (SwiftUI + AVFoundation, XcodeGen)
└── Sources/ArchiveCaptureiOS/
    ├── App.swift / ContentView.swift  # Entry point; Connect ⇄ Capture screen switch
    ├── Net/                           # MacEndpoint (QR parse), MacClient (ping/postPhoto/complete)
    ├── Capture/                       # CaptureModels, SessionStore (durable JSON), CaptureViewModel
    ├── Camera/CameraController.swift  # AVFoundation photo capture
    └── UI/                            # CameraPreview, QRScannerView, ConnectScreen, CaptureScreen, SegmentTagSheet
```

## Potential Features

- **OpenAI provider** — add GPT-4o and other OpenAI models as an OCR provider
- **Handwriting recognition mode** — specialized prompting or model selection for handwritten documents
- **Tag statistics dashboard** — summary view showing tag distribution, date coverage, and collection sizes across a processed batch
- **Export tag vocabulary from results** — generate a vocabulary CSV from tags actually used across a collection, for reuse in future runs
- **Batch tag editing** — select multiple files and apply/remove tags in bulk after processing
- **Search and filter** — search processed files by tag, date range, format, or OCR text content
- **Template OCR prompts** — save and load named prompt templates for different document types or collections
- **Side-by-side image viewer** — full-resolution image viewer in the review dialog with pan/zoom for inspecting hard-to-read documents
- **Undo/redo in review** — track classification and rotation changes with undo support during review
- **Auto-detect document language** — identify document language and include it in metadata; optionally translate
- **Duplicate detection** — flag visually similar or identical pages within a collection
- **Export to CSV/spreadsheet** — export all generated metadata (dates, tags, authors, etc.) as a CSV for use in archival management systems
- **Finder Quick Look plugin** — preview OCR text and tags directly from Finder without opening the app
- **Watch folder mode** — monitor a folder and automatically process new images as they appear
