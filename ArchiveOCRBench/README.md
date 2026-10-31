# ArchiveOCRBench

What the bench has measured, as one page you can read and share. It has seven parts:

1. **OCR.** The W41 OCR panel: twenty-five hosted routes read the same 96 adjudicated truth pages, and each is
   scored for accuracy (NES) against its price per 1,000 pages, overall and separately for typewritten, printed and
   handwritten pages. Four more routes ran the same pages on our own hardware: Qwen3-VL 8B at 4-bit, LightOnOCR-3-4B at 8-bit and
   Qwen3.5-9B at 4-bit on the owner's Mac, drawn in the free column, and Qwen3.6 27B at fp8 on one L40S on Stanford
   FarmShare, which is too large for the Mac and so is priced at OpenRouter's rate for the same model. Every other
   FarmShare run of the 96 pages in `farmshare/truth/` is on the same four charts (added 2026-10-21): □ when
   OpenRouter sells the model, priced at its rate for the run's tokens; ✶ when it does not (GLM-OCR, LightOnOCR-3,
   PaddleOCR-VL 1.5, PP-OCRv6, CHURRO-3B, Qwen3.5 4B), drawn in the free column as having no hosted price, free on
   a university cluster, with its GPU-hours in the tables. Part 1 opens with the ranking table (W46.ocr-rescore-
   offline, 2026-10-30): NES on the pages each route answered, the headline, with its failures beside it (provider
   or the model's own: caps, refusals, empty answers), strict NES, the paired difference from Qwen3.6 27B on pages
   both answered, p081 apart (the owner cannot correct its truth) and "96 only" for each route that has not read the
   895 itself. Part 5's difficulty fit, rankings and cascades keep the 29 routes they were built on (`build.py`
   passes them to `difficulty.analyse`), so Gemini 3.7 and the cluster runs other than FarmShare's Qwen3.6 27B are not in part 5.
2. **Segmentation.** How well each approach splits a box of photographs into documents, on the two locked test
   boxes (Stanton and RG 165, 363 pages): pages in the exact document with no checking, against price; and, in a
   table, the checks per 100 pages each needs, the pages right after checking, and the errors left unflagged.
3. **Handwriting on the Mac.** The on-device handwriting readers the Vision OCR lab measured on its own 19
   handwritten truth pages, as missed and added words. A different truth set and score from part 1; the pick and
   runner-up are also on part 1's charts as Mac routes, scored by NES (W41.mac-local-hw).
4. **FarmShare.** Open-weight models served on Stanford's FarmShare GPUs, one L40S each: the same 96 truth pages
   scored as part 1 scores them, with photos an hour and, for each model too large for the Mac, its price at OpenRouter's rate; NewsBench's
   newspaper pages read whole and through a layout detector, scored by NewsBench; and a 2,000-page run on the real
   corpus. Read from `ArchiveProcessor/segbench-results/farmshare/` (`build.py` → `farmshare()`).
5. **Difficulty and cascades.** Part 1's routes ranked on the pages they answered, apart from their failures, with a
   page-difficulty measure that never reuses the route being judged; where failures fall; cheap-first cascades
   simulated from the measured readings, with a split-half check on choosing them; and the signals that flag an
   answered page that is wrong (W41.bench-difficulty). With it, the Vision OCR lab's page sorter (newspaper,
   photograph, handwriting, other, from Apple Vision's reading; no model, no paid call) on the panel's pages and the
   bulk pilot's, as a label that does not depend on the route being judged and as a routing rule
   (W41.bench-vision-kind). The full report is `difficulty.md`. Beside it, a page-kind classifier for the Processor
   (hand, forms and tables, low resolution) measured on 184 labelled page images, with the reading accuracy a wrong
   kind costs under the model guide, read from `ArchiveProcessor/segbench-results/kind-classifier.json`
   (W41.bench-kind-classifier; the full report is `kind-classifier.md` there).
