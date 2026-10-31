# Archive Processor

A native macOS application for processing historical archive photograph collections. Archive Processor performs OCR on scanned documents using cloud LLM providers or on-device Apple Vision, generates searchable PDFs, applies intelligent filesystem tags, and organizes files into archival collections.

Built for archivists, historians, and researchers working with large digitized document collections.

The app has three areas, selectable at the top of the window, plus a native Settings window:

- **Process Files** — drop in images (or a folder) and run OCR + tagging + organization as a batch.
- **Live Capture** — photograph documents with an **Android or iPhone** companion app and stream them to the Mac; optionally OCR/tag/PDF **each segment as you shoot** so processing finishes with capture.
- **Tools** — one-off diagnostics: compare OCR across models, test how image resolution affects OCR, and look back over past runs.
- **Settings (⌘,)** — all durable settings (provider, model, API key, rotation, tagging options, live-capture mode) in one place, with a live cost estimate for 1,000 files that updates as you change settings.

## Features

### Cloud and on-device OCR

Process scanned images through any of five cloud LLM providers or the free, local Apple Vision backend:

| Provider | Models | Thinking Mode | Batch Processing |
|----------|--------|---------------|------------------|
| **Anthropic** | Claude Sonnet 4.6, Claude Opus 4.6 | Low / High | Yes |
| **Google Gemini** | 3.8 Flash (default), 3.5 Flash Lite, 3.1 Flash Lite, 3.5 Flash, 3.1 Pro, 3 Flash Preview, 2.5 Flash, 2.5 Flash Lite, 2.5 Pro | Low / High | Yes |
| **Mistral** | Mistral OCR 3 | — | Yes |
| **OpenAI (ChatGPT)** | GPT-5 nano (default), GPT-5 mini, GPT-5.4 mini, GPT-5.4, GPT-5.5 | Low / High (reasoning models) | — |
| **OpenRouter** | Qwen3-VL 235B (default), Qwen3.6 27B, GLM-5.3 Flash — each pinned to one host | — | — |
| **Apple Vision** | macOS Vision | — | — |

- Also supports an **OpenAI-compatible API Gateway** (custom base URL + model ID) for self-hosted or proxied endpoints, with user-supplied pricing for cost estimates — including a one-click **"Fill in OpenAI preset"** that prefills OpenAI's public endpoint, model, and pricing (a custom base URL then covers **Azure OpenAI** / proxies)
- Or a **Local Agent CLI backend** — for an enterprise/subscription **Claude Code**, **Gemini CLI**, or **OpenAI Codex** entitlement with **no API key**: pick *Local CLI Agent* in Settings, point it at the installed CLI, and OCR runs through your existing subscription login (a guided *Set up* wizard for Claude Code and Gemini CLI, and a *Detect & Verify* check, are built in; Codex is chosen in the Settings tool picker). Only Claude Code has been checked end to end so far. Batch mode is skipped on this path; cost shows "Included in your subscription — usage limits apply."
- Or choose **Apple Vision (on this Mac)** in Settings for free, on-device transcription with no API key or network request. It uses the Mac's performance cores and exposes language, fast-recognition, confidence, and custom-vocabulary controls. With **Use an LLM for text-only judgement** off, choose **No tagging** or **Copy source file tags** for a fully offline, fully free run. Turn it on to send only Vision's extracted text (never the image) to a separately selected direct LLM for classification, dates, segmentation, and generated tags. Vision is strongest on clean typescript and weaker on handwriting or heavily skewed scans, where cloud vision-language models can be preferable, so it remains an added backend rather than the default.
- Switch providers and models at any time (in **Settings**)
- API keys stored securely in macOS Keychain
- Cost estimation displayed before processing (standard pricing, and batch pricing too when batch mode is on)
- Custom OCR prompts — append additional instructions to the default OCR prompt
- Image resolution scaling — **size-based** (target a fraction of a standard image size; see below) to lower API cost and time, downscaling large files more

### Guided API-Key Setup

You bring your own API keys, and the app makes that easy. A **first-run wizard** (and a **Set up keys**
button in Settings) walks you through creating and pasting a **free** Gemini or Mistral key — both
providers offer an OCR-capable free tier with **no credit card required** — or a pay-as-you-go **Anthropic**
or **OpenAI** key (an OpenRouter key is pasted straight into Settings):

