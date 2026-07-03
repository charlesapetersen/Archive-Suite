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

---

## Live Capture — Wired Transport Without USB Debugging (feasibility)

The v3.2.0 Live Capture wired mode uses `adb reverse`, which requires **USB debugging** (Developer Options) + a per-computer adb authorization + `adb` on the Mac. That is fine for personal/small-scale use but **cannot ship in a wide-release app** — you can't ask general users to enable Developer Options and trust an RSA key. A normal Android app also cannot open a USB data channel to a host except through the sanctioned USB APIs, so "no debugging" means dropping adb entirely. Options, in order of practicality:

1. **Wi‑Fi instead of USB (easiest, wide-release-ready).** Already supported via QR/manual LAN pairing. For a broad release this is the pragmatic primary transport; wired becomes a power-user extra. Downside: needs a shared network (the reading-room problem).

2. **USB tethering (no Developer Options, but fragile on Macs).** The user toggles Settings → Hotspot & tethering → USB tethering, creating a real network link over the cable; the app does HTTP over it — no debugging/authorization. **But** Android tethering uses RNDIS, which modern Apple‑Silicon macOS does not support without a kernel driver (kexts are largely dead on current macOS). Some newer devices offer NCM (better macOS support) but it's inconsistent. Consumer-friendly on the phone, unreliable on the Mac today — not safe to ship.

3. **Android Open Accessory (AOA) — the proper wide-release wired path.** Android's sanctioned way for an app to talk to a USB *host* with no debugging/root. The Mac acts as USB host via **libusb** (pure user-space, no kext), sends AOA control requests to switch the phone into accessory mode, then bulk-transfers; the Android app implements the `UsbAccessory` side and gets a standard one-time "Allow this app to access the USB device?" prompt (not Developer Options). Distributable and robust, but real engineering: a custom framed protocol on both sides plus a libusb host embedded in the Mac app. Moderate-to-high effort.

**Bottom line:** feasible for wide release, but only by adding **AOA** (option 3) — a real project, not a flag. USB tethering (option 2) is too flaky on current Macs to rely on. Recommended posture for a broad release: make **Wi‑Fi the primary transport**, keep `adb reverse` as a documented power-user/dev option, and invest in **AOA** only if wired-for-everyone becomes a hard requirement.

---

## App-Store Distribution — Phase 4 (deferred)

The distribution initiative (see `DISTRIBUTION_PLAN.md`) is complete through **Phase 3**: guided
BYO-key onboarding (Gemini + Mistral, both confirmed free with no card), and an **iPhone capture
companion** (`ArchiveCaptureiOS/`) alongside the Android one. **Phase 4 — publishing the companion
apps to the App Store and Google Play — is intentionally deferred** and captured here for the future.

Phase 4 is mostly **owner (not Claude) work**, because it needs paid accounts, real hardware, and
signing identities Claude cannot access:

- **[USER] Apple:** enroll in the Apple Developer Program ($99/yr); create the App ID, signing
  certificate, and provisioning profile; run the iOS companion on a physical iPhone to smoke-test the
  camera + LAN pairing (the simulator can't exercise the camera); archive and upload via Xcode /
  App Store Connect; complete the App Privacy questionnaire; submit for review.
- **[USER] Google:** create a Google Play Console account (one-time $25); generate an upload key and
  sign the Android app bundle (`.aab`); complete the Data Safety form; submit.
- **[USER] Assets:** capture screenshots / a short screen-recording of each companion for the store
  listings (Claude can't produce device screenshots of a live camera session).

What **Claude can draft on request** (no accounts needed): the privacy policy, the Play **Data
Safety** form answers, the Apple **App Privacy** "nutrition-label" answers, the store descriptions /
keywords, and the in-app BYO-key onboarding copy. Because neither companion holds API keys or sends
data anywhere except the user's own paired Mac over the LAN, the privacy story is simple (no data
collection / no third-party sharing) — which keeps the questionnaires short.

**Feasibility note:** every code artifact Phase 4 needs already exists and builds; the blockers are
purely account/identity/asset steps that require the owner. Nothing here needs new engineering unless
review feedback demands a change.
