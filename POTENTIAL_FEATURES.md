# Potential Features

## High Priority

### Search & Browse
- **Full-text search across processed files** — index OCR text for instant search with highlighted results
- **Gallery/grid view** — browse processed images with thumbnails, classification badges, and applied tags
- **Filter by tag** — filter the file list by year, subject, classification, or collection

### Quality & Accuracy
- **OCR confidence scoring** — request confidence levels from the LLM and flag low-confidence pages for human review
- **Side-by-side comparison view** — show original image alongside OCR text for manual verification
- **Multi-model consensus** — run the same image through multiple models and merge/compare results
- **Custom OCR prompts** — allow users to add domain-specific instructions (e.g., "This collection contains legal documents from the 1950s")

### Workflow
- **Processing profiles/presets** — save combinations of provider, model, tagging, and segmentation settings as named profiles
- **Queue system** — add files to a processing queue and process in the background
- **Undo/redo for review changes** — track classification changes in review dialogs with undo support
- **Resume interrupted processing** — save standard (non-batch) processing state for resume after app restart

## Medium Priority

### Export & Integration
- **CSV/spreadsheet export** — export all tags and metadata to CSV for use in archival management systems
- **IIIF manifest generation** — generate IIIF manifests for digital collection platforms
- **EAD/Dublin Core export** — export metadata in standard archival description formats
- **Zotero/Tropy integration** — import/export with popular research tools
- **Finding aid generation** — auto-generate archival finding aids from processed collections

### Tagging Enhancements
- **Custom tag vocabularies** — let users define controlled vocabularies for subject tags
- **Tag suggestions from nearby documents** — use surrounding document context to improve tag accuracy
- **Hierarchical tags** — support nested tag structures (e.g., Politics > Elections > Presidential)
- **Tag editing UI** — edit applied tags directly in the file pane without reprocessing
- **Bulk tag operations** — apply/remove tags across multiple files at once

### Document Processing
- **Multi-page document merging** — combine continuation pages into single multi-page PDFs
- **Handwriting recognition mode** — specialized prompts and processing for handwritten documents
- **Table extraction** — detect and extract tabular data from documents into structured formats
- **Language detection** — identify document language and adjust OCR accordingly
- **Newspaper/periodical layout analysis** — handle multi-column layouts, headlines, captions

### Collection Management
- **Nested collection hierarchy** — support sub-collections (Box > Folder > Document)
- **Collection-level metadata** — assign metadata to entire collections, not just individual documents
- **Cross-collection deduplication** — identify duplicate documents across different collections
- **Collection statistics dashboard** — visualize document counts, date ranges, subject distributions per collection

## Lower Priority

### Performance & Scale
- **Thumbnail caching** — cache generated thumbnails for faster review dialog rendering
- **Incremental processing** — process only new/changed files in a directory
- **Distributed batch processing** — split large jobs across multiple API keys for faster throughput
- **Memory-efficient streaming** — stream batch results instead of loading all into memory

### UI Enhancements
- **Dark mode optimization** — ensure all custom views render correctly in dark mode
- **Keyboard shortcuts** — add shortcuts for common actions (start processing, switch providers, navigate files)
- **Drag to reorder files** — let users reorder the file list before processing
- **Split view for review** — show the original image and OCR text side-by-side in review dialogs
- **Progress notifications** — macOS notifications when batch processing completes

### API & Extensibility
- **OpenAI/GPT-4o support** — add OpenAI as a fourth provider
- **Local model support** — integrate with Ollama or llama.cpp for offline processing
- **Plugin system** — allow custom classification and tagging plugins
- **REST API server mode** — run Archive Processor as a headless service for automation
- **Apple Shortcuts integration** — expose processing actions via Shortcuts app

### Data & Analytics
- **Processing history** — track all processing runs with timestamps, settings, and results
- **Cost tracking** — cumulative cost reporting across all processing runs
- **Accuracy metrics** — compare OCR results against ground truth files for benchmarking
- **Tag frequency analysis** — show most common tags, date distributions, subject clusters
