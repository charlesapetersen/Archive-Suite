# Automatic segmentation — find a method good enough to use, then build it

Written 2026-10-05 at the owner's request: "improving automatic segmentation in Archive Processor. This is the
original goal of the project ... Consider both using paid API calls for segmentation and using a small on device
model. We'll likely need to do a bakeoff ... The results will need to be extremely good to be usable. Getting
segmentation wrong ... can change how items are dated, tagged, and broken into individual files." It is queued
**before the W40 feature freeze**: `W40.a1` waits on this plan's decision item, and on its build items if the owner
approves a build.

Part 1 is for the owner. Part 2 is the daemon's detail.

---

## Part 1 — for the owner

### What segmentation is here, and why it failed in the spring

Segmentation decides where one document ends and the next begins in a box's stream of page photos, and which
photos are box or folder labels. Every later step depends on it: a page placed in the wrong document gets that
document's date, its tags and its file.

Today the app labels each page *as it reads it*, in the same call that does the OCR, and with the default settings
it looks at that page alone — not the page before, not the folder. In March the best version, which also saw the
previous page, labelled 90.5% of pages correctly. That number hides the harm. Counted the way a user feels it —
**the share of pages that end up in a document whose pages are exactly right** — an earlier run got about two pages
in three right: one page in three sat in a document that was wrongly split or merged. Nobody recorded why the work
stopped; the manual segmentation modes added in July took its place.

### What has changed since

1. **Methods that see many pages at once.** Current research frames this as "page stream segmentation" and judges
   each boundary with several pages in view, not one page alone. Published results on real collections are still
   short of perfect (about 0.83–0.95 on the usual measures), so no single method will be good enough on its own.
2. **Agreement between independent methods, plus review of the doubtful ones.** The realistic route to "extremely
   good" is to accept a boundary automatically only when independent methods agree, and to show you only the
   boundaries they dispute — side by side, page n beside page n+1. The question the bake-off answers is not "how
   accurate is the best model" but **"how few boundaries do you have to look at, for how few errors left over?"**
3. **Cheap enough not to matter.** Frontier models at batch prices come to roughly $1–3 per thousand pages for the
   fast ones and $8–15 for the strongest. A box is a few hundred pages.
4. **A Mac-sized option.** A small local model can learn from page features, or be prompted page by page. It runs
   free and private, but it is likely weaker and needs more labelled examples than five boxes provide.

Your point that photo timestamps are only a weak clue is built in: they are one input to the feature model and
never decide a boundary.

### The plan in five steps

1. **Your ground truth, checked.** The five labelled boxes (914 pages, 459 documents) are good, but the analysis
   found a few labels that look wrong and some questions only you can settle — is an enclosure its own document? a
   carbon? an envelope? You get a short list to check and a one-page set of rules to approve. Labelling one fresh
   box on the current phone would give the cleanest test, because the spring prompts were tuned on all five.
2. **A test bench** that scores any method on your boxes, offline, with every model answer saved so reruns cost
   nothing. It reports the harm-centred number above, false splits and false merges separately, and how many
   boundaries a method would send you for review. Two boxes (Stanton, RG 165) are locked away as the final exam;
   methods are tuned only on the other three.
3. **The bake-off.** Seven approaches, from the old one-page prompt (the baseline to beat) through frontier models
   that see a window of pages, a second frontier model as an independent voter, a local feature model, and a local
   vision model — then the combination with review.
4. **Your decision.** You see, for the best combination: errors left over per thousand pages, and how many
   boundaries you would have reviewed per box. You decide whether that is usable. If nothing is, the work stops
   there, and the manual modes stay the way to segment — that is a legitimate outcome.
5. **Only then, the build:** a segmentation pass that runs after OCR over the whole sequence, a review screen that
   shows only the flagged boundaries, the cost estimate updated, and the existing manual modes kept.

### What it costs

The bake-off's paid calls should come to tens of dollars in all; the daemon states the cost before each paid run.
About a dozen daemon sessions before your decision, and a similar number to build if you approve.

### Decisions that are yours