6. **Dating.** How well the tagging call dates a document: the app's `generateTags` prompt and default model on 300
   whole corpus documents, scored against the owner's own year, month and Date Uncertain tags. Read from
   `ArchiveProcessor/segbench-results/date-tagging.json` (W41.date-tag-measure; the full tables are
   `date-tagging.md` there). Beside it, the staged pipeline (rule candidates, a chooser, propagation, the residue
   to Qwen3.6 27B with a quote checked) against one shot, from `date-traceable.json` (W46.date-traceable;
   `date-traceable.md`).
7. **Public truth sets.** The reference routes (Gemini 3.8 Flash, Qwen3-VL 235B, and Apple Vision on the
   Latin-script pages) on 440 pages of published transcriptions in seven strata: Dutch and Romance archival hands,
   German Kurrent, charters before 1600, early print with Fraktur, Arabic manuscripts, Greek minuscule and Hebrew
   book hands. Scored by stratum with the 96's prompt, image size and scorer; scores only, no page images. Read
   from `ArchiveProcessor/segbench-results/bench-corpus/` (`routes.csv`, `routes-paired.json`, `manifest.jsonl`),
   written by `scripts/segbench/corpus/routes.py report` (W43.corpus-build). The frozen inventory now has
   **895 pages in fifteen strata**, adding English handwriting, typescripts, registers, newspapers, Cyrillic,
   Chinese and Devanagari (W43.corpus-build-more). The **455 added pages have no hosted reference scores**;
   those readings are deferred to W43.sweep, except Gemini 3.7 Flash through the gateway, which read all 895
   (W46.ocr-gemini37-895-paid; `gemini37-public.md`, and its rows in the scorer tables). Part 7 shows the inventory separately from the original results. Below it, the open-weight models read on FarmShare on all 895 pages, native-prompt and panel-prompt routes
   labelled apart, a review baseline (`open-sweep-20261019.csv`, written by `corpus/farmshare_expanded_report.py`;
   receipts in `data/open-sweep-20261019.json`), and the open models built for the hardest scripts (`specialists.csv`, written by
   `corpus/specialists.py report`, W43.script-specialists).

It is kept current: a change that commits a measured OCR or segmentation result updates the bench in the same
commit (owner, 2026-10-15; the rule is in the root [`CLAUDE.md`](../CLAUDE.md)). Presentation ideas not yet
built are in [`POTENTIAL_FEATURES.md`](POTENTIAL_FEATURES.md).

Part 2 also reports the public/easier CREST and Lincoln segmentation boxes separately, from their frozen
`public-segmentation/*-scores.json` files. Every supplied page was audited before collection; source gaps
and ambiguous wrappers are disclosed beside the figures. W46.seg-lincoln-cloud-paid adds the completed
Claude cue arm's gateway holes, Gemini windows and whole streams on both boxes, and GLM windows on CREST.
Lincoln GLM failed the unchanged gap validator twice at pages 163–169; its remaining windows stopped and
the table shows the failure and attempted-call cost without a numeric full-box score. Lincoln's whole reply
required a SHA-specific repair of two opening array brackets, with all decisions unchanged. Whole-stream
images use JPEG quality 45, so the window comparison also changes encoding and photo assumptions.
`seg-lincoln-gateway.json` joins each completed public route's field metrics, additional gateway calls,
mean response time and estimated token cost into that table. Gateway costs use checked list rates,
including reasoning, because the gateway supplies no bill; they are explicitly estimates. The Claude cue
row combines plan replies and 9 gateway windows on CREST (2 more on Deaver are in the full report).
The collection-facts panel (W46.seg-context) reads `seg-context.json`: the 27B teacher and trained 2B on
CREST, Lincoln and the two test boxes, each window with and without a COLLECTION FACTS block, beside the
gap votes a plain rerun flips (the noise floor).
The window panel (W46.seg-window-modality) reads `seg-window-modality.json`'s `pooled` rows: the trained 2B at
window sizes 3 to 10 and the whole folder, with images and text-only, on the development boxes, and the 2B, 4B
and teacher voting over six runs on the test boxes and Lincoln. A whole-folder cell the 2B never answered
parseably stays blank; any other incomplete cell stops the build.

## Completeness rule

