# One app: Vision OCR's engine inside Archive Processor

Written 14 October 2026 for the owner's review. Status: **draft, decisions of 14 October recorded below; the build
has not been approved.** Part 1 is for the owner. Part 2 is the detail a session works from.

## Part 1 — the plan in brief

### The goal (owner, 14 October 2026)

One app that takes a group of files and works out the best way to read them within the user's limits. A user might
want Vision for scanned academic articles, a local model such as Falcon-OCR for newspaper pages, another local model
for typewritten letters, and a paid model for handwritten letters. The app works out of the box with Vision alone
and then guides the user to the best mix for the documents they actually have.

### Decisions (owner, 14 October 2026)

1. **Archive Processor is the app.** It takes in Vision OCR's engine. The standalone Vision OCR app gets one last
   release that tells its users where to go, and then stops updating.
2. **Output is the user's choice, set as a default for each input format and each kind of page.** The choices are
   Vision OCR's searchable PDF (the page image with an invisible text layer placed on the words) and Archive
   Processor's image followed by a page of text. When the image-plus-text form is chosen, the image can also be made
   a searchable PDF, so the text is present twice.
3. **Sequencing.** Reader and Notes, and the suite-wide W40 checks that do not depend on Archive Processor, carry on
   with the verification phase and freeze. Archive Processor's W40 items wait until the integration is built and run
   once, on the integrated app. The phase's last three steps (re-run every journey, the release candidate, the owner's
   acceptance pass) come at the end for all three apps. The plan is written now; building starts when Vision OCR's
   current queue is finished and its release is cut.
4. **The limits a user can set:** money, local only, time, and a quality floor.
5. **OpenRouter becomes an OCR provider in the app** (owner, 14 October), so the less expensive models the W41
   bake-off measures through it are also routes a user can choose.

### Why it is workable

Most of the pieces exist; they are in two apps.

- Vision OCR has the reading engine: Vision, Falcon-OCR and PaddleOCR-VL running locally under a memory guard, a
  layout model, page-kind detection for newspapers, and the searchable-PDF writer with JBIG2 and layered
  compression. Its key technique is that any model's words are fitted onto the lines Vision finds, so even a model
  that returns plain text can produce a correctly placed text layer.
- Archive Processor has everything around the reading: the paid providers (Gemini, Claude, OpenAI, Mistral, any
  OpenAI-style gateway, and the subscription command-line tools), keys in the Keychain, cost and time estimates,
  classification of box labels, folder labels and document starts, rotation, segmentation into documents, Finder
  tags, and Live Capture from a phone.
- Both apps already have the screen this goal needs, in two halves. Vision OCR's Accurate mode lists each reader
  with measured mistakes, speed and memory. Archive Processor's segmentation chooser lists each approach with
  measured accuracy and cost and shows only the routes the user can use. The integrated app needs one chooser of
  that kind, organised by kind of page.
- The W41 bake-off is the router's evidence. Its report is to give mistakes, cost and speed by kind of page and by
  the Mac's memory, which is the table the app recommends from.

### What is hard

