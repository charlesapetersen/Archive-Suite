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
   a university cluster, with its GPU-hours in the tables. Part 5's difficulty fit, rankings and cascades still use
   only the routes in `ocr-pages.csv`, so these runs are not in part 5.
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
   `date-tagging.md` there).
7. **Public truth sets.** The reference routes (Gemini 3.8 Flash, Qwen3-VL 235B, and Apple Vision on the
   Latin-script pages) on 440 pages of published transcriptions in seven strata: Dutch and Romance archival hands,
   German Kurrent, charters before 1600, early print with Fraktur, Arabic manuscripts, Greek minuscule and Hebrew
   book hands. Scored by stratum with the 96's prompt, image size and scorer; scores only, no page images. Read
   from `ArchiveProcessor/segbench-results/bench-corpus/` (`routes.csv`, `routes-paired.json`, `manifest.jsonl`),
   written by `scripts/segbench/corpus/routes.py report` (W43.corpus-build). The frozen inventory now has
   **895 pages in fifteen strata**, adding English handwriting, typescripts, registers, newspapers, Cyrillic,
   Chinese and Devanagari (W43.corpus-build-more). The **455 added pages have no hosted reference scores**;
   those readings are deferred to W43.sweep. Part 7 shows the inventory separately from the original results. Below it, the open-weight models read on FarmShare on all 895 pages, native-prompt and panel-prompt routes
   labelled apart, a review baseline (`open-sweep-20261019.csv`, written by `corpus/farmshare_expanded_report.py`;
   receipts in `data/open-sweep-20261019.json`), and the open models built for the hardest scripts (`specialists.csv`, written by
   `corpus/specialists.py report`, W43.script-specialists).

It is kept current: a change that commits a measured OCR or segmentation result updates the bench in the same
commit (owner, 2026-10-15; the rule is in the root [`CLAUDE.md`](../CLAUDE.md)). Presentation ideas not yet
built are in [`POTENTIAL_FEATURES.md`](POTENTIAL_FEATURES.md).

Part 2 also reports the public/easier CREST and Lincoln segmentation boxes separately, from their frozen
`public-segmentation/*-scores.json` files. Every supplied page was audited before collection; source gaps
and ambiguous wrappers are disclosed beside the figures. Paid reference calls remain deferred.

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
truth runs are added as `own_hardware.routes` entries in `data/inputs.json`. Known gaps today: part 5 (rankings,
difficulty curves, cascades) covers only the routes in `ocr-pages.csv`, not the 13 FarmShare runs added to part 1.

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
- `ocr-pages.csv` and `ocr-pages-agree.csv`: every route's score on every one of the 96 pages (kind, the kind the
  route said, Vision OCR's page kind, answered, NES, measured cost, word counts), and the NES between two cheap
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
  `ocr-truth-bias.json` (`ocr_truth_bias.py`, W46.fix-ocr-truth-bias) splits each route's word accuracy on the 96
  into the words both drafters agreed on and the words the owner adjudicated, strict and with line-end hyphen joins
  forgiven; the page shows it under the same section, with the blind owner check it feeds.
- `ocr-panel-cloud-pilot.md`: the three-page pilot that came before the full cloud run.
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