- Check the suspected label errors, and approve the rules for what counts as one document (step 1).
- Optionally, label one new box on the current phone as an unseen test.
- At step 4: is the result usable, and which combination of methods to build.
- Separately worth knowing: the phone app's existing "End segment" button already lets you mark boundaries while
  photographing. The bake-off measures how much that would add, but whether to use it is a question about your
  workflow, not about software.

---

## Part 2 — the daemon's detail

Tags are `W36.seg-*`. Each item is sized for one or two sessions (`resume-prompt.txt`). The bench and every
experiment are TOOLS: they do not change the app until `W36.seg-build*`. The W40 freeze does not cover this plan;
`W40.a1` waits on `W36.seg-decision` (and on the build items the decision files).

### What exists (survey, 2026-10-05)

- Classification is per page, inside the OCR call (`OCR/OCRPrompt.swift:6-64`, parsed `:69-114`, "when uncertain,
  prefer document_start" at `:30`). Optional context: the previous page's image (`sendPreviousImage`, default false)
  and previous text (removed in v3.6.0, `266bb7a`). Pre-OCRed PDFs use a text-only call
  (`OCRPrompt.buildClassificationOnly`, `:118-156`); Mistral uses a regex heuristic (`MistralClient.swift:60-126`).
  Live Capture's phone-side "End segment" groups override the labels (`applyPreGroupedClassifications`,
  `OCRProcessor+ReviewFlows.swift:23-38`).
- Grouping: `Tagging/DocumentSegmenter.swift:18-78`, no model call. Collections: `Tagging/CollectionSegmenter.swift`.
  Review: `showFullSegmentationReview` (`ReviewFlows.swift:404-460`; sheet `Views/OCRView+DocumentSegmentReviewSheet.swift`).
  Segments feed `TagGenerator.generateTags` (dates from up to 3 neighbouring segments), merging and the JSON sidecars.