1. **Telling the kind of page cheaply, before choosing how to read it.** Vision OCR tells newspapers from everything
   else using Vision's line shapes alone. Typed, handwritten and photographed pages are not detected yet
   (photographed pages are next in Vision OCR's queue). Handwriting matters most, because it is where a paid model is
   worth paying for.
2. **Placing text on handwriting.** Vision finds handwritten lines poorly, so a paid model's reading of a letter may
   not fit onto Vision's lines. Those pages need a text layer that is not placed word by word, or the text page.
3. **Two code bases built differently.** Vision OCR is about 26,000 lines of Swift compiled with `swiftc` from a
   script, with no package and one test file of about 24,000 lines. Archive Processor is about 54,000 lines, built
   with XcodeGen and a shared Swift package, and tested by running the app. Neither has a common interface for its
   readers or providers.
4. **Checking it.** Archive Processor has no ordinary tests of its own code. The integration is the moment to give
   the engine and the router real tests, because the router's choices are what users will trust.

### The stages

| Stage | What it delivers | Rough size |
|---|---|---|
| 0. Now | This plan; Vision OCR finishes its queue and releases; W41 finishes its report | (under way) |
| 1. The engine as a package | Vision OCR's engine builds as a Swift package inside Archive Suite, with its tests passing there | 3-5 sessions |
| 2. One way to read a page | Vision, the local models and every paid provider behind one interface in Archive Processor, with OpenRouter added as a provider | 4-5 sessions |
| 3. Kinds of page | One list of kinds, detected on the first Vision pass, corrected by Finder tags, measured | 3-4 sessions |
| 4. The measured table and the router | The evidence in one file; the user's limits pick a route for each kind | 2-3 sessions |
| 5. Output | Searchable PDF and image-plus-text, chosen per format and kind; tags and document merging kept | 2-3 sessions |
| 6. Plan this batch | The screen that shows the recommendation and its cost, and what changes if the user adds a key or a model | 2-3 sessions |
| 7. Retire Vision OCR's app | Its last release points its users to Archive Processor | 1 session + owner |
| 8. Verify | Archive Processor's W40 items on the integrated app, then the phase's last three steps for all three apps | (W40) |

About 17-24 sessions before verification, by estimate. Stages 1 and 2 must come first, in that order. Stages 3 and 4
can run in parallel once 2 is done, and so can 5 and 6.

### Questions for later, decided when the work reaches them

- Whether local models should be offered on Intel Macs at all (they run on Apple's MLX, so in practice they need
  Apple Silicon).
- Which further local models to add, from the W41 panel's answers by memory size.
- How Live Capture should use local models while photos are arriving (memory and heat on a laptop).
- Signing and notarization, which affect both apps already and are not changed by this plan.

## Part 2 — the detail

### Facts this plan rests on (surveyed 14 October 2026, origin/main of both repositories)

- Vision OCR (`~/Claude/vision-ocr`, version 1.15.0, minimum macOS 13, universal build): 15 Swift source files, about
  26,000 lines (`Flattener` 6,546, `Recogniser` 5,460, `Model` 3,496, `SearchableWriter` 2,254, `JBIG2` 2,224); the
  helper `visionocr-recognise` runs Vision in parallel processes; `build.sh` compiles with `swiftc`; tests are
  `Tests/main.swift` (about 2,000 checks) and `Tools/ux-regression.sh`. Local models run as a subprocess of a
  downloaded Python 3.12 runtime with mlx-vlm (`Resources/read-model.py`); downloads are pinned by sha256
  (`ModelDownloads.swift`); one model reads at a time across processes. A reader is a route, an arrangement
  (`align`, `fill`, `replace`, `regions`) plus a model, chosen per page kind (`Prefs.AccurateReader.route`);
  page kinds are `newspaper` and `other`. Accuracy figures come from `OCR-COMPARE-2026-10-13.tsv` (67 pages);
  "Measure on this Mac" (`TimingRun.swift`) measures speed only.
- Archive Processor (`ArchiveProcessor/`, minimum macOS 14): about 53,700 lines; providers are concrete clients
  (`AnthropicClient`, `GeminiClient`, `MistralClient`, `OpenAICompatibleClient`, `VisionClient`,
  `LocalAgentClient`) chosen by `switch provider` in `OCRProcessor+OCR.swift`; `enum LLMProvider` raw values are
  stored, so cases may only be appended. One prompt for every model, `OCR/OCRPrompt.swift`, which also asks for the
  page's classification and rotation. Segmentation has a protocol (`WindowTransport`) and a chooser with measured
  figures (`SegmentationChooser.swift`, `segbench-results/options.json`). Output is a two-page PDF per image (image,
  then text) with Finder tags; continuation pages merge into one PDF per document.
- Shared code: `packages/ArchiveCore` (Swift package: Calendars, Corpus, Links, PDF, Tags, Thumbnails).

### Stage 0 — now

- Vision OCR finishes its queue (photo-pdf-size, settings-plain, page-kinds-three, model-throughput,
  layout-compare) and the owner cuts its release. No integration work touches `~/Claude/vision-ocr` while its
  daemon is working there.
- W41 finishes. Its report should give its figures by the kinds of page in Stage 3, so they drop into the table in
  Stage 4 without re-grouping. W41.ocr-prompt-app brings the app's instruction into line with the owner's
  transcription rulings; Stage 2 keeps that instruction for every paid and local model that takes one.
- The W40 order changed as decided (done 14 October): Archive Processor's W40 items (a5, b3, b4, d1-d5, e8, e12,
  g3, i1-i5) are `(blocked-on: W42.int-done)`, a HOLD QUEUE gate ticked when Stage 7 is done. Reader, Notes and the
  suite-wide checks continue. c1 is not held, because Notes needs it; b5, d11, e4 and h2 wait through their existing
  edges.

