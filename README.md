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
- Custom OCR prompts — append additional instructions to the default OCR prompt
- Image resolution scaling — reduce image resolution (5%–100%) to lower API costs

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

### Model Comparison Testing

Built-in test UI for comparing OCR results across providers and models:

- Select two provider/model combinations to compare side by side
- Diff highlighting shows differences between outputs
- "Use" button to adopt a model directly from test results
- Selections persist across sessions

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