- Step-by-step instructions with the exact console page to open for each provider
- Paste-and-validate: a key that doesn't look right gets a warning, and **Validate key** confirms it with a
  cheap live call to the provider (no page is read) and saves it once it passes — so a mistyped or
  wrong-provider key is caught immediately. A separate **Test OCR on a sample page** button then reads one
  synthetic page, if you want to see it work
- Per-provider status chips in Settings show at a glance which keys are set and working
- Keys are stored only in the macOS Keychain — never in code, config files, or logs

### PDF Output

Each input image produces a two-page PDF:

- **Page 1:** The original image, correctly oriented (rotation detected and applied automatically)
- **Page 2:** Extracted OCR text with provider, model, and date metadata. Page height adjusts dynamically — text never overflows to a third page.

### Multi-Page Document Merging

When enabled, continuation pages are merged into a single PDF with their document start page. A multi-page letter produces one multi-page PDF rather than separate files per page.

### Image Orientation Correction

The LLM detects if images are rotated sideways or upside down, and output PDFs show them upright. For folder photographs, orientation is based on the folder tab rather than document text. Mistral, an API Gateway and the Local Agent have no LLM rotation check, so with them the app uses the Mac's own detector, which is less accurate; it does the same if the LLM check fails. Detection can also be set to the Mac's detector only, or off.

To check rotation by hand, turn on **Review rotation** in Settings (it needs a detection mode). It is its own short pass, before the segmentation review: radio buttons for 0°, 90°, 180°, 270° with live thumbnail preview, and `[`/`]` rotate the focused image in 90° increments.

### Document Classification

Every image is automatically classified as one of:

- **Box Label** — photograph of an archival storage box
- **Folder Label** — photograph of a folder tab or divider
- **Document Start** — first page of a new document
- **Document Continuation** — subsequent page of the same document

Mistral (which uses a dedicated OCR endpoint without prompt support) classifies via text heuristics instead; for pre-OCRed PDFs it uses a short text-only Mistral chat call. Apple Vision returns no classification unless its text-only LLM judgement is turned on.

### Previous-page image context

Optionally send the **previous page's image** alongside the current one to improve classification
(box / folder / document continuation). It is used only when the OCR model's own page labels segment the run
(Automatic tagging with Manual segmentation), and not for pre-OCRed input; it roughly doubles per-image cost and
**keeps OCR running in parallel**. (An earlier free-text
"previous text context" slider was removed; OCR always runs in parallel now, across a configurable worker
pool — *Settings › Parallel OCR workers*, default 4.)

### Batch Processing

