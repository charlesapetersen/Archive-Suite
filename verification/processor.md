# Archive Processor — feature ledger

Format and statuses: [`README.md`](README.md). Written by `W40.b3`, 2026-10-21.

- **Sources the promises were written from (rule 3, before the code was opened):** `ArchiveProcessor/README.md`
  (§Features, §Live Capture), `ArchiveProcessor/CLAUDE.md` (Recovery Core Directive, Primary Functions 1-3, Settings
  & Tools, OCR Output Format; the Implementation Map for feature names only), `ArchiveProcessor/TESTING.md` (Tier 2B
  checklist §2.0-2.14, Tier 2D driver list), `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md` (Runs A-C, Mac side
  only), and `SPEC/tag-format.md` (§Invariants 3, 5, 6, 7 and §2-page PDF structure).
- **Sources read at:** `8a03097c`.
- **Count:** _filled in once the rows are traced._

**Checkpoint 1 holds the promises only.** Each row's *Promise* and *Promised in* were written from the sources above
before any implementation file was opened; *Reached by*, *Real-path test*, *Runtime evidence* and *Status* are
filled in by the trace that follows (rule 3).

The phone side of Live Capture is the capture ledger's ([`capture.md`](capture.md), `C-` rows, `W40.b4`). Rows here
cover the Mac: the receiver, the tag card, the drain gate, staging, finalize and the backup folder.

---

## Shell, settings and keys

### P-01 · Three areas and a Settings window

- **Promise:** the window has three areas chosen at the top — Process Files, Live Capture, Tools — and a native
  Settings window opens with ⌘, holding every durable setting; the tagging mode and output folder stay in Process
  Files.
- **Promised in:** `README.md` intro, §Settings window; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.0, §2.1.

### P-02 · Live cost and time estimate in Settings

- **Promise:** a pinned pane in Settings recomputes, as settings change, the cost (OCR, rotation, tagging,
  collection ID; standard and batch) and the processing time (per phase) of a 1,000-file run at the standard image
  size.
- **Promised in:** `README.md` §Settings window; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.1 last item.

### P-03 · Cost estimate before a Process Files run

- **Promise:** once files are added, Process Files shows the estimated cost before processing, standard and batch
  side by side, updated as files are added or removed and as the model changes.
- **Promised in:** `README.md` §Cloud and on-device OCR, §Other Features; `CLAUDE.md` §Cost Estimator; `TESTING.md`
  §2.2.

### P-04 · Guided API-key setup

- **Promise:** a first-run wizard, and a Set up keys button in Settings, walk the user through creating a key
  (step-by-step, the exact console page); a pasted key is format-checked and confirmed with a live sample-OCR call
  before it is saved; per-provider status chips in Settings show which keys are set and working.
- **Promised in:** `README.md` §Guided API-Key Setup; `CLAUDE.md` Impl Map `ProviderKeySpec`, `KeyValidator`,
  `ProviderKeyWizard`.

### P-05 · Keys only in the Keychain, one field per provider

- **Promise:** each provider (Anthropic, Gemini, Mistral, OpenAI, OpenRouter, Gateway) has its own key field in
  Settings; keys are stored only in the macOS Keychain, masked, never in code, config files or logs.
- **Promised in:** `README.md` §Cloud and on-device OCR, §Guided API-Key Setup, §Settings window; `CLAUDE.md` §API
  Keys & LLM Calls, §Settings & Tools; `TESTING.md` §2.1.

## OCR — readers and routes

### P-06 · Built-in providers and models, with a thinking level

- **Promise:** provider and model dropdowns offer exactly the built-in lists (Anthropic Sonnet/Opus 4.6; Gemini
  with `gemini-3.8-flash` the default; Mistral OCR; OpenAI GPT-5 family, `gpt-5-nano` default; OpenRouter's pinned
  catalog); models that support it get a Low/High thinking dropdown, hidden otherwise.