### Stage 1 — the engine as a package

Move Vision OCR's engine into `packages/VisionOCRKit` in this repository, keeping its history (a subtree merge from
`~/Claude/vision-ocr` after its release; the session states the method it used). The package holds recognition,
the page-kind detector, the flattener and its compression, JBIG2, the searchable-PDF writer, the model runtime, the
model downloads and the memory guard; Vision OCR's SwiftUI screens stay out. The helper becomes an executable
product of the package; `read-model.py` and the other resources become package resources. The minimum is macOS 14,
Archive Processor's.

Done when: the package builds with `swift build` for both architectures; its tests, converted from
`Tests/main.swift` to a test target, pass with the same count of checks; `ux-regression.sh`, run through a small
command-line product of the package, is no worse than Vision OCR's at its release; Vision OCR's own app, rebuilt
against the package, passes its suite (proof that nothing was lost in the move).

### Stage 2 — one way to read a page

A `PageReader` protocol in the package, and a provider adapter in Archive Processor. A reading takes the page image
and Vision's lines (Vision always runs first; it is free and gives the geometry) and returns the words in reading
order with positions where the reader has them, plus the seconds it took, the dollars it cost and the memory it
used. Implementations: Vision; each local model with its arrangement; each paid provider and the gateway; the
subscription command-line tools. Classification and rotation stay with the prompt for readers that take one, and
with Vision and Archive Processor's text rules for readers that do not, as Mistral already works.

**OpenRouter as a provider.** Today the app has no OpenRouter route; only the bake-off scripts use it
(`segbench/method_openrouter.py`, the W41 panels). The app's OpenAI-compatible gateway client may already reach it
with a custom base URL and hand-entered prices; that is checked first and stated. The first-class provider adds what
the gateway lacks: the model list and per-page prices read from OpenRouter's models endpoint, so the cost estimate
and the measured table need no hand-entered prices; the key in the Keychain account the owner already made
(`com.archiveprocessor.app` / `OpenRouter`); and the upstream provider pinned for each model, as the W41 panels do,
because OpenRouter serves an open model from several providers at different precisions and the measured figures hold
only for the one measured. A new `LLMProvider` case is appended, never inserted. The router treats each OpenRouter
model as its own route, so a model the W41 panel found good and cheap for a kind of page can be recommended for it.

Done when: Archive Processor's `switch provider` sites read through the protocol; every provider's existing journey
gives the same text as before on the smoke images; a check goes red if a provider skips the protocol; an OpenRouter
model reads the smoke images through the app with its cost taken from the models endpoint (a few cents, stated
before calling).

### Stage 3 — kinds of page