Owner, 2026-10-21: when the bench page is updated, everything measured that a chart can take goes on it. A route
enters every chart whose metric it was measured on, on the same pages and settings that chart uses; page sets are
never mixed (96-page figures on the 96-page charts, the 895/440/455 public figures on the public tables, the locked
test boxes on the segmentation test chart). Hosted routes sit at their measured price and Mac routes are free. A
FarmShare or other cluster run of a model OpenRouter sells is priced at OpenRouter's rate for its own measured
tokens (`data/inputs.json` → `openrouter_open_weights`, or a route's own `price`, each with the date read); a run of
a model OpenRouter does not sell is drawn in the free column with its own marker, labelled as having no hosted
price (free on a university cluster), with its GPU-hours shown, never as a free equivalent of a hosted route. The
page says what each marker means. Where a chart cannot take a measured route (it lacks the per-kind scores or the
per-page answers the chart needs), the route stays off and the page or this README says which and why. New FarmShare
truth runs are added as `own_hardware.routes` entries in `data/inputs.json`; `ocr_pages_export.py` then adds their
pages to `ocr-pages.csv`, and a new route that has read the 895 gets a `PUBLIC_TWIN` entry in `build.py`. Known gaps
today: part 5 (rankings, difficulty curves, cascades) covers the 29 routes it was fitted on, not Gemini 3.7 Flash or the cluster runs
other than FarmShare's Qwen3.6 27B.

## What is here

| Path | What it is |
|---|---|
| `build.py` | Builds the two outputs below from the panel's committed results. `--check` fails if they are stale. |
| `data/inputs.json` | The figures the panel reports do not hold, each with its source: route display names, the estimated API price for Claude Sonnet 5.5, which routes have a batch price, and the names and machines of the routes on our own hardware (`own_hardware`). |
| `data/vision-ocr-handwriting.json` | The Vision OCR lab's handwriting figures, entered by hand from its repository with the file and commit they came from. |
| `difficulty.py` | Part 5's analysis, called by `build.py`: rankings, difficulty, cascades, flags. Standard library only; `test_difficulty.py` checks its statistics. |
| `difficulty.md` | Built. Part 5 as a readable report, every table included. |
| `data/panel-data.json` | Built. Every OCR route's score, answered pages and price for the four charts; every segmentation approach's test-box figures; the handwriting readers. |
| `site/template.html` | The chart page, with a `__DATA__` placeholder. |
| `site/index.html` | Built. The page itself: open it in a browser, or publish it. |

## Where the data comes from

The scores and measured costs are not copied here. `build.py` reads them where the panel's scripts write them,
in [`ArchiveProcessor/segbench-results/`](../ArchiveProcessor/segbench-results/), so those files stay the one
record:

- `ocr-panel-cloud.md` and `ocr-panel-local.md`: the reports, with the overall scores, answered pages, the
  measured cost per page, and the scoring method and its limits.
- `ocr-panel-cloud-groups.csv` and `ocr-panel-local-groups.csv`: scores per page attribute. The page kinds come
  from the `kind` rows.
- `ocr-mac-local.md` and `ocr-mac-local-groups.csv`: Qwen3-VL 8B at 4-bit through MLX on the 18 GB M3 Pro
  (W41.mac-local-measure). The CSV holds its scores overall and per kind; the report's speed table gives the
  seconds a page and peak memory shown in the tables.
- `ocr-mac-local-hw.md`: LightOnOCR-3-4B (8-bit, its card's settings) and Qwen3.5-9B (4-bit, the panel's prompt)
  on the same Mac (W41.mac-local-hw). Their scores are in the same groups CSV; each has its own speed table,
  named in `data/inputs.json` (`report`, `speed`).
- `farmshare/truth/<run>/summary.json` and `pages.csv`: Qwen3.6 27B on Stanford FarmShare. The charts use the
  fp8-KV run (`qwen3.6-27b-1849739`); the bf16-KV and fp8-at-load (`dyn`) runs are in the tables only. Scores
  per kind are averaged from `pages.csv` over the 96 accuracy pages (the agreement-only letters are read from
  `ocr_panel.py`), and `build.py` stops if that average stops matching `summary.json`. GPU-hours per 100,000
  photos come from its photos an hour. The newspaper results in `farmshare/news/` wait for a newspaper chart
  (`POTENTIAL_FEATURES.md`).
- `ocr-pages.csv` and `ocr-pages-agree.csv`: every whole-page route's score on every one of the 96 pages (kind, the
  kind the route said, Vision OCR's page kind, answered, why a failed page failed, NES, measured cost, word counts;
  the panels, the Mac, Gemini 3.7 through the gateway and every FarmShare and Sherlock run), and the NES between two cheap
  readers' texts on the same page. `scripts/segbench/ocr_pages_export.py` writes them from the panels' private
  caches; rerun it when a route is added or rerun, then `build.py`. Part 5 reads only these, and FarmShare's
  `bulk/summary.json`, `bulk/pages.csv` and `bulk/vision-kind.csv` for the bulk pages' failures and kinds.