- **Promised in:** `CLAUDE.md` §LLM Provider & Model Selection, §Thinking Mode; `README.md` provider table;
  `TESTING.md` §2.1. Sources disagree: see Notes.

### P-07 · Custom model IDs

- **Promise:** Settings › Manage custom models… adds extra Anthropic or Gemini model IDs, which then appear in the
  model dropdown, persist across relaunch, and are the model used (named in the PDF's page-2 subheader).
- **Promised in:** `CLAUDE.md` §Custom models; `README.md` §Project Structure (`ModelSelectionStore`); `TESTING.md`
  §2.1, §2.11.

### P-08 · OpenAI-compatible gateway, with an OpenAI preset

- **Promise:** Use gateway routes OCR through any OpenAI-compatible endpoint (base URL, model ID, its own Gateway
  key, user-supplied pricing); batch and LLM rotation are greyed out on that path; Fill in OpenAI preset prefills
  OpenAI's endpoint, cheapest non-reasoning model and pricing.
- **Promised in:** `CLAUDE.md` §Custom models, gateway & Local Agent; `README.md` §Cloud and on-device OCR;
  `TESTING.md` §2.1, §2.10.

### P-09 · A model on this Mac

- **Promise:** in gateway mode, A model on this Mac marks the endpoint as a local LM Studio / Ollama / mlx server;
  Settings recommends a model by the Mac's memory and fills the fields at $0, Check server lists the server's
  models; the route caps tokens, detects a repetition loop in the streamed reply, reads a looped page once more,
  runs one page at a time, never sends a saved key, and escalates a failed page to the cloud only when the user
  allows it.
- **Promised in:** `CLAUDE.md` §A model on this Mac (`W41.app-local-models`, `-fu1`).

### P-10 · Local Agent CLI backend

- **Promise:** with no API key, Local CLI Agent runs OCR, classification, tagging and segmentation through an
  installed, signed-in Claude Code (Gemini CLI and Codex unvalidated); a guided Set up wizard and Detect & Verify
  check are built in; batch and LLM rotation are skipped; the cost shows "Included in your subscription — usage
  limits apply"; PDF headers and history name the CLI and record $0.
- **Promised in:** `README.md` §Cloud and on-device OCR; `CLAUDE.md` §Local Agent CLI backend (`W13.cli-1`…`4`).

### P-11 · Apple Vision on this Mac

- **Promise:** Apple Vision transcribes on-device with no key, network or cost, with language, fast-recognition,
  minimum-confidence and custom-vocabulary controls; with the text-only LLM judgement off, No tagging or Copy source
  tags gives a fully offline run; with it on, only Vision's text (never the image) goes to a separately selected
  direct LLM for classification, dates, segmentation and tags.
- **Promised in:** `README.md` §Cloud and on-device OCR; `CLAUDE.md` §Apple Vision (`W13.vision-1`/`2`).

### P-12 · A second reader for a page Gemini refuses

- **Promise:** a page the default Gemini model refuses is read by a second reader (Claude, then Qwen3.6 27B on
  OpenRouter) rather than coming back empty.
- **Promised in:** `CLAUDE.md` Gemini model list and OpenRouter note (`W41.app-ocr-default`,
  `W41.app-openrouter-fu1`).

### P-13 · Cheap-first OCR cascade

- **Promise:** with an escalation model set (off by default), a page the run's model fails on — cut off, unparsable,
  server error with no text, Gemini refusal — is read again by that model; transport errors, timeouts, rate limits,
  key errors, gateways, the Local Agent and Vision-as-first-reader never escalate; the kept reading is named in the
  PDF header and its cost added to the run; a breaker caps escalations at 20 then a quarter of the run.
- **Promised in:** `CLAUDE.md` §Cheap-first OCR cascade (`W41.app-ocr-cascade`).

### P-14 · Each page's reader chosen by its kind

- **Promise:** with Choose each page's reader by its kind on (off by default), each dropped image is classified on
  the Mac and the guide's first runnable pick for that kind is preselected; each row shows the kind and reader with
  a menu to change it; the estimate adds the price difference; the reader is named in the PDF header.
- **Promised in:** `CLAUDE.md` §Each page's reader by its kind (`W41.app-page-kind`).

### P-15 · Institutional computing text import

- **Promise:** Use institutional computing text… takes a cluster kit's bulk output folder; a page whose image
  SHA-256 matches a record with model and cluster name takes the cluster's text (plus one text-only classification
  call), the PDF header names the cluster and job, every other page is read as usual, and nothing is written to the
  folder or the inputs.
