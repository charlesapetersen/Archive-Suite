# ArchiveOCRBench

The W41 OCR panel's results as a benchmark you can read and share. Twenty-four OCR routes read the same 96
adjudicated truth pages, and each is scored for accuracy (NES) against its price per 1,000 pages: overall,
and separately for typewritten, printed and handwritten pages. Parked on 2026-10-15; the owner means to come
back to it (ideas in [`POTENTIAL_FEATURES.md`](POTENTIAL_FEATURES.md)).

## What is here

| Path | What it is |
|---|---|
| `build.py` | Builds the two outputs below from the panel's committed results. `--check` fails if they are stale. |
| `data/inputs.json` | The figures the panel reports do not hold, each with its source: route display names, the estimated API price for Claude Sonnet 5.5, and which routes have a batch price. |
| `data/panel-data.json` | Built. Every route's score, answered pages and price, for each of the four charts. |
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
- `ocr-panel-cloud-pilot.md`: the three-page pilot that came before the full cloud run.

The scripts that produced them are in `ArchiveProcessor/scripts/segbench/` (`ocr_panel.py`,
`ocr_panel_score.py`, `ocr_cloud_full.py` and their neighbours); each report ends with its reproduction steps.

## Rebuilding

```bash
python3 ArchiveOCRBench/build.py
```

Run it after any panel result changes, and commit the two built files with the change. It needs only the
Python standard library.

## How to read the page

- **NES** is normalized edit similarity: one minus the character edit distance divided by the longer text's
  length, averaged over pages. A failed page scores 0, which is why routes with failures fall further than
  their good readings suggest.
- **Prices** are the measured charge per page, times 1,000: OpenRouter's on the panel's pinned endpoint, and
  Mistral's published rate for Mistral OCR. The local panel's costs include its reports' conservative ceilings
  for calls with no billing record. Apple
  Vision runs on the device and is drawn in a "free" column. Claude Sonnet 5.5 ran on the subscription, so its
  price is an estimate (`data/inputs.json` → `sonnet_api_estimate`).
- **Batch points** sit at half the measured cost, for routes whose batch price is half their standard price.
  A dotted line joins the two points.
- **The best-value line** links the points that no other point beats on both price and score. It is worked out
  across standard and batch prices together.
- **The kind charts** reuse each route's average price over all 96 pages, so they compare accuracy at a route's
  usual price, not the price of that kind of page.

## Limits

These are the panel's own, from its reports. One corpus of about 100 pages. Claude Opus 5.5 and Gemini 3.8
Flash drafted the truth before it was adjudicated, so it may lean toward those families. The "local panel"
chose models small enough to run on a Mac, but every route ran hosted on OpenRouter; quality on a Mac is not
measured. A difference of a point or two is not a ranking, and the handwritten chart rests on about 2,200 words.

The published copy of the page from 2026-10-15 is the private artifact
<https://claude.ai/artifact/LGb43P7kewBvqXJ6Kiwd41>, built from the same data.