- The Vision kind comes from `scripts/segbench/vision_kind/run.sh`, which builds a small tool against a vision-ocr
  checkout's `Sources/` (read only; the commit is printed) and writes into the private cache's `vision-kind/`;
  then rerun `ocr_pages_export.py`. The bulk pages' images are the bulk pilot's 2,400 px renders, kept on the Mac.
- `ocr-scorers.json` (`scripts/segbench/ocr_rescore.py`, W46.fix-ocr-scorers): every saved reading of the 96 and
  the 895 re-scored with the processing review's scorer additions (added and rewritten words, cMER, NewsBench's
  bag-of-words F1 and gap, the two-reader suspect check, OmniDocBench's reading-order edit). The page shows the
  whole-set rows of every route that answered; the strata, preservation, markup and restoration-only tables are in
  `ocr-scorers.md` only. `chaos-probe.json` (`chaos_probe.py`) is the altered-word probe on 20 typed owner pages.
- `gemini37-vs-38.md` and `-groups.csv` (`scripts/segbench/gateway_gemini.py report`, W46.fix-ocr-scorers-paid):
  Gemini 3.7 Flash through the Stanford gateway on the 96, in the cloud panel's two formats, so `build.py` draws it
  on the 96's charts. Its price is an estimate (the gateway returns no cost), and the route's name says so. Its
  pages are in `ocr-pages.csv` for the ranking table; the difficulty and cascade analysis leaves it out.
  `gemini37-public.md` (`scripts/segbench/ocr_gemini37_public.py report`, W46.ocr-gemini37-895-paid) is the same
  route on the 895, with the same settings and the reference routes' images; `ocr_rescore.py` scores it on both
  sets (family `gateway`), and its `PUBLIC_TWIN` entry gives the ranking table its 895 count.
  `ocr-truth-bias.json` (`ocr_truth_bias.py`, W46.fix-ocr-truth-bias) splits each route's word accuracy on the 96
  into the words both drafters agreed on and the words the owner adjudicated, strict and with line-end hyphen joins
  forgiven; the page shows it under the same section, with the blind owner check it feeds. That check's score is
  `ocr-truth-bias-score.json` (`ocr_truth_bias_score.py`, W46.fix-ocr-truth-bias-score), read into the same note.
- `ocr-panel-cloud-pilot.md`: the three-page pilot that came before the full cloud run.
- `enh-dewarp.json` (`scripts/segbench/enh_dewarp.py report`, W46.enh-dewarp): crop, dewarp or nothing before
  reading, and the app's own encoder, each image against the plain photograph on the 96, per reader (Apple
  Vision now; the three FarmShare readers when their run is fetched). The page shows its rows as a table; the
  round trip, curvature and hand-crop tables are in `enh-dewarp.md`, the UVDoc benchmark check in
  `enh-dewarp-uvdoc-bench.md`.
- `enh-ocr-input.json` (`scripts/segbench/enh_ocr_input.py report`, W46.enh-ocr-input): content-removing
  enhancement (shading division, GCDRNet, SBB, DocRes appearance and deshadow) before Apple Vision, PP-OCRv6,
  Qwen3-VL 8B, GLM-OCR on PP-DocLayoutV3 regions and Gemini 3.7 Flash through the Stanford gateway
  (W46.enh-ocr-input-paid, priced from its estimated tokens), on the 96, and the two-seed ResShift/NAF-DPM probe on the 30
  hardest pages. The page shows its summary rows as a table with a page-group picker; every arm read on all 96
  enters the four OCR charts (`enh-` ids, kept out of the difficulty analysis). Tag, repair-by-tag and gate tables
  are in `enh-ocr-input.md`.
