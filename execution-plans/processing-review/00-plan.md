# Processing review: segmentation, dating, OCR and what surrounds them

Owner, 2026-10-20. A systematic review of how Archive Processor turns photographs of archival material into
segmented, dated, readable documents, measured against the current literature and the current model releases,
before more processing work is built. Every processing item in the queue waits on the gate `W46.review-done`
until this review has filed its work queue. The Agent Manager meanwhile works on UI and bugs.

Progress and the resume point live in `STATE.md` beside this file. A session that picks this up reads that first.

## What already exists

The project has measured a lot and read little. The record, in brief, with the files that hold it:

- Segmentation. Five owner boxes (914 pages, three development and two locked test boxes) and two public boxes.
  Rules, a feature model, local zero-shot models, cloud models over page windows, cheap OpenRouter models,
  ensembles, and Qwen3.5 2B and 4B students trained on FarmShare. On the test boxes Gemini 3.8 Flash puts 88.8% of
  pages in an exactly right document, the trained 2B on the Mac 78.8%. Results fall sharply on new collections
  (Lincoln Papers 35-47%). `ArchiveProcessor/segbench-results/SUMMARY.md`, `options.md`, `public-segmentation.md`,
  `execution-plans/segmentation/`.
- Dating. Gemini 3.8 Flash gets the exact year on 79.6% of 300 documents: 97.5% when the year is printed, 63.4%
  when it is not. The trained 2B and 4B reach 41% on unprinted years and never mark a date uncertain.
  `segbench-results/date-tagging.md`, `date-model.md`.
- OCR. A 99-page owner truth set (drafted by Claude and Gemini, adjudicated by the owner, so biased toward those
  families), a cloud panel, a hosted open-weight panel, Mac MLX runs, FarmShare throughput, an 895-page public set
  in 15 strata (440 scored), script specialists, a failure cascade and a page-kind router.
  `segbench-results/ocr-*.md`, `bench-corpus/`, `ArchiveOCRBench/`.
- Layout. Newspapers only, in the Vision OCR lab: DocLayout-YOLO regions first is best. Nothing for archive photos.
- Enhancement and dewarping. Nothing beyond upright rotation and downscaling.
- Text placement. The Processor writes an image page and a separate text page. The Vision OCR lab has the
  searchable-PDF writer and the line alignment; the integration plan (`execution-plans/integration/00-plan.md`)
  would bring them in, and it now waits on this review.
- Entities. Nothing.
- Literature. Four prior-art notes in the Vision OCR lab (`vision-ocr/PRIOR-ART-*.md`, OCR and handwriting and text
  layers). Nothing on page-stream segmentation, dating, enhancement, layout for photos, entities or whole-corpus
  methods.

## Owner decisions that shape the review (2026-10-20)

- The reading copy may be dewarped, deskewed or otherwise enhanced only by methods that remove no content, because
  that makes the text easier to select. It is a user option, on or off. Methods that remove marks, scribbles,
  stamps or bleed-through may produce an OCR input only, never the image a reader sees. Seemingly incidental marks
  are evidence and are preserved.
- Text placed on the page image is preferred to a separate text page, unless a text page is necessary.
- Sherlock is the cluster the review plans for from the start (owner: assume access will come). Experiments are
  designed for its GPUs (its public gpu partition lists 16 H100 and 32 L40S among about 200 GPUs, no A100; 16 GPUs
  per user, 2-day jobs; `J-compute.md`), so models too large for FarmShare's L40S cards are
  in scope. FarmShare stays a second cluster profile, a fallback while the Sherlock account is pending, and the
  home of the outputs already collected. The cluster kit (`scripts/segbench/institutional-compute/`) gets a
  Sherlock profile beside `profiles/farmshare.json`.
- The Vision OCR integration waits on this review. The Processor UI and bug items no longer wait on it.
- Phases 0-2 and 4 run interactively. Phase 3, the experiments, is queued for the engine.
- Experiments use free cluster compute (Sherlock first) where they can. Paid APIs are used when a question needs them, under the
  $3 rule in `~/Claude/CLAUDE.md`.
- Every model tested on the 895-page public set is also run on the owner's 96 truth pages (root CLAUDE.md, "Both
  OCR sets, every time").
- Dating is explicit only. A date written or printed on the document is wanted; so is a date inherited from an
  explicitly dated covering document when the enclosure relation can be established (in the owner's tags, a dated
  document with no date of its own is almost always an enclosure). Estimating a year from style, hand, typeface or
  neighbours is out of scope. Strand B covers explicit extraction and enclosure detection; the app's speculative
  year and `Date Uncertain` behaviour is reviewed against this in Phase 4.
- Entities (authors, senders and recipients, places) are a long-term option, and are reviewed mainly as an input to
  dating and segmentation. More languages, scripts and eras are a long-term goal; the existing corpus and the
  public set are broad enough for now.

## The user profiles every recommendation is given for

1. A laptop only, open weights: Macs with 16, 32 and 64 GB or more.
2. Cheap API access: OpenRouter and similar.
3. Premium APIs or subscriptions: Gemini, Claude, OpenAI, and the Claude and ChatGPT plans.
4. A cluster: Sherlock, FarmShare, or any Slurm cluster with GPUs.
5. Any of the above plus a coding agent, which can train a model on the user's own photographs with a kit we
   provide (see strand H).

Each recommendation is given per profile and per document kind (typed, printed, handwritten, forms, clippings,
newspapers, non-Latin scripts, early modern hands).

## Phase 0 — housekeeping (interactive)

- Done 2026-10-20: one gate, `W46.review-done`, on every processing item; the Processor UI items freed from the
  never-filed integration marker.