- **Promised in:** `CLAUDE.md` §Institutional computing import (`W41.app-institutional-compute`).

### P-16 · Custom OCR prompt

- **Promise:** the user can append instructions to the default OCR prompt.
- **Promised in:** `README.md` §Cloud and on-device OCR.

### P-17 · Size-based image resolution

- **Promise:** the resolution slider targets a fraction of a standard image size (default 3 MB, set in Settings),
  so larger files are downscaled more and average or small files are left full-resolution.
- **Promised in:** `README.md` §Cloud and on-device OCR, §Size-based image resolution; `TESTING.md` §2.1.

### P-18 · Parallel OCR workers and previous-page image context

- **Promise:** OCR runs in parallel across a configurable worker pool (Settings › Parallel OCR workers, default 4);
  optionally the previous page's image is sent with the current one (Gemini, Anthropic) to improve classification,
  roughly doubling per-image cost, with OCR still parallel.
- **Promised in:** `README.md` §Previous-page image context; `CLAUDE.md` §Concurrency; `TESTING.md` §2.4.

### P-19 · Batch processing

- **Promise:** Anthropic, Gemini and Mistral offer a batch mode at half price; batch state persists to disk and
  survives restarts; a pending batch resumes with one click; a running batch can be cancelled server-side; an
  uncertain submission stops and keeps its recovery journal rather than resubmitting; a finished chunk with no pages
  is re-read, then its files are reported failed without holding up the run.
- **Promised in:** `README.md` §Batch Processing and its two sub-sections; `CLAUDE.md` §Batch Processing;
  `TESTING.md` §2.8, §2.13.

### P-20 · Automatic retry and the retry dialog

- **Promise:** files failing on 429/503/529 are retried with exponential backoff; remaining failures open a dialog
  to retry them, and the loop continues until all succeed or the user continues. A retry reproduces the run's own
  backend and changes only rotation.
- **Promised in:** `README.md` §Automatic Retry; `CLAUDE.md` §W25.retry-backend correction; `TESTING.md` §2.13.
  Sources disagree: see Notes.

### P-21 · Pre-OCRed PDF input

- **Promise:** PDFs that already carry OCR text are processed without OCR calls: text is extracted, classified by
  text-only calls, then tagged and organised normally, without overwriting the input.
- **Promised in:** `README.md` §Pre-OCRed PDF Input; `TESTING.md` §2.9.

## Input

### P-22 · Adding files

- **Promise:** images can be dragged onto the window, chosen in an open panel, or found recursively in a chosen
  folder; JPEG, PNG, TIFF and HEIC are accepted (and PDF for pre-OCRed input), others ignored gracefully.
- **Promised in:** `README.md` §File Input; `CLAUDE.md` §File Input; `TESTING.md` §2.3.

## Output

### P-23 · The two-page PDF