- `ocr-logprob.json` (`scripts/segbench/ocr_logprob.py report`, W46.ocr-logprob): LightOnOCR-3 4B and Qwen3.5-9B
  read again with token log-probabilities (mlx-vlm on the Mac for the 96, vLLM on Sherlock for the 96 and the 895).
  Part 5 shows each signal's AUC against an answered page under 90 NES and the 455's 20%-budget cascade into
  Qwen3.6-27B. Three of its four readings rerun routes already on the charts (same settings, NES within about a
  point) and add no chart route. The fourth, Qwen3.5-9B through vLLM on Sherlock with the panel prompt, is new: its
  96 are `farmshare/truth/qwen3.5-9b-49202328` (scored by `corpus/farmshare_truth96.py`), on the four OCR charts as
  `qwen3.5-9b-sherlock` at OpenRouter's DeepInfra bf16 rate. Its 895 (NES 48.3; 31.2 on the 440, 64.9 on the 455;
  237 caps) stay off the public tables, which are the open sweep's report (`open-sweep-20261019.*`), not a list
  routes can join; the figures are in `ocr-logprob.md`. Calibration, threshold and invariance tables are there too.
- `ocr-postcorrect.json` (`scripts/segbench/postcorrect.py score --results`, W46.ocr-postcorrect): Qwen3.6-27B on
  Sherlock correcting cheap readings in the NES 70-90 band of the 96 and of L1, L2, L4 and L6, with the image and as
  text only, trimmed and cap-guarded, beside the same model's direct reading from `ocr-scorers-pages.csv`; part 5's
  post-correction panel. A table panel, not chart routes: a corrector is a stage on another reader's text, not a
  reader. The figures are in `ocr-postcorrect.md`.
- `bench-corpus/regions-20261021.json` (`corpus/regions.py report`, W46.ocr-regions): whole page against
  DocLayout-YOLO regions, PP-DocLayoutV3 regions and overlapping tiles, four readers on L9/L4/L3/L1 (255
  public pages) and the 96. Its experiment section selects public strata and overlapping annotation groups;
  all twelve crop routes also enter the four eligible OCR charts using the exact panel-kind groups, including
  capped crop costs in Qwen's own-token OpenRouter-rate prices. Other readers have no hosted price and use
  the free-cluster marker. These crops ran on Sherlock, with 38 reused GLM pilot crops from FarmShare.
  Per-arm speed is unknown: concurrent job summaries combine all arms and both sets. Part 5 excludes them
  because they are absent from `ocr-pages.csv`. The JSON also holds a separate table-markup diagnostic;
  strict NES stays unchanged. `regions-20261021.md` gives provenance, limits and the unmeasured L4 cell arm.
- `bench-corpus/regions-orderfree-20261030.json` (`corpus/regions_orderfree.py`, W46.ocr-rescore-offline): the same
  stitched readings of the open readers and of Gemini 3.7 (`regions-gateway-20261028`) rescored with NewsBench's
  order-free bag-of-words F1, its order gap and the missed and added word rates, each arm paired with its own
  whole page; the regions table's order-free column. The 96's truth has no reading order, so the order-free loss is
  the one to quote there.
- `options.md`: the segmentation approaches on the test boxes (manual, Claude, Gemini, ChatGPT, Claude and
  ChatGPT together), each at the flag level frozen on the development boxes, with their API cost.
- `cheap-models.md`: the three cheap segmentation finalists (GLM-5.3 Flash, GPT-5.6 Luna, Qwen3.5 Flash) at the
  98% bar's frozen level, and their cost over five boxes. `build.py` stops if its Gemini row stops matching
  `options.md`, which the report says it reproduces.