- March 2026 measurements: `Test Files/Ground Truth Segmentation/segmentation_test.py` and `run_improved*.py`
  (they call Gemini directly with their own copy of the prompt, not the app's code), results in `test_results/`:
  baseline 86–91% per page, improved_v1 90.5% (shipped), improved_v2 86.0% (503 errors). Re-scored by document:
  about 73% of documents exact at baseline, about 89.5% with v1 counting the trivial box/folder segments;
  boundary precision 0.91–0.97, recall 0.82–1.00 — the model mostly MERGES.
- Constraints: `SPEC/tag-format.md` already carries the `Classification:` line (`Document Start`, `Continuation`,
  `Box`, `Folder`), so a new method can emit the same per-page `DocumentClassification` and leave the SPEC alone.
  Tagging/ is Tier-2. Text calls go through `LLMTextClient.complete`; the Vision hybrid sends text only. A
  sequence-level pass needs its own line in `CostEstimator`/`TimeEstimator`, and in batch mode it runs after the
  batch returns.

### The data (analysis, 2026-10-05)

- Five CSVs, schema `File Number,Status`, values `Box`/`Folder`/`New`/`Cont`; file N is `0000N — <Collection>.<ext>`.
  Pages are 914, not 948 (the folder CSVs were being counted). Documents 459; 59% are a single page; longest 19.
- Per collection: Dean 202 pages / 122 docs (iPad mini 2); Deaver 149 / 87 (iPad); Herrnstein 200 / 106 (iPhone 6);
  RG 165 113 / 32 (Pixel 9, 71% continuation pages, 16 box photos); Stanton 250 / 112 (iPad).
- Quality: trailing blank rows (Deaver about 102, Stanton 1); stray whitespace in labels; mixed `.jpg`/`.jpeg`;
  em-dash file names that break literal paths (list the directory, don't build names); suspected label errors at
  Dean 13 and 15 (`-2-` pages labelled New) and Dean 111–112 (two copies of a page 2); 38 New pages begin with a
  page number of 2 or more and need the owner's eye. "Collection Segmentation" reuses 29 of its 35 images from these
  folders and is not an independent test.
- Ground truth holds boundaries and label photos only — no dates or tags — so per-field accuracy can be scored only
  if the owner adds columns.
- `Test Files/` is gitignored: the bench reads it by a configurable path and never copies it into git.

### Metrics — the bench reports all of these, per collection and pooled

- **Headline: pages in an exact document** — the share of document pages whose document's page set is exactly the
  ground truth's. It counts the damage directly (every page in a wrongly split or merged document is mis-dated,
  mis-tagged, mis-filed). Measured by `W36.seg-bench` (2026-10-05), all five collections: no boundaries at all scores 3.7% (the
  "about 25%" first written here was wrong); every page a new document scores 58.6% of
  documents exact.
- False splits and false merges separately (they cost differently); boundary precision, recall, F1; Pk/WindowDiff;
  documents exact; folders perfectly segmented (STP); edits per 100 pages; box/folder photo accuracy apart.
- **For a method that flags uncertainty: the risk–coverage curve** — share of boundaries auto-accepted against the
  error rate among those accepted, and review load in boundaries per 100 pages.
- The owner's bar (2026-10-05): "close to maybe 98 percent". Two readings, both reported: fully automatic (no review),
  and after review of flagged boundaries with the review load stated. The published evidence makes the first
  unlikely today — the best results on real collections leave about 5% of boundaries wrong, and 98% of pages in an
  exact document needs nearer 1% — and the second plausible.
- Proposed usability bar, for the owner to confirm at the decision: after review of flagged boundaries, at least 98%
  of pages in an exact document in EVERY test collection, with no more than about 1 unflagged error per 500 pages.

### Splits

Development: Dean, Deaver, Herrnstein (551 pages, 315 documents), with leave-one-collection-out for any tuning
(prompts, thresholds, feature weights). Test: Stanton and RG 165 (363 pages, 144 documents), scored ONCE per finalist
at the end, never used to tune. The owner's fresh box, if labelled, is a second test. State in every result that the
spring prompts saw all five.

### Items

- **`W36.seg-truth` [S · owner]** — prepare the owner's check: the suspected errors with thumbnails, the 38
  page-number-first New pages, and a one-page draft of document rules (enclosure, carbon, envelope, clipping,
  photograph, attachment, duplicate page). The OWNER gate `W36.seg-truth-owner-ok` (HOLD) records the answers; the
  CSVs are corrected by the owner or with the owner's approval, never silently. The bench can start on the
  development set before the answers come back.
- **`W36.seg-bench` [M]** — the test bench, under `ArchiveProcessor/scripts/segbench/` (Python in the lab venv or
  Swift; follow the repo's tool conventions): load the five folders (strip whitespace, skip blank rows, list
  directories), OCR text per page cached once (Apple Vision, the app's own route), EXIF, image thumbnails; a method
  interface returning per-boundary `{new|continue, confidence, cue}`; every model response cached by content hash;
  all metrics above; per-run TSV and a short markdown summary committed under `ArchiveProcessor/segbench-results/`.
  Prove the scorer on hand-made toy streams with known answers.
- **`W36.seg-base` [S]** — baselines on the bench: all-New, no-boundaries, the shipped per-page prompt reproduced
  through the app's prompt text (with and without the previous image), and rule cues alone (page numbers, "Page n of
  N", salutations, closings, date lines, blank pages).
- **`W36.seg-window` [M · paid]** — approach A: a frontier model judging boundaries in overlapping windows of 6–8
  pages, images at medium resolution plus OCR text, structured JSON per boundary with the cue it saw and a confidence;
  every boundary judged in two windows. Variants: text only versus image plus text; window 4/6/8. Start with Gemini
  3.x Flash (batch). State the cost first. EARLY READ (owner, 2026-10-05: not worth building unless it gets "close to
  maybe 98 percent"): when this item ships, append a Daemon Report entry with its development-set numbers — pages in
  an exact document, and the review load needed to reach 98% — so the owner can stop the bake-off here. As a guide,
  if the best variant alone is under about 90% pages in an exact document, the combination is unlikely to reach 98%
  at a review load worth having; say so plainly.
- **`W36.seg-second` [S · paid]** — approach B: the same framing with an independent model (Claude Sonnet 5.5 or
  Gemini 3.1 Pro), as a second voter.
- **`W36.seg-whole` [S · paid]** — approach C: one long-context call per folder as a third voter; expect it to
  degrade past about 10 pages, and measure that.
- **`W36.seg-features` [M]** — approach D, on device: a gradient-boosted or logistic model on per-boundary features —
  rule cues, text-embedding similarity of pages n and n+1, image-embedding similarity (a small SigLIP/CLIP model
  through MLX), paper colour, page size and orientation change, blank-page flag, and the capture-time gap as ONE weak
  feature (owner, 2026-10-05: timestamps "will not be a very reliable clue"; report the model with and without it).
  Trained leave-one-collection-out; report calibration. 914 pages is little data: say so in the result.
- **`W36.seg-localvlm` [M]** — approach E, on device: a local vision model prompted per boundary or per small window
  (Qwen3-VL-8B 4-bit or Qwen3.5-4B, through the Vision OCR lab's guarded MLX setup; peak under 12 GB). Zero-shot only
  here; a LoRA fine-tune needs thousands of labelled boundaries and is noted as future work fed by corrections.
- **`W36.seg-corpus-survey` [S-M]** — training data from the owner's own tagged corpus (owner, 2026-10-06). Each
  corpus PDF is one photo in capture order; a change of Finder tags between neighbours implies a document start where a
  folder was tagged per document (HBS/Doriot), and nothing where it was tagged per collection (the corpus Deaver, Dean,
  Herrnstein). Read-only survey of all ~102,500 files' tags, per-folder classification, usable boundary count, and an
  owner-checked noise sample of 80 implied decisions. If enough usable, noisy-but-large data exists, approach E's
  LoRA fine-tune ("future work fed by corrections") gets costed at the decision instead of waiting for corrections.
  The corpus is never written. Zero-shot on-device results for comparison (Deaver, 2026-10-05): Qwen3.5-4B 57.4%,
  Qwen3-VL-8B 53.2%, Gemma 4 12B 46.8%, against 97.9% for the cloud models (`segbench-results/local-models-Deaver.md`).
- **`W36.seg-ensemble` [S-M]** — approach F: combine the voters (unanimous agreement = auto-accept; any disagreement
  or low confidence = flag), thresholds set leave-one-collection-out; risk–coverage curves; then score the finalists
  ONCE on the test collections. Also measure approach G on RG 165, the only Live Capture box: how many errors the
  phone's "End segment" marks would have removed, from its recorded groups if they survive, else stated as unknown.
- **`W36.seg-report` [S]** — `execution-plans/segmentation/01-results.md` for the owner: per approach and for the best
  combination, pages in an exact document, false splits and merges, review load per box, cost per 1,000 pages, and a
  recommendation. Then a Daemon Report entry for the decision.
- **`W36.seg-decision` — OWNER (HOLD)** — usable or not; which combination; the review design. If approved, the session
  that records the answer files `W36.seg-build1…N` (below), mirrors them into the plan, and adds their tags to
  `W40.a1`'s `(blocked-on:)`. If not, it records the outcome and `W40.a1` proceeds.
- **`W36.seg-build*` [filed at the decision; roughly L in all, Tier-2]** — a sequence-level segmentation pass after OCR
  that emits the same per-page `DocumentClassification` plus a per-boundary confidence (no SPEC change); a review
  screen showing only flagged boundaries, page n beside page n+1; `CostEstimator`/`TimeEstimator` lines; the batch
  path running the pass after the batch returns; the manual modes kept; the bench wired as a regression test on the
  development set; verified on the owner's fresh box if there is one.

### The owner's domain cues (2026-10-05) — every method must use them

From the owner's answers to the ground-truth check (`02-truth-check.md`, last section): ignore OCR text that shows
through from the sheet beneath (onion skin) — a page number read through the paper is not a continuation cue; a
small item (telegram, cover letter) photographed on top of a full sheet means the sheet underneath is the next
document; a byline, a wire credit ("(AP)", "(UPI)") or a section heading starts a newspaper clipping, and a newspaper
page number at the top is where it began; a full magazine is one document; photographs are never reordered, and
runs of empty folder or box photos are normal. Prompts (approaches A–C, E) state these; the feature model (D)
needs a show-through filter for its page-number cue and a byline/credit feature.

### Rules for every W36 item

- Never write into `Test Files/` (gitignored, and the owner's ground truth); results and caches go elsewhere.
- A number in a result says which collections it was measured on and whether they were tuned on.
- Paid runs: cheapest capable model first, batch where it exists, cost stated before the run, responses cached.
- A method's own confidence is evidence, not truth: thresholds come from held-out collections.
