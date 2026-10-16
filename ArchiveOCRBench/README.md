# ArchiveOCRBench

What the bench has measured, as one page you can read and share. It has three parts:

1. **OCR.** The W41 OCR panel: twenty-four hosted routes read the same 96 adjudicated truth pages, and each is
   scored for accuracy (NES) against its price per 1,000 pages, overall and separately for typewritten, printed and
   handwritten pages. Two more routes ran the same pages on our own hardware and are drawn in the free column:
   Qwen3-VL 8B at 4-bit on the owner's Mac, and Qwen3.6 27B at fp8 on one L40S on Stanford FarmShare.
2. **Segmentation.** How well each approach splits a box of photographs into documents, on the two locked test
   boxes (Stanton and RG 165, 363 pages): pages in the exact document with no checking, against price; and, in a
   table, the checks per 100 pages each needs, the pages right after checking, and the errors left unflagged.
3. **Handwriting on the Mac.** The on-device handwriting readers the Vision OCR lab measured on its own 19
   handwritten truth pages, as missed and added words. A different truth set and score from part 1.

It is kept current: a change that commits a measured OCR or segmentation result updates the bench in the same
commit (owner, 2026-10-15; the rule is in the root [`CLAUDE.md`](../CLAUDE.md)). Presentation ideas not yet
built are in [`POTENTIAL_FEATURES.md`](POTENTIAL_FEATURES.md).

## What is here

| Path | What it is |
|---|---|
| `build.py` | Builds the two outputs below from the panel's committed results. `--check` fails if they are stale. |
| `data/inputs.json` | The figures the panel reports do not hold, each with its source: route display names, the estimated API price for Claude Sonnet 5.5, which routes have a batch price, and the names and machines of the routes on our own hardware (`own_hardware`). |
| `data/vision-ocr-handwriting.json` | The Vision OCR lab's handwriting figures, entered by hand from its repository with the file and commit they came from. |
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
- `farmshare/truth/<run>/summary.json` and `pages.csv`: Qwen3.6 27B on Stanford FarmShare. The charts use the
  fp8-KV run (`qwen3.6-27b-1849739`); the bf16-KV and fp8-at-load (`dyn`) runs are in the tables only. Scores
  per kind are averaged from `pages.csv` over the 96 accuracy pages (the agreement-only letters are read from
  `ocr_panel.py`), and `build.py` stops if that average stops matching `summary.json`. GPU-hours per 100,000
  photos come from its photos an hour. The newspaper results in `farmshare/news/` wait for a newspaper chart
  (`POTENTIAL_FEATURES.md`).
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
  Vision runs on the device and is drawn in a "free" column, as is Qwen3-VL 8B on our Mac (◇). The FarmShare route
  (□) is priced at $0, since the cluster bills nothing, with its GPU-hours per 100,000 photos beside it. Claude Sonnet 5.5 ran on the subscription, so its
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
chose models small enough to run on a Mac, and ran hosted on OpenRouter; of those, only Qwen3-VL 8B has been
measured on the Mac itself (−2.15 NES strict, −0.17 on the pages both finished). A difference of a point or two is not a ranking, and the handwritten chart rests on about 2,200 words.
Segmentation's error counts are small (zero to three on the test boxes for most approaches), so one or two either
way is noise, and the boxes are from one archive. The handwriting part rests on 19 pages and one archive's hands.

The published copy of the page is the private artifact
<https://claude.ai/artifact/LGb43P7kewBvqXJ6Kiwd41>, built from the same data.