The handwriting part comes from another repository, so it cannot be read in place. Its figures are copied into
`data/vision-ocr-handwriting.json` from `HW-PANEL-2026-10-15.tsv` in
[vision-ocr](https://github.com/charlesapetersen/vision-ocr) at commit `bbf4370`; re-enter them if that file is
rerun.

The scripts that produced them are in `ArchiveProcessor/scripts/segbench/` (`ocr_panel.py`,
`ocr_panel_score.py`, `ocr_cloud_full.py` and their neighbours); each report ends with its reproduction steps.

## Rebuilding

```bash
python3 ArchiveOCRBench/build.py
```

Run it after any result it reads changes, and commit the two built files with the change. `--check` fails when
they are stale. It needs only the
Python standard library.

## How to read the page

- **NES** is normalized edit similarity: one minus the character edit distance divided by the longer text's
  length, averaged over pages. A failed page scores 0, which is why routes with failures fall further than
  their good readings suggest.
- **Prices** are the measured charge per page, times 1,000: OpenRouter's on the panel's pinned endpoint, and
  Mistral's published rate for Mistral OCR. The local panel's costs include its reports' conservative ceilings
  for calls with no billing record. Apple
  Vision runs on the device and is drawn in a "free" column, as are the three routes on our Mac (◇). Models too
  large for the 18 GB Mac are not free even when they ran on FarmShare, which bills nothing: each is priced at
  OpenRouter's catalogue list rate for the same open-weight model applied to the run's own measured tokens
  (`data/inputs.json` → `openrouter_open_weights`, read 2026-10-20). That covers the FarmShare route (□) on the
  charts, part 4's Qwen tables and the 2,000-page pilot, the segmentation teacher and the dating runs. Models that
  fit on the Mac (CHURRO-3B, GLM-OCR, the 2B and 4B fine-tunes) stay free, except a FarmShare run of one OpenRouter
  sells (Qwen3-VL 8B, at $0.25/$0.75 read 2026-10-21), which the completeness rule below prices at that rate. Claude Sonnet 5.5 ran on the subscription, so its
  price is an estimate (`data/inputs.json` → `sonnet_api_estimate`).
- **Batch points** sit at half the measured cost, for routes whose batch price is half their standard price.
  A dotted line joins the two points.
- **The best-value line** links the points that no other point beats on both price and score. It is worked out
  across standard and batch prices together.
- **The kind charts** reuse each route's average price over all 96 pages, so they compare accuracy at a route's
  usual price, not the price of that kind of page.
- **Segmentation's "no checking"** is the share of document pages that land in exactly the right document if
  nobody checks anything. Its "checks per 100 pages" counts every page photographed, box and folder photos
  included. Each approach is at the flag level frozen on the development boxes for the 98% bar (`options-frozen.json`,
  `options-frozen-openai.json`, `cheap-finalists.json` and `cheap-models.md`), so the table
  shows what checking costs and buys at that level. Prices come from tokens measured over all five boxes, not
  only the test boxes. Claude's and ChatGPT's are what the same requests would cost on the API; both ran on
  subscriptions. Gemini 3.8 Flash is at an introductory price until 31 Dec 2026, after which its list price doubles.
- **Handwriting's missed words** are truth words a reader did not produce, per 1,000; added words are words it
  produced that match no truth word. These do not compare with NES.

## Limits

For the OCR panel, from its reports. One corpus of about 100 pages. Claude Opus 5.5 and Gemini 3.8
Flash drafted the truth before it was adjudicated, so it may lean toward those families. The "local panel"
chose models small enough to run on a Mac, and ran hosted on OpenRouter; of those, Qwen3-VL 8B and Qwen3.5-9B have
been measured on the Mac itself (Qwen3-VL 8B −2.15 NES strict, −0.17 on the pages both finished; Qwen3.5-9B +2.48,
because the hosted route failed four pages, and −3.00 on handwritten pages). A difference of a point or two is not a ranking, and the handwritten chart rests on about 2,200 words.
Segmentation's error counts are small (zero to three on the test boxes for most approaches), so one or two either
way is noise, and the boxes are from one archive. The handwriting part rests on 19 pages and one archive's hands.

The published copy of the page is the private artifact
<https://claude.ai/artifact/LGb43P7kewBvqXJ6Kiwd41>, built from the same data.
