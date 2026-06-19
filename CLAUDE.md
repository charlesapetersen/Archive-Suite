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

### API Efficiency for Tagging
- Minimize API calls — batch OCR results where possible before making tagging calls
- Reuse OCR output; do not re-query the image for tagging if text is already extracted

---

## Test Files
- Located in `Test Files/` directory within the project
- Contain a wide range of document types
- **Do not delete or modify any test files**
- Only create new output files

---

## API Keys
- **Do not store API keys in code or config files**
- Do not run up costs
- Before any test run: (1) write a test plan, (2) estimate the cost, (3) request the appropriate API key from the user
- For tests, prefer lower-cost models (e.g., gemini-2.5-flash-lite, claude-sonnet-4-6)

---

## Architecture Notes (macOS Native)
- Language: Swift
- UI framework: SwiftUI (or AppKit where needed)
- Concurrency: Swift concurrency (async/await + TaskGroup) for parallel OCR workers
- PDF generation: PDFKit (with dynamic page sizing for text page)
- Filesystem tagging: `NSFileManager` extended attributes or `tag` CLI tool
- Networking: URLSession for LLM API calls

---

## Project Structure (planned)
```
Archive Processor/
├── CLAUDE.md
├── Archive Processor.xcodeproj/
├── Sources/
│   ├── App/
│   ├── OCR/          # LLM provider clients, batch logic
│   ├── Tagging/      # Document segmentation, tag application
│   ├── PDF/          # PDF generation (PDFKit)
│   └── UI/           # SwiftUI views
├── Test Files/       # Do not modify
└── Test Outputs/     # Generated PDFs and log files from test runs
```