- Score the open-model outputs already collected on FarmShare (GLM-OCR, LightOnOCR-3, PaddleOCR-VL, PP-OCRv6,
  Qwen3-VL-8B, Qwen3.5-4B and the rest, in `Long term storage/FarmShare-open-sweep-20261019/`). They cost nothing more
  and become the baseline. Check whether the Nemotron rerun (job 1860275) is still on the cluster.
- Create `STATE.md` with the strand table and the resume procedure.

## Phase 1 — literature and model survey (interactive, subagents)

Strands:

- A. Page-stream segmentation and document splitting: page-pair classifiers (LayoutLMv3 and successors), DocLLM,
  OmniParser, doc-split-v1, DocSplit (arXiv 2602.15958) and the papers that cite it, HR-DocStream, TABME and others;
  adapting to a new collection; learning from a user's corrections.
- B. Dating, explicit only: extracting and normalising dates written or printed on a document (letterheads,
  postmarks, stamps, annotations, partial dates), and detecting enclosure relations so an undated enclosure takes its
  covering document's date (SPEC/tag-format.md, W37.dual-date). Stylistic or visual date estimation is out of scope.
- C. OCR and HTR: current vision-language OCR models, historical-script specialists, post-OCR correction,
  historical language models (HMBERT and the Saskatchewan thesis the owner cited), whole-page against region-first.
- D. Image enhancement, dewarping, deskewing and binarisation, with the Rényi DIE model as a starting point; which
  methods remove content and which do not; invented-text risk; detecting and transcribing marks and annotations
  separately.
- E. Layout analysis and reading order for archive photographs, not just newspapers.
- F. Text placement: models that report word or line positions, alignment of position-free output onto detected
  lines, hOCR and ALTO, handwriting placement.
- G. Entity extraction from letters and papers (sender, recipient, places), as an input to dating and segmentation
  and as a later option.
- H. Whole-corpus methods: collection-level context, active learning, few-shot adaptation, and training on a user's
  own photographs, including what a coding-agent kit would need and how a trained model plugs into the Processor.
- I. Model inventory: Hugging Face and GitHub, with licence, size, positions or not, languages, and whether it runs
  on a Mac (MLX or llama.cpp) at each memory size.
- J. Compute and prices: Sherlock's partitions, GPU types, job limits, storage and model-download rules (the
  design target), FarmShare limits as the fallback, OpenRouter and direct API prices, batch
  discounts.

How the reading is done, so the expensive model reads only what matters:

1. Screen wide. A cheaper model (Sonnet) runs the searches (arXiv, Semantic Scholar, ACL Anthology, ICDAR and
   HIP proceedings, Hugging Face, GitHub, Papers with Code), follows citations forward from the key papers, and
   triages by abstract into read, skim or drop. It records every candidate with its reason, so the shortlist can be
   audited.
2. Read deep, selectively. Fable reads in full only the shortlisted papers, about five to eight per strand: the
   ones whose claims we would build on or test. It writes the strand note and its synthesis. The inventories
   (strands I and J) stay with the cheaper model.
3. Check. Every figure and claim a strand note relies on is checked against the source before it reaches the gap
   audit. A claim is tagged measured, inferred or unknown.

Each strand note (`A-segmentation.md` and so on) uses one template: the question, what the field does, the claims
with their figures and conditions, whether code and weights exist and under what licence, how it compares with what
we measured, and the test on our material that would settle it. Strands run a few at a time. The first strand
measures its share of the weekly window, and the rest are paced from that figure.

## Phase 2 — gap audit (interactive)

- Match each candidate method to the test that would settle it, and to the profile it serves.
- Find where an existing public benchmark already answers a question well enough that we need not build our own
  (for example DocSplit for splitting, published HTR benchmarks for specialist scripts), and where our material
  differs enough that we must. Record the reason either way.
- Where a public benchmark is close but not exact, borrow its data, metrics or scripts and run them ourselves:
  when our setup differs (photographs rather than scans, our resolution and JPEG settings, our prompts and routes),
  when the published scores predate the current models, or when we want its pages inside our own scorer. Check the
  licence and the test-contamination risk for each, as the public OCR set already does.
- Fix the weak test sets the review needs: the OCR truth that favours Claude and Gemini (a third family adjudicates
  or a fresh set is drafted differently), more locked segmentation boxes, a larger dating test set with unprinted
  years, and a new small set of pages with marks (marginalia, stamps, annotations, scribbles) that measures whether
  marks survive and are transcribed.
- Add scoring the review needs: an added-words rate to catch invented text from enhancement, and a position
  accuracy score for text placement.
- Write the experiment list in priority order, each with its free route and, only where needed, its paid route and
  cost estimate.

The owner sees the gap audit before Phase 3 is filed.

## Phase 3 — experiments (engine)

Filed as queue items of medium size, each behind the owner's approval of the gap audit. They compare the one-shot
routes with staged pipelines on the same frozen sets, and switch each stage off in turn to measure its contribution:
enhancement as OCR input on and off, dewarping, layout first, page-pair classifiers against windows, collection
context for dating, entity cues for dating and segmentation, and user-trained models against general ones.
Sherlock first, FarmShare as fallback, the Mac for profile 1, paid APIs where a question needs them.

## Phase 4 — decisions and the work queue (interactive)

- One decision note per stage, with the recommendation per profile and document kind, and what would change it as
  models move.
- The owner's calls, walked one at a time.
- The implementation queue filed with `ops/autonomous/plan-edit.sh`: the integration stages (W42.int-s1 to s7),
  changes to app defaults and routes, the training kit and its plug-in point, the marks layer, and the long-term
  entity and language items recorded with their test needs. Then `W46.review-done` is approved and the held items
  are kept, rewritten or retired.
