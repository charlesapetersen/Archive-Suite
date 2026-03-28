# Archive Processor

A native macOS application for processing historical archive photograph collections. Archive Processor performs OCR on scanned documents using multiple LLM providers, generates searchable PDFs, applies intelligent filesystem tags, and organizes files into archival collections.

Built for archivists, historians, and researchers working with large digitized document collections.

## Features

### Multi-Provider LLM OCR

Process scanned images through any of three LLM providers:

| Provider | Models | Thinking Mode | Batch Processing |
|----------|--------|---------------|------------------|
| **Anthropic** | Claude Sonnet 4.6, Claude Opus 4.6 | Low / High | Yes |
| **Google Gemini** | 2.5 Pro, 2.5 Flash, 2.5 Flash Lite, 3 Flash Preview, 3.1 Pro Preview, 3.1 Flash Lite Preview | Low / High | Yes |
| **Mistral** | Mistral OCR 3 | — | Yes |

- Switch providers and models at any time
- API keys stored securely in macOS Keychain
- Cost estimation displayed before processing (standard and batch pricing)

### PDF Output

Each input image produces a two-page PDF:

- **Page 1:** The original image, correctly oriented (rotation detected and applied automatically)
- **Page 2:** Extracted OCR text with provider, model, and date metadata. Page height adjusts dynamically — text never overflows to a third page.

### Image Orientation Correction

The LLM detects if images are rotated sideways or upside down. Output PDFs always show correctly oriented images. For folder photographs, orientation is based on the folder tab rather than document text.

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
4. **Exports JSON metadata** per segment (optional, toggleable)

### Collection Segmentation & Organization

When collection segmentation is enabled:

1. Identifies archival collections from box label OCR text via LLM
2. Clusters similar collection names (handles variations in case, abbreviation, punctuation)
3. Normalizes names to title case with consistent formatting
4. Organizes output PDFs into collection folders with sequential naming (`00001 Collection Name.pdf`)

### Review Dialogs

Two optional review steps let you verify and correct the app's classifications before finalizing:

#### Box/Folder Identification Review
- Thumbnail images (180x180) alongside each box/folder identification
- Radio buttons to reclassify: Box, Folder, or Document
- Editable collection names for boxes
- Resizable dialog window
- Changes propagate to Finder tags and collection segmentation

#### Document Segmentation Review
- Sequential per-collection dialogs after box/folder identification
- Radio buttons: New Document, Continuation, Box, or Folder
- Adjustable thumbnail size via slider (60–400px)
- Reclassifying as Box/Folder triggers collection segment rebuild
- Resizable dialog window

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
- **Progress tracking** — real-time status messages and progress bar
- **Error display** — full error text visible in the file pane
- **Log file** — generated after processing, listing all failures with reasons
- **Secure networking** — ephemeral URLSession, retry with backoff on transient errors, cellular network support

## Architecture

- **Language:** Swift
- **UI:** SwiftUI (macOS native)
- **Concurrency:** Swift async/await with TaskGroup for parallel processing
- **PDF Generation:** Core Graphics with DCTDecode JPEG embedding and CTFramesetter for text layout
- **Filesystem Tagging:** NSFileManager extended attributes (`NSURLTagNamesKey`, `NSURLLabelNumberKey`)
- **Networking:** URLSession with automatic retry and exponential backoff
- **Key Storage:** macOS Keychain via Security framework
- **Project Generation:** XcodeGen (`project.yml`)

## Building

```bash
cd ArchiveProcessor
xcodegen generate
open ArchiveProcessor.xcodeproj
```

Build and run with Xcode (macOS target).

## Project Structure

```
ArchiveProcessor/Sources/ArchiveProcessor/
├── ArchiveProcessorApp.swift          # App entry point
├── ContentView.swift                  # Root view
├── Models/
│   ├── ProviderModels.swift           # LLMProvider, LLMModel, OCRResult, OCRJob
│   ├── CostEstimator.swift            # Pre-processing cost calculation
│   └── KeychainHelper.swift           # Secure API key storage
├── OCR/
│   ├── OCRProcessor.swift             # Main processing orchestrator
│   ├── OCRPrompt.swift                # Prompt builder and response parser
│   ├── AnthropicClient.swift          # Anthropic Messages API client
│   ├── GeminiClient.swift             # Google Gemini API client
│   ├── MistralClient.swift            # Mistral OCR API client
│   ├── BatchOCR.swift                 # Batch clients for all three providers
│   ├── PDFGenerator.swift             # Output PDF creation
│   ├── PDFTextExtractor.swift         # Text extraction from existing PDFs
│   ├── PDFToImageConverter.swift      # PDF-to-JPEG conversion for OCR
│   └── NetworkSession.swift           # URLSession with retry logic
├── Tagging/
│   ├── DocumentSegmenter.swift        # Document boundary detection
│   ├── TagGenerator.swift             # LLM-based tag generation
│   ├── CollectionSegmenter.swift      # Collection identification and organization
│   └── MacOSTagger.swift              # macOS Finder tag application
└── Views/
    ├── OCRView.swift                  # Main UI with all controls and review sheets
    └── DropReceiver.swift             # Native NSView drag-and-drop handler
```