Anthropic, Gemini, and Mistral support batch processing for lower-cost, asynchronous OCR (OpenAI's Batch API is a later phase):

- Toggle batch mode in the UI
- Batch state persists to disk — survives app restarts
- Resume pending batches with a single click
- Cancel running batches (server-side cancellation)
- Cost estimator shows batch discount (50% for all providers)

#### If a batch submission reports an uncertain outcome

Very rarely, the provider can accept a batch and its reply can be lost on the way back (a dropped
connection at exactly the wrong moment). The app never guesses in that situation: it stops, keeps the
recovery journal, and says

> Batch submission outcome is uncertain. No server job was acknowledged, but a create whose reply was lost
> may still have been accepted. The recovery journal was kept. Review before retrying.

**Do not just press Resume — check the provider's own console first.** The app cannot list your batches
on the provider side, so it cannot tell whether that batch exists there; retrying blind is the one way to
pay for the same pages twice. Nothing has been lost either way — your originals are untouched and no
output was written.

- **Anthropic** — Console → *Batches* (https://console.anthropic.com)
- **Gemini** — Google AI Studio / Cloud console → *Batch jobs* (https://aistudio.google.com)
- **Mistral** — La Plateforme → *Batch* (https://console.mistral.ai)

Look for a job created in the last few minutes with roughly your page count. If one is there, let it
finish and resume from it; if there is none, the submission never landed and it is safe to run again.

The sibling message *"Batch submission stopped after N server jobs had been created"* is the case where
the app **does** know what it made. Read the sentence that follows it, because it is the one that tells you
whether Resume is enough:

- *"The recovery journal was kept, so Resume can pick the batch up."* — the benign case. All N jobs are
  recorded; press Resume. **A Stop pressed mid-submission normally lands here.** A job the provider created
  in the instant Stop arrived is still written into the journal, and you will see the sentence *"A paid batch
  job was created just as Stop landed. Its server ID was added to the recovery journal, so Resume can still
  reach it."* The submission stops either way — Stop is never answered by creating more jobs.
- *"…but K server jobs are missing from it, so Resume will not reach them."* — K jobs were created and
  billed, but the app could not write their IDs down (a failed journal write, or a Stop that arrived after
  the journal had already been removed). Resume collects the rest; the K missing ones need the provider
  console, as above.
- *"No recovery journal is on disk…"* — the app has no local record at all. Go to the provider console.

The count in that message is always the number of jobs the app **created**, not the number it managed to
record — it is never quietly rounded down to what survived (W16.bat3-fu2).

#### If a finished chunk comes back with no pages

A batch is sent as one or more chunks, and a chunk the provider reports as *finished* is expected to carry
pages. If one comes back empty, the app re-reads it for a few minutes — a job can flip to "succeeded" a
moment before its results are attached, and that resolves itself. If it is still empty it says

> A finished batch chunk returned no pages after 5 checks. Its files are reported as failed; nothing was
> marked complete for it.

and then lets the run finish normally. Two things matter here. That chunk is never written off as done, so
nothing claims pages arrived that did not. And the run is not held hostage to it: every other chunk still
lands, the files from the empty chunk are listed as failed like any other failure, and the retry pass can
re-run just those pages. Files whose pages had already been retrieved on an earlier pass stay done.

This is rare and means the provider reported a finished job it then had nothing to hand back — for example a
result file asked for long after the provider stopped keeping it (Gemini discards batch output after about
two days). Look the job up in the provider's console before re-running the pages, since re-running them is a
new, billable request.

### Automatic Retry

- **Auto-retry:** a rate-limited request (429) is retried with exponential backoff, and files that still fail on rate limits or server overload (429, 503, 529) get one more automatic pass about 10 seconds later
- **User retry dialog:** After auto-retry, remaining failures prompt a dialog where you can retry them. A retry uses the run's own provider, model and key (only the image rotation can be changed). The retry loop continues until all files succeed or you choose to continue.

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

- **Manual entry** — type the allowed tags directly, one per line
- **Import from CSV** — load a controlled subject-tag vocabulary from a CSV/text file via the **Import from CSV** button or by **dropping** the file onto the vocabulary editor

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
- Full keyboard navigation:
  - `1`–`4` — set classification (`1` and `2`, the document classes, only where they are shown)
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
- **Test Resolution** — OCR one image at 10, 20, 40, 60, 80 and 100% resolution and compare each reading with the full-size one (a similarity score and a word diff), then adopt a resolution. It shows the text, not the cost, and needs an API key, so it doesn't run with Apple Vision.
- **Processing History** — past Process Files runs: provider and model, file counts, and each run's estimated cost. No API key needed.

### Settings window (⌘,)

All durable settings live in a native macOS Settings window: provider/model/API mode, a **separate API-key field per provider** (Anthropic / Gemini / Mistral / OpenAI / OpenRouter, plus Gateway when the gateway is on, each in the Keychain), Apple Vision's no-key local controls, input & processing (pre-OCR, batch, image resolution), rotation, tagging & segmentation options, custom models, and the Live Capture processing mode. The tagging **mode** dropdown is in Settings and also in the Process Files view for quick access; the output folder is chosen in the Process Files view.

**Appearance** (top of Settings): System (the default, follows macOS), Light or Dark. The choice applies at once to every window, sheet and panel, and is restored at the next launch. The same setting, under the same name, is in the Reader and Notes.

A **pinned pane on the right** recomputes live for 1,000 files (at your standard image size) as you change settings:

- **Cost** — broken out by phase: OCR, **rotation** (LLM rotation calls, which weren't counted before), tagging, collection ID and segmentation, with a standard total and, when batch mode is on, a batch total. Apple Vision, the Local Agent and a gateway with no pricing show a note in place of dollar figures.
- **Time** — an estimate of *processing* time (network + LLM generation only, not human interaction), broken out per phase, calibrated from measured latencies and the pipeline's concurrency (OCR 4-wide, tagging 6-wide; rotation overlaps OCR). Interactive (non-batch) processing; batch mode returns asynchronously.

### Size-based image resolution

The image-resolution slider is a **target fraction of a standard image size** (default 3 MB, configurable in Settings), not a fixed percentage of each file's dimensions. At 100% it targets the standard size, so **larger files are downscaled more** while average/small files are left full-resolution — evening out cost and time across a collection. Batch runs don't do this yet: they scale every image by the plain slider percentage, so at 100% a large scan goes up whole.

### Pre-OCRed PDF Input

Process PDFs that already contain OCR text (e.g., from a previous run):

- Extracts text without API calls
- Classifies via text-only LLM calls (no image processing)
- Applies tagging and collection segmentation normally
- Useful for re-tagging or re-organizing previously processed files

### File Input

- **Drag and drop** images onto the app window
- **File selection** via standard macOS open panel
- **Directory selection** — adds the images in the selected folder (for now only its top level: images in sub-folders are not picked up)
- Supported formats: JPEG, PNG, TIFF, HEIC, plus PDF (a multi-page PDF is read again page by page; with pre-OCRed input, PDFs only)

### Other Features

- **Cost estimator** — shows estimated cost before processing, updated dynamically as options change
- **Source tag pass-through** — optionally copy existing Finder tags from source files to output PDFs
- **Progress tracking** — real-time status messages and progress bar
- **Error display** — full error text visible in the file pane
- **Log file** — optional (*Write a processing log file* in Settings, off by default): a `.txt` written after processing, listing all failures with reasons
- **Secure networking** — ephemeral URLSession, retry with backoff on transient errors, cellular network support

## Live Capture (phone companion + streaming)

Photograph documents with a phone and stream them straight into the pipeline — no scanner, no manual import. This is the **Live Capture** tab plus a companion app for **Android** (`ArchiveCapture/`, Kotlin + Jetpack Compose + CameraX) or **iPhone** (`ArchiveCaptureiOS/`, SwiftUI + AVFoundation). Both companions speak the same streaming protocol and offer the same capture workflow; pick whichever phone you have.

**On the phone:** shoot document pages with a full-resolution shutter; mark **Box** (red) and **Folder** (purple) with dedicated buttons; **End segment** finishes a document. Minimal on-phone tagging per segment: **Quality** (Unrated or Q1–Q3, with a per-page Q3 override via long-press) and **year/month**. Photos and their grouping/tags are written to disk immediately and uploaded via a durable, auto-retrying queue — so a photo (which can't be re-taken) is never lost, even across an app crash or an unplugged cable. (On Android, if the phone's saved record was out of date when the app died, the photos it recovers are held on the phone until you tap **Review** to tag and send them.) As each segment is confirmed on the Mac, its photos **leave the phone** (with a transfer animation), so images stream to the Mac in segments rather than piling up on the device.

**Pairing:** the Mac shows a QR code (host / port / token); the phone scans it (or you can enter host/port/token manually). The Android app first asks how the phone is connected (Wired, Wi-Fi or Cloud) before it scans. Works over the LAN; **Android** additionally supports **USB** with no shared Wi-Fi (the Mac auto-runs `adb reverse` so the phone reaches `127.0.0.1`). Pairing is stable across Mac restarts (persisted token + pinned port); the QR hides once a phone is paired. Once paired, the phone opens straight to the capture screen — use **Re-pair** there to return to the scanner and switch connection (e.g. from USB to Wi-Fi) or Macs; captured photos are kept and upload once reconnected.

**Transports (all behind one seam — same never-lose-a-photo pipeline):** direct **LAN** (default), **USB local relay** (Android, `adb reverse`), and a **Google Drive cloud relay** — the wireless fallback for **client-isolated networks** (public/guest/airport Wi-Fi that blocks device-to-device) and **off-site** capture. In cloud mode the phone uploads each captured object to the user's Google Drive and the Mac pulls + ingests them through the same segment pipeline (the Mac deletes each object after a durable receipt). The Mac side ships, and so does the **Android** phone side (checked end to end over a real Drive account; `drive.file` scope). On the **iPhone** the Drive transport is built, but Drive sign-in does not work yet: the app still carries a placeholder Google sign-in client id.

**On the Mac**, each completed document segment pops an **auto-advancing tag card** — add subject tags (with autocomplete from your existing Finder tags) and adjust the phone's date/0–3 Quality rating. `0` is Unrated and writes no tag; `1`–`3` write canonical `Q1`–`Q3`. Tagging and saving are keyboard-driven (↑/↓ to pick a suggestion, ⇥ to complete, ⏎ to add a tag or, on an empty field, save and advance, ⌫ to delete the previous tag, esc to clear what you typed); **Skip** is a button only.

**Backup folder.** Every photo received from the phone is also kept in a durable, easy-to-find folder — **`~/Pictures/Archive Processor Live Capture`** — until the run's output is fully written. A **Backup Folder** button in the Live Capture tab opens it in Finder, so if anything goes wrong you can recover and copy the original photos yourself (they can't be re-taken).

**Two processing modes** (chosen in Settings):

- **Stage for later** — captures collect in Live Capture; send them to Process Files for a normal batch run.
- **Process live** — each segment is **OCR'd on arrival**, tagged (Mac subjects, or the LLM), turned into a **PDF + a renamed copy of the original image** (dual output), merged if multi-page, and staged — all while you keep shooting. At **Finish session** you confirm each collection's name (auto-suggested from the box label's OCR, **fuzzy-matched against existing output folders** so you can append to one). New files are numbered continuing an existing collection's sequence. Processing is durable and resumable: a mid-session crash reloads the staging manifest and never re-OCRs already-processed segments; failed-OCR segments can be retried.

## Architecture

- **Language:** Swift (macOS app + iPhone companion), Kotlin (Android companion)
- **UI:** SwiftUI (macOS native + iPhone companion), Jetpack Compose + CameraX (Android); iPhone capture uses AVFoundation
- **Concurrency:** Swift async/await with TaskGroup for parallel processing (Swift 6 strict concurrency)
- **PDF Generation:** Core Graphics with DCTDecode JPEG embedding and CTFramesetter for text layout
- **Filesystem Tagging:** NSFileManager extended attributes (`NSURLTagNamesKey`, `NSURLLabelNumberKey`)
- **Networking:** URLSession with automatic retry and exponential backoff. Live Capture rides one transport-agnostic ingest seam: a lightweight `NWListener` HTTP receiver for the LAN/USB routes (Bearer-token auth; `GET /ping`, `POST /photo`, `POST /segment/complete`, `POST /session/complete`, `POST /phone/status`, `POST /session/disconnect`), plus a Google Drive object-store relay (`RelayObjectStore`/`FileRelay`) for the wireless cloud fallback
- **Settings sharing:** durable settings persist in `UserDefaults`/`@AppStorage` (shared across the main window and the Settings window) + Keychain for API keys
- **Key Storage:** macOS Keychain via Security framework
- **Project Generation:** XcodeGen (`project.yml`)

## Building

**Quick start:** `./bootstrap.sh` — installs XcodeGen (if needed) and generates every Xcode project; pass `--open` to also open the macOS app. Then build & run in Xcode. (Manual steps are below if you prefer.)

The `.xcodeproj` is **generated and not committed** (`project.yml` is authoritative), so a fresh clone has no project file: run `./bootstrap.sh` (or `xcodegen generate`) before opening or building — otherwise Xcode/`xcodebuild` reports a missing project. For the manual path, install XcodeGen once: `brew install xcodegen`.

**macOS app:**

```bash
cd macOS
xcodegen generate                 # required after clone, and whenever files are added
open ArchiveProcessor.xcodeproj   # build & run in Xcode (macOS target)
```

Headless build (CI / quick check):

```bash
cd macOS && xcodegen generate && \
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
ArchiveProcessor/macOS/Sources/ArchiveProcessor/
├── ArchiveProcessorApp.swift          # App entry point (+ Settings scene, ⌘,)
├── ContentView.swift                  # Root view: Process Files / Live Capture / Tools tabs
├── Models/
│   ├── ProviderModels.swift           # LLMProvider, LLMModel, TaggingMode, RotationMode, GatewayConfig, OCRResult
│   ├── ModelSelectionStore.swift      # User-added custom model IDs (Manage custom models…)
│   ├── ProviderKeySpec.swift          # Per-provider key format/validation specs (guided setup)
│   ├── CostEstimator.swift            # Pre-processing cost calculation
│   ├── TimeEstimator.swift            # Per-phase processing-time estimates
│   └── KeychainHelper.swift           # Secure API key storage
├── OCR/
│   ├── OCRProcessor.swift             # Core @MainActor orchestrator: stored state + member types (methods live in the extensions below)
│   ├── OCRProcessor+{Pipeline,OCR,Tagging,ReviewFlows}.swift  # method clusters split by concern (for concurrent work)
│   ├── OCRProcessor+Types.swift       # top-level review/tag model types (CollectionReviewItem, ManualTagSegment, …)
│   ├── OCRPrompt.swift                # Prompt builder and response parser
│   ├── AnthropicClient / GeminiClient / MistralClient / VisionClient / OpenAICompatibleClient (gateway)
│   ├── BatchOCR.swift                 # Batch clients for all three providers
│   ├── ImageEncoding.swift            # Image downscaling / base64 encoding for API calls
│   ├── KeyValidator.swift             # Live key check via one cheap call (guided setup)
│   ├── SampleOCRTester.swift          # Optional sample-page OCR test via a synthetic-token page
│   ├── PDFGenerator.swift             # Output PDF creation
│   ├── PDFTextExtractor / PDFToImageConverter
│   ├── RotationDetector / LLMRotationDetector   # local Vision + LLM rotation
│   └── NetworkSession.swift           # URLSession with retry logic
├── Tagging/
│   ├── DocumentSegmenter.swift        # Document boundary detection
│   ├── TagGenerator.swift             # LLM-based tag generation
│   ├── CollectionSegmenter.swift      # Collection identification and organization
│   ├── MacOSTagger.swift              # macOS Finder tag application (+ trailing "Unread")
│   └── SystemTagsProvider.swift       # Subject autocomplete over the persisted TagVocabulary
├── Capture/                           # Live Capture
│   ├── CaptureModels.swift            # CapturedPhoto, CaptureGroup, MacSegmentTags
│   ├── CaptureSession.swift           # Session state, durable manifest, pairing, mode
│   ├── SessionProcessingConfig.swift  # Snapshot of settings for a live session
│   ├── LiveCaptureProcessor.swift     # Streaming coordinator (OCR→tag→PDF→stage→finalize)
│   └── LiveCaptureTestDriver.swift    # Test harness driving the live-staging pipeline
├── Net/
│   ├── CaptureServer.swift            # NWListener HTTP receiver (Bearer token)
│   ├── USBBridge.swift                # adb reverse tunnel for USB pairing (Android)
│   └── USBMuxBridge.swift             # usbmux tunnels for USB pairing (iPhone)
└── Views/
    ├── OCRView.swift                  # Process Files UI — main view (controlPanel + filePanel)
    ├── OCRView+*.swift                # extracted sheets/rows/diff: FileRowView, OCRRetrySheet, Segmentation/DocumentSegment/Collection review sheets, ModelSelection/ModelTestResults/ModelTestTypes, Resolution drop/test sheets, WordDiff
    ├── SettingsView.swift             # Settings window (⌘,) + live cost pane
    ├── ManageModelsView.swift         # Add/remove custom model IDs
    ├── ProviderKeyWizard.swift        # Guided first-run BYO-key setup
    ├── ToolsView.swift                # Compare Models + Test Resolution + Processing History
    ├── LiveCaptureView.swift          # Live Capture UI (pairing, status, tag card)
    ├── CollectionFinalizeSheet.swift  # End-of-session collection naming
    ├── BoxFolderConfirmSheet.swift    # Confirm box/folder markers during review
    ├── ManualSegmentTagView.swift / ManualTaggingSheet.swift  # Manual segmentation + tagging UI
    ├── TagInputField.swift / KeyboardTokenField.swift         # Keyboard-driven tag entry
    ├── ArchiveThumbnail.swift / ZoomableImageView.swift       # Thumbnail + pan/zoom image views
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

The planned/wishlist backlog — search & browse, exports (CSV / IIIF / EAD), hierarchical tags, handwriting mode, local models, and more — is tracked in [POTENTIAL_FEATURES.md](POTENTIAL_FEATURES.md).