- **Promise:** each input image produces one PDF with the same base name: page 1 the oriented image, page 2 headed
  `Extracted text.` with `[Provider] · [Model] · [D Month YYYY]`, the text all on one page however long; no text →
  `No text returned by model.` and the reason (Gemini's `Recitation` shown clearly).
- **Promised in:** `README.md` §PDF Output; `CLAUDE.md` §OCR Output Format; `SPEC/tag-format.md` §2-page PDF
  structure; `TESTING.md` §2.4, §2.13.

### P-24 · Multi-page documents merged into one PDF

- **Promise:** when enabled, continuation pages are merged with their document-start page into a single multi-page
  PDF.
- **Promised in:** `README.md` §Multi-Page Document Merging.

### P-25 · Rotation detected and corrected

- **Promise:** sideways or upside-down images are detected (locally by Vision, or by the LLM) and output PDFs always
  show them upright; folder photos orient by the folder tab.
- **Promised in:** `README.md` §Image Orientation Correction; `CLAUDE.md` Impl Map `RotationDetector`,
  `LLMRotationDetector`; `TESTING.md` §2.7.

### P-26 · Run log and on-screen errors

- **Promise:** after a run a `.txt` log lists every file that produced no OCR text and why; the full error text is
  visible in the file pane; progress shows in real time.
- **Promised in:** `README.md` §Other Features; `CLAUDE.md` §Batch log file; `TESTING.md` §2.4, §2.13.

### P-27 · Per-segment JSON metadata

- **Promise:** optionally, each segment gets a JSON metadata file.
- **Promised in:** `README.md` §Document Segmentation & Tagging step 4; `CLAUDE.md` Impl Map `SegmentJSONBuilder`.

### P-28 · Enclosure dates

- **Promise:** a page the OCR marks as an enclosure is related to its covering document; the cover's date is
  carried as `Sent With`, and the PDF header shows the source dates; JSON and resume round-trip it.
- **Promised in:** `SPEC/tag-format.md` §W37.dual-date; `CLAUDE.md` Impl Map `DocumentSegmenter.enclosureOf`,
  `DualDateTestDriver`.

## Segmentation and tagging

### P-29 · Every image classified

- **Promise:** every image is classified as Box Label, Folder Label, Document Start or Document Continuation;
  Mistral, which takes no prompt, classifies by text heuristics.
- **Promised in:** `README.md` §Document Classification; `CLAUDE.md` §Document Segmentation.

### P-30 · Choice of segmentation approach

- **Promise:** the user chooses how a run is segmented — manual, Claude, Gemini, ChatGPT, a mix, a model on this
  Mac — each shown with its rough accuracy, how much checking it leaves and its cost (dollars by API key, a share of
  the plan when run on a Claude or ChatGPT subscription).
- **Promised in:** `CLAUDE.md` Impl Map `Segmentation/` (`SegmentationApproach`, `SegmentationChooser`,
  `PlanUsage`, `ChatGPTPlanTransport`, `LocalSegmenter`); `SUITE_TODO_DONE.md` `W36.seg-decision`,
  `W36.seg-opt-chooser`, `W36.seg-opt-subscription`, `W36.seg-opt-siwc`, `W41.app-local-seg`, `W41.app-seg-default`.

### P-31 · Flagged boundaries, then a skim

- **Promise:** with an automatic approach, the boxes and folders are confirmed, the run segments in windows, the
  uncertain boundaries are put to the user one by one (keep, split, join) and every one must be answered before
  Done; then a skim of the whole result; hitting a usage limit or error offers "check the rest myself" or stop, and
  the run resumes from the answered windows.
- **Promised in:** `CLAUDE.md` Impl Map `RunSegmentation`, `OCRProcessor+WindowSegmentation`;
  `SUITE_TODO_DONE.md` `W36.seg-opt-review`, `W36.seg-opt-proof`.

### P-32 · Per-page segmentation review dialog

- **Promise:** after OCR, a full-screen dialog shows every file as a thumbnail (size slider 60-800 px) with
  classification and rotation radio buttons and live preview; keys `1`-`4` set the class, `[`/`]` rotate, `↑`/`↓`
  move, Return confirms.
- **Promised in:** `README.md` §Segmentation Review, §Image Orientation Correction; `TESTING.md` §2.4, §2.6.

### P-33 · Generated tags

- **Promise:** each segment gets a year tag and an `MM Month` tag (`Date Uncertain` and an estimated year when the
  date cannot be read; never an estimated month), 2-6 subject tags, its format, author and recipient.
- **Promised in:** `README.md` §Document Segmentation & Tagging; `CLAUDE.md` §Tags Applied to Each File;
  `TESTING.md` §2.4.

### P-34 · Finder tags written: colour and `Unread` last

- **Promise:** outputs get their tags as macOS Finder tags; boxes are Red, folders Purple (never promoted from a
  subject string); in real-tagging modes `Unread` is appended once, last, on every PDF and exported image; a failed
  tag read is never written over as empty.
- **Promised in:** `README.md` §Document Segmentation & Tagging step 3; `CLAUDE.md` §Special tags; `SPEC/tag-format.md`
  §Invariants 3, 5, 6, 7; `TESTING.md` §2.4.

### P-35 · Tagging modes

- **Promise:** Automatic, Auto date, Human, No tagging and Copy source tags each behave as named: No tagging writes no
  tags and no `Unread`; Copy source passes the source file's tags through verbatim with no `Unread`.
- **Promised in:** `CLAUDE.md` §Special tags; `README.md` §Other Features (source tag pass-through); `SPEC/tag-format.md`
  §Invariant 6; `TESTING.md` §2.5.

### P-36 · Controlled vocabulary

- **Promise:** a subject vocabulary can be typed one per line or imported from CSV (button or drop); when set, the
  LLM may choose only from it.
- **Promised in:** `README.md` §Custom Tag Vocabularies; `TESTING.md` Tier 2D `test-controlled-vocabulary.sh`.

### P-37 · Tagging review

- **Promise:** after tag generation the tags show in the file pane; double-clicking a file edits its
  classification; Redo tagging regenerates with the updated segmentation; Complete proceeds to collection
  organisation.
- **Promised in:** `README.md` §Tagging Review.

### P-38 · Manual per-segment tagging

- **Promise:** in the human and manual-segmentation modes, the user segments and tags each segment in turn, with
  subject autocomplete from existing tags.
- **Promised in:** `CLAUDE.md` Impl Map `ManualTaggingSheet`, `ManualSegmentTagView`, `SystemTagsProvider`;
  `TESTING.md` §2.5 (Human).

### P-39 · Collections identified, named and numbered

- **Promise:** with collection segmentation on, collection names are read from box-label text, similar names are
  clustered and title-cased, the user reviews and corrects them, and output PDFs are filed into collection folders
  as `00001 Collection Name.pdf`, never overwriting an existing file.
- **Promised in:** `README.md` §Collection Segmentation & Organization, §Collection Name Review; `CLAUDE.md`
  Tier-2 list (collection numbering); `TESTING.md` Tier 2D `test-collection-organize.sh`.

### P-40 · Box and folder confirmation

- **Promise:** before segmentation proceeds, every box and folder identification is shown to be confirmed or
  reclassified.
- **Promised in:** `CLAUDE.md` Impl Map `BoxFolderConfirmSheet`, `RunSegmentation`.

## Tools

### P-41 · Compare Models

- **Promise:** one image is run through several provider/model combinations side by side with differences
  highlighted, and a model can be adopted from the results.
- **Promised in:** `README.md` §Tools tab; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.12.

### P-42 · Test Resolution

- **Promise:** one image is OCRed at 10-100% resolution to show the accuracy/cost trade-off, and a resolution can be
  adopted.
- **Promised in:** `README.md` §Tools tab; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.12.

## Live Capture — the Mac side

### P-43 · Pairing by QR

- **Promise:** the Live Capture tab shows one QR (host, port, token, name, and a relay code when signed in to Drive);
  the token and port persist across Mac restarts; the QR hides once a phone pairs; a phone's Re-pair makes the Mac
  show it again. Pairing is QR-only, no discovery.
- **Promised in:** `README.md` §Live Capture (Pairing); `CLAUDE.md` §Pairing + connect flow; `LIVE_CAPTURE_ANDROID_TEST.md`
  A1, A5.

### P-44 · LAN receiver: durable before ack

- **Promise:** each photo is written to the manifest before the Mac acks it, and a resend of the same `(group, seq)`
  replaces rather than duplicates; routes need the bearer token (bad token 401, unknown route 404), with backoff on
  failed auth.
- **Promised in:** `CLAUDE.md` §Streaming + never-lose-a-photo, §LAN transport security, §Pairing (routes);
  `README.md` §Architecture; `LIVE_CAPTURE_ANDROID_TEST.md` C5, C6.

### P-45 · USB tunnel (Android)

- **Promise:** the Mac keeps `adb reverse` asserted so a USB-tethered Android reaches the Mac at `127.0.0.1` with no
  shared Wi-Fi, re-asserting on replug and re-pair.
- **Promised in:** `README.md` §Live Capture; `CLAUDE.md` §USB local relay; `LIVE_CAPTURE_ANDROID_TEST.md` B1, B2.

### P-46 · Google Drive cloud relay, Mac side

- **Promise:** once signed in to Google Drive (Settings › Live Capture, Desktop OAuth client), the Mac pulls the
  phone's objects from Drive during an active session, ingests them through the same pipeline, and deletes each
  object after a durable receipt.
- **Promised in:** `README.md` §Live Capture (Transports); `CLAUDE.md` §Google Drive cloud relay, §Cloud-relay OAuth
  setup; `SPEC/relay-object-format.md`.

### P-47 · Tag card per completed segment

- **Promise:** each completed segment pops an auto-advancing tag card: subject tags with autocomplete from existing
  tags, the phone's date and 0-3 Quality editable (0 writes no tag, 1-3 write `Q1`-`Q3`), fully keyboard-driven.
- **Promised in:** `README.md` §Live Capture (On the Mac); `CLAUDE.md` §On the Mac, §On the phone (Quality);
  `LIVE_CAPTURE_ANDROID_TEST.md` A4.

### P-48 · Finish waits for the phone to drain

- **Promise:** Finish shows "phone still has N to send" and holds finalize until the phone's heartbeat reports
  nothing pending, so no segment finalizes partial.
- **Promised in:** `CLAUDE.md` §On the Mac; `LIVE_CAPTURE_ANDROID_TEST.md` A6.

### P-49 · The backup folder and recovery

- **Promise:** every received photo, and in `_processed/` every staged PDF/JPG/JSON with tags, is kept in
  `~/Pictures/Archive Processor Live Capture/<session>/` until finalize confirms the destination has it; a Backup
  Folder button reveals it; a source is deleted only after its output is confirmed at the destination, and only to
  the Trash.
- **Promised in:** `CLAUDE.md` §Recovery Core Directive, §Backup folder; `README.md` §Live Capture (Backup folder);
  `LIVE_CAPTURE_ANDROID_TEST.md` C4.

### P-50 · Stage for later

- **Promise:** in Stage for later mode captures collect in Live Capture and are sent to Process Files for a normal
  batch run.
- **Promised in:** `README.md` §Live Capture (Two processing modes); `CLAUDE.md` §Two processing modes;
  `LIVE_CAPTURE_ANDROID_TEST.md` B3.

### P-51 · Process live

- **Promise:** in Process live mode each segment is OCRed on arrival, tagged, made into a PDF and a renamed copy of
  the original image, merged if multi-page and staged while shooting continues; at Finish the user confirms each
  collection's name (suggested from the box label, fuzzy-matched to existing folders to append), and new files
  continue the folder's numbering.
- **Promised in:** `README.md` §Live Capture (Two processing modes); `CLAUDE.md` §Two processing modes;
  `LIVE_CAPTURE_ANDROID_TEST.md` A6.

### P-52 · Live sessions survive a crash; failed segments retry

- **Promise:** a mid-session crash reloads the staging manifest and never re-OCRs a processed segment; each
  segment's failure reason shows in the Processing pane, which offers per-item retry, rotate-and-re-run, view text
  and reveal, plus a bulk Retry N failed; retries are refused while finishing.
- **Promised in:** `README.md` §Live Capture (Process live); `CLAUDE.md` §Shared per-item Processing pane;
  `LIVE_CAPTURE_ANDROID_TEST.md` C2.