One list for the whole app, decided here and stated in the session's notes. It is likely to be: newspaper, printed
(book, journal, report), typewritten (typewriter and computer printer, as the owner ruled on 14 October),
handwritten, mixed, form or table, and photographed page as a second axis (it changes the image, not the writing).
Box and folder labels stay Archive Processor's classification, not a kind. The detector uses the first Vision pass
(line shapes and Vision's own confidence), the photo detection from Vision OCR's page-kinds-three, and the file's
Finder tags (Handwritten, Clippings, Statistics) when present. If those are not enough for handwriting, a small
on-device classifier is tried and measured before it is adopted.

Done when: the detector's accuracy is measured on the W41 truth set (99 pages, kinds confirmed by the owner) and on
Vision OCR's newspaper truth pages, reported per kind, with a check pinning it.

### Stage 4 — the measured table and the router

One bundled file, as `options.json` is for segmentation: for each kind of page and each route, the mistakes per
1,000 words, seconds a page on a reference Mac, dollars per 1,000 pages at list and batch prices, memory, and
whether it leaves the Mac. Sources: the W41 report and Vision OCR's comparisons, each row naming its evidence and
its sample size. "Measure on this Mac" rescales the speeds for the user's Mac.

The router takes the user's limits (a money cap for the batch, local only, a deadline or seconds-a-page ceiling, a
quality floor in mistakes per 1,000 words) and the routes the user has (keys, downloaded models, signed-in tools),
and for each kind picks the route with the fewest mistakes that fits. When nothing fits, it says which limit to
relax and by how much. It is a lookup in the table, not a model, so every choice can be explained in a sentence.

Done when: the router is tested on cases built from the table, including no key, local only, a cap that only
partly fits and a floor nothing meets; each recommendation's sentence names its evidence.

### Stage 5 — output

The searchable-PDF writer and its compression become Archive Processor's output path alongside the image-plus-text
PDF. The default is set per input format and per kind; for image-plus-text the image can also carry a text layer.
Finder tags and the merging of continuation pages into documents work for both forms. Where a reader's words cannot
be placed on Vision's lines (often handwriting), the page still gets a text layer, unplaced, and the run report says
which pages.

Done when: each combination is produced on the smoke set and read back through PDFKit (text selectable, tags
present, merged documents correct); the file sizes are reported against Vision OCR's at its release.

### Stage 6 — plan this batch

The screen, built from the two existing choosers. Out of the box only Vision is available, and the app reads with
it. After the first pass it shows the kinds it found and, for each, what the user would gain from a route they do
not have yet, in plain words: for example, 40 pages that look handwritten, about how many words Vision gets wrong
on such pages, and what Gemini would cost for them. The user sets their limits there. The wording follows Vision
OCR's settings-plain work (no term a non-technical user cannot explain from the screen).

Done when: a verifying reader of off-screen renders, told to read as a non-technical user, finds nothing it cannot
explain; the Processor's W40 visual review (e12) covers the screen.

### Stage 7 — retire Vision OCR's app

Vision OCR's last release (owner-only, as its releases are) shows its users a notice that the app continues as
Archive Processor, with a link; its updater then stops offering versions. Vision OCR's settings that have an
equivalent are read on first launch of Archive Processor (presets, the memory limit, downloaded models, which stay
where they are).

### Stage 8 — verify

Archive Processor's held W40 items run on the integrated app, rewritten where the integration changed what they
cover (the feature ledger b3 in particular). Then W40's h2, h3 and h4 for all three apps.

### Risks

- **The move breaks something subtle in the engine.** Vision OCR's suite and its UX regression set are the guard;
  Stage 1 is not done until both pass against the package.
- **The table's evidence is thin for some kinds.** W41 is about 100 pages and Vision OCR's comparison 67; some kinds
  will have a handful. Each row carries its sample size, and the screen says when a figure rests on few pages.
- **Two daemons on two repositories during the move.** Stage 1 starts only after Vision OCR's release, and Vision
  OCR's daemon is then pointed at Archive Suite's queue; the Agent Manager's project list changes with it.
- **Memory.** Local models plus Archive Processor's own work on an 18 GB Mac; the existing memory guard and the
  one-model-at-a-time lock carry over, and Live Capture's use of local models waits for its own decision.
