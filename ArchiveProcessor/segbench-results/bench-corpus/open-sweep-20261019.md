# Open-model FarmShare sweep on the 895 public pages (2026-10-19 runs, scored 2026-10-20)

**A review baseline, nothing adopted.** This is Phase 0 of the processing review
(`execution-plans/processing-review/00-plan.md`). It scores readings already collected from FarmShare. No model
was called, no money was spent, and no catalogue entry, default or recommendation changes because of it.

Protocol: `execution-plans/open-model-sweep-20261019.md`. Scorer: `corpus/farmshare_expanded_report.py`, the
script that scored the Qwen 27B/35B extension, given `--route` arguments for the new models. Metric: the panel's
NES, chrF2 and pooled word miss/add rates from `ocr_panel_score.py`, unchanged. Files: `open-sweep-20261019.csv`
(route × subset × stratum), `open-sweep-20261019-pages.csv` (route × page, public page ids, no text),
`open-sweep-20261019.json` (overall rows, coverage, manifest checksums). Receipts:
`ArchiveOCRBench/data/open-sweep-20261019.json`.

Reproduce (raw readings live outside git, in `~/Claude/Long term storage/`):

```
cd ArchiveProcessor/scripts/segbench/corpus
O=".../FarmShare-open-sweep-20261019/outputs"; Q=".../FarmShare-20261019/results/ocr"; RC=".../FarmShare-20261019/recovery"
uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python farmshare_expanded_report.py \
  --manifest "$RC/manifest-895.jsonl" --base "$RC/manifest-440.jsonl" --name open-sweep-20261019 \
  --out ../../../segbench-results/bench-corpus \
  --route "glm-ocr=$O/glm-ocr/results/ocr/glm-ocr:native" --route "lightonocr3-4b=$O/lightonocr3-4b/results/ocr/lightonocr3-4b:native" \
  --route "lightonocr3-0.8b=$O/lightonocr3-08b/results/ocr/lightonocr3-08b:native" \
  --route "paddleocr-vl1.5=$O/paddleocr-vl15/results/ocr/paddleocr-vl15:native" \
  --route "qwen3-vl-8b=$O/qwen3-vl-8b/results/ocr/qwen3-vl-8b:panel" --route "qwen3.5-4b=$O/qwen35-4b/results/ocr/qwen35-4b:panel" \
  --route "qwen3.6-27b=$Q/qwen3.6-27b:panel" --route "qwen3.5-27b=$Q/qwen3.5-27b:panel" --route "qwen3.6-35b-a3b=$Q/qwen3.6-35b-a3b:panel"
```

## What was run

Six models, one NVIDIA L40S each, vLLM 0.31.0, the checkpoint's own bf16 weights, context 16,384, temperature 0,
thinking off, 8,192 output tokens, eight requests at a time. Every page went in as the same 2400 px JPEG 90 the
Qwen 27B/35B runs read; the image SHA-256 in every reading matches the Qwen3.6 27B reading of the same page, for all
895 pages and all eight other routes. The manifests are the unchanged `FarmShare-20261019/recovery/manifest-895.jsonl`
and `manifest-440.jsonl`, byte-identical to this folder's `manifest.jsonl` and `manifest-reference-440.jsonl`, and
`routes.frozen()` checked every source image and truth file against them.

Two kinds of route, kept apart in every table:

- **Panel**: the 96's prompt (KIND, TABLE, TEXT), parsed as the panel parses it. Qwen3-VL 8B, Qwen3.5 4B, and the
  three comparison rows.
- **Native**: the prompt the model card gives, scored as the model writes it. GLM-OCR (`Text Recognition:`),
  PaddleOCR-VL 1.5 (`OCR:`), LightOnOCR-3 0.8B and 4B (the image alone, no text).

The comparison rows are Qwen3.6 27B, Qwen3.5 27B and Qwen3.6 35B-A3B, fp8, the same prompt, settings and images,
read in two jobs (440 pages on 2026-10-18, 455 more in the 2026-10-19 extension). Rescored here with the same
script, their overall figures match `FarmShare-20261019/numeric-results/farmshare-expanded.json` exactly.

The 440-page subset is exactly the seven original strata (L5-L8, N1, N3, N4); the 455 added pages are the other
eight (L1-L4, L9, N2, N5, N6). So the stratum table below serves both subsets, and the subset totals differ only in
which strata they pool.

## Results

NES and chrF2 are per-page means with failures scored 0. "Answered" counts pages with a usable reading. Word rates
pool words over pages, and the tokenizer counts each Chinese character as a word, so N5 holds 34% of all truth words
on the 895 and the 15 newspapers (L9) another 16%; L5 holds 36% of the 440's. A route that fails on those strata
shows a high miss rate even where its NES is close to others'. GLM-OCR's word miss rate on N5 (79%) is far above
what its NES there (62.4) suggests; that was not investigated.

### All 895 pages

| model | route | answered | NES % | NES answered % | chrF2 % | words missed % | words added % |
|---|---|---:|---:|---:|---:|---:|---:|
| qwen3.6-35b-a3b (comparison) | panel | 818/895 | 63.9 | 69.9 | 59.8 | 31.7 | 19.6 |
| qwen3.6-27b (comparison) | panel | 798/895 | 63.3 | 71.0 | 58.3 | 32.7 | 19.2 |
| lightonocr3-4b | native | 810/895 | 62.9 | 69.5 | 58.2 | 35.4 | 21.5 |
| qwen3.5-27b (comparison) | panel | 764/895 | 62.2 | 72.8 | 57.8 | 31.6 | 17.0 |
| lightonocr3-0.8b | native | 750/895 | 56.7 | 67.6 | 52.4 | 43.1 | 20.9 |
| qwen3-vl-8b | panel | 659/895 | 53.3 | 72.3 | 49.6 | 42.5 | 14.7 |
| qwen3.5-4b | panel | 648/895 | 51.0 | 70.5 | 47.2 | 46.7 | 14.7 |
| glm-ocr | native | 680/895 | 48.6 | 64.0 | 42.8 | 71.4 | 13.1 |
| paddleocr-vl1.5 | native | 545/895 | 38.9 | 63.8 | 33.5 | 83.6 | 14.1 |

### The original 440 pages (the historical comparison)

| model | route | answered | NES % | NES answered % | chrF2 % | words missed % | words added % |
|---|---|---:|---:|---:|---:|---:|---:|
| lightonocr3-4b | native | 383/440 | 54.3 | 62.4 | 45.2 | 59.2 | 48.9 |
| qwen3.6-35b-a3b (comparison) | panel | 380/440 | 52.4 | 60.7 | 43.9 | 61.1 | 47.4 |
| qwen3.6-27b (comparison) | panel | 372/440 | 51.3 | 60.7 | 42.8 | 62.0 | 46.7 |
| qwen3.5-27b (comparison) | panel | 345/440 | 49.8 | 63.5 | 41.7 | 61.4 | 40.7 |
| lightonocr3-0.8b | native | 338/440 | 45.5 | 59.2 | 37.7 | 65.8 | 46.6 |
| qwen3-vl-8b | panel | 256/440 | 37.7 | 64.7 | 30.6 | 72.3 | 30.7 |
| glm-ocr | native | 282/440 | 33.8 | 52.7 | 26.9 | 77.2 | 29.1 |
| qwen3.5-4b | panel | 239/440 | 33.7 | 62.0 | 27.2 | 74.4 | 27.9 |
| paddleocr-vl1.5 | native | 213/440 | 24.5 | 50.6 | 18.2 | 87.2 | 26.5 |

The hosted reference routes read only these 440 pages (`routes.csv`, 2026-10-17): Gemini 3.8 Flash 70.3 NES
(419/440 answered, chrF2 63.4), Qwen3-VL 235B 51.6 (365/440, chrF2 41.2). They have no figure on the 895.

### The 455 added pages

| model | route | answered | NES % | NES answered % | chrF2 % | words missed % | words added % |
|---|---|---:|---:|---:|---:|---:|---:|
| qwen3.6-35b-a3b (comparison) | panel | 438/455 | 75.0 | 77.9 | 75.2 | 16.9 | 5.5 |
| qwen3.6-27b (comparison) | panel | 426/455 | 74.8 | 79.9 | 73.2 | 18.0 | 5.4 |
| qwen3.5-27b (comparison) | panel | 419/455 | 74.2 | 80.5 | 73.4 | 16.5 | 5.0 |
| lightonocr3-4b | native | 427/455 | 71.1 | 75.8 | 70.9 | 23.5 | 7.7 |
| qwen3-vl-8b | panel | 403/455 | 68.3 | 77.2 | 67.9 | 27.4 | 6.6 |
| qwen3.5-4b | panel | 409/455 | 67.8 | 75.4 | 66.5 | 32.7 | 8.0 |
| lightonocr3-0.8b | native | 412/455 | 67.5 | 74.5 | 66.6 | 31.7 | 8.0 |
| glm-ocr | native | 398/455 | 63.0 | 72.0 | 58.2 | 68.4 | 5.0 |
| paddleocr-vl1.5 | native | 332/455 | 52.7 | 72.3 | 48.3 | 81.7 | 7.9 |

### NES by stratum (failures as 0)

| stratum | pages | qwen3.6-35b-a3b | qwen3.6-27b | lightonocr3-4b | qwen3.5-27b | lightonocr3-0.8b | qwen3-vl-8b | qwen3.5-4b | glm-ocr | paddleocr-vl1.5 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| L1 English letters and diaries | 80 | 87.0 | 88.4 | 87.8 | 86.2 | 83.8 | 83.1 | 78.7 | 78.6 | 69.6 |
| L2 English manuscripts, 1700-1850 | 80 | 76.4 | 73.5 | 77.4 | 73.0 | 72.4 | 65.1 | 70.8 | 72.7 | 50.4 |
| L3 typescripts and telegrams | 80 | 95.0 | 96.0 | 93.5 | 95.8 | 90.7 | 93.6 | 93.2 | 92.0 | 92.4 |
| L4 ledgers and forms | 80 | 67.1 | 69.3 | 55.0 | 70.0 | 52.1 | 53.4 | 61.8 | 59.7 | 28.2 |
| L5 Dutch and Romance hands | 80 | 50.3 | 50.5 | 58.9 | 53.9 | 53.0 | 50.2 | 40.9 | 46.8 | 16.7 |
| L6 German Kurrent | 80 | 46.2 | 46.3 | 52.5 | 39.7 | 38.9 | 20.0 | 14.6 | 23.1 | 20.3 |
| L7 charters before 1600 | 80 | 39.0 | 34.1 | 40.2 | 31.9 | 27.2 | 32.8 | 27.5 | 25.4 | 6.7 |
| L8 early print, incl. Fraktur | 80 | 87.7 | 86.2 | 87.8 | 87.3 | 85.5 | 85.9 | 82.3 | 88.3 | 76.3 |
| L9 newspapers | 15 | 93.4 | 93.6 | 92.5 | 95.8 | 84.5 | 85.3 | 68.9 | 29.2 | 0.0 |
| N1 Arabic manuscripts | 40 | 54.0 | 43.6 | 50.6 | 47.8 | 43.1 | 25.3 | 30.8 | 1.5 | 28.2 |
| N2 Cyrillic | 40 | 21.2 | 17.1 | 8.9 | 14.8 | 4.2 | 14.4 | 6.5 | 8.2 | 3.2 |
| N3 Greek minuscule | 40 | 39.5 | 41.4 | 44.3 | 37.3 | 25.8 | 5.9 | 6.3 | 2.4 | 1.5 |
| N4 Hebrew book hands | 40 | 36.7 | 45.8 | 24.2 | 36.9 | 22.5 | 5.2 | 3.0 | 0.2 | 0.0 |
| N5 Chinese print | 40 | 82.1 | 80.7 | 72.8 | 79.7 | 74.3 | 78.3 | 72.1 | 62.4 | 56.2 |
| N6 Devanagari print | 40 | 63.6 | 63.3 | 65.4 | 63.0 | 59.3 | 62.3 | 58.1 | 28.7 | 59.3 |

### Answered pages by stratum

| stratum | pages | qwen3.6-35b-a3b | qwen3.6-27b | lightonocr3-4b | qwen3.5-27b | lightonocr3-0.8b | qwen3-vl-8b | qwen3.5-4b | glm-ocr | paddleocr-vl1.5 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| L1 | 80 | 78 | 80 | 78 | 79 | 78 | 77 | 77 | 79 | 73 |
| L2 | 80 | 76 | 73 | 77 | 72 | 77 | 66 | 75 | 78 | 57 |
| L3 | 80 | 79 | 80 | 80 | 80 | 80 | 79 | 79 | 80 | 80 |
| L4 | 80 | 79 | 73 | 80 | 74 | 75 | 66 | 78 | 79 | 47 |
| L5 | 80 | 64 | 62 | 74 | 64 | 64 | 60 | 53 | 62 | 29 |
| L6 | 80 | 71 | 71 | 75 | 59 | 59 | 32 | 25 | 44 | 39 |
| L7 | 80 | 68 | 67 | 72 | 57 | 67 | 52 | 51 | 69 | 33 |
| L8 | 80 | 80 | 79 | 80 | 79 | 80 | 79 | 77 | 80 | 74 |
| L9 | 15 | 15 | 15 | 15 | 15 | 14 | 15 | 12 | 6 | 0 |
| N1 | 40 | 36 | 31 | 32 | 33 | 29 | 19 | 21 | 6 | 29 |
| N2 | 40 | 33 | 28 | 20 | 21 | 12 | 24 | 14 | 22 | 10 |
| N3 | 40 | 35 | 35 | 35 | 30 | 25 | 6 | 7 | 3 | 4 |
| N4 | 40 | 26 | 27 | 15 | 23 | 14 | 8 | 5 | 18 | 5 |
| N5 | 40 | 38 | 37 | 37 | 38 | 36 | 37 | 34 | 28 | 25 |
| N6 | 40 | 40 | 40 | 40 | 40 | 40 | 39 | 40 | 26 | 40 |

### Second scores

The stratum's second score, as `routes.csv` reports it: historical letter forms mapped (L2, L5-L8), combining
marks removed (N1, N3, N4, N6), or whitespace removed (N5, the CER convention for Chinese).

| stratum | score | qwen3.6-35b-a3b | qwen3.6-27b | lightonocr3-4b | qwen3.5-27b | lightonocr3-0.8b | qwen3-vl-8b | qwen3.5-4b | glm-ocr | paddleocr-vl1.5 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| L2 | mapped | 76.4 | 73.6 | 77.4 | 73.0 | 72.4 | 65.1 | 70.8 | 72.7 | 50.4 |
| L5 | mapped | 52.0 | 52.2 | 60.8 | 55.7 | 54.7 | 51.7 | 42.1 | 48.1 | 17.0 |
| L6 | mapped | 46.7 | 46.7 | 53.0 | 40.2 | 39.2 | 20.2 | 14.7 | 23.3 | 20.4 |
| L7 | mapped | 40.0 | 35.0 | 41.4 | 32.7 | 28.0 | 33.5 | 28.2 | 25.8 | 6.8 |
| L8 | mapped | 90.6 | 89.1 | 90.9 | 90.2 | 88.7 | 89.1 | 85.1 | 91.0 | 77.4 |
| N1 | no marks | 54.9 | 44.5 | 51.9 | 49.2 | 43.8 | 27.2 | 31.4 | 1.5 | 29.8 |
| N3 | no marks | 44.4 | 48.0 | 49.8 | 41.8 | 30.2 | 7.4 | 7.6 | 3.0 | 1.7 |
| N4 | no marks | 39.3 | 45.8 | 24.2 | 37.4 | 23.2 | 5.9 | 3.0 | 0.2 | 0.0 |
| N5 | no spaces | 84.7 | 82.2 | 74.0 | 81.3 | 75.8 | 80.4 | 74.8 | 64.2 | 57.4 |
| N6 | no marks | 66.2 | 66.1 | 67.8 | 66.1 | 62.6 | 64.8 | 61.2 | 30.9 | 62.5 |

## Failures, caps and missing pages

Every route has a terminal reading for all 895 pages; none is missing. A reply that ran to the 8,192-token limit is
a cap, kept as the collector saved it, not re-asked, and scored as an empty reading.

| model | caps | of which repetitive (zlib ratio < 0.12) | answered but blank | unparsable panel reply | answered |
|---|---:|---:|---:|---:|---:|
| glm-ocr | 215 | 206 | 0 | – | 680 |
| qwen3-vl-8b | 236 | 227 | 0 | 0 | 659 |
| lightonocr3-0.8b | 145 | 141 | 0 | – | 750 |
| lightonocr3-4b | 76 | 75 | 9 | – | 810 |
| paddleocr-vl1.5 | 350 | 316 | 0 | – | 545 |
| qwen3.5-4b | 247 | 234 | 0 | 0 | 648 |
| qwen3.6-27b | 97 | | | 0 | 798 |
| qwen3.5-27b | 131 | | | 0 | 764 |
| qwen3.6-35b-a3b | 76 | | | 1 | 818 |

The repetition column is a diagnostic from the raw replies (compressed size under an eighth of the reply), not
part of the score: almost every cap is a loop, not a dense page that needed more tokens. Caps gather in the hard
hands and scripts (L5-L7, N1-N4) and, for PaddleOCR-VL, in all 15 newspapers and 33 ledgers. LightOnOCR-3 4B
returned nine stopped replies with no text; they score as failures.

## Native formatting

The raw replies were scanned for Markdown headings, bold, tables, HTML tags, LaTeX and coordinate or box tags
before scoring. No route emits coordinates or layout tags. GLM-OCR and PaddleOCR-VL write plain text (a handful
of pages carry a `$...$` span or a heading). The two panel models answer in the panel format on every stopped
reply. LightOnOCR-3 writes Markdown and HTML for structured pages: headings, bold, `<table>`/`<td>` tables, pipe
tables and image placeholders, on 96 answered pages for the 4B and 123 for the 0.8B.

No normalisation was added. The panel's `normal()` already removes table bars, and the precedent for a native
Markdown route is Mistral OCR on the 96, scored "removes table bars but not other Markdown"
(`ocr_cloud_full_report.py`). The LightOnOCR rows follow it. As a diagnostic only, stripping those tags and
headings from the affected pages raises their NES from 61.9 to 75.3 (4B) and from 65.3 to 76.5 (0.8B), about 1.4
and 1.5 points on the 895-page mean. The other two native routes move by less than 0.01. So the LightOnOCR rows
understate its reading by about a point and a half against the panel rows; a markup-aware score would be a new
convention for every native route and is left to the review.

## GPU time

One L40S per model. The collector time is the pilot and full-run wall clock from the Slurm output; the server span
runs from the first to the last line of the vLLM log and includes loading the model.

| model | collector, minutes | server span, minutes | GPU-hours per 1,000 pages (collector) |
|---|---:|---:|---:|
| lightonocr3-0.8b | 17.5 | 19.7 | 0.33 |
| paddleocr-vl1.5 | 18.9 | 20.1 | 0.35 |
| glm-ocr | 39.8 | 40.7 | 0.74 |
| lightonocr3-4b | 43.3 | 45.9 | 0.81 |
| qwen3.5-4b | 91.8 | 92.7 | 1.71 |
| qwen3-vl-8b | 178.8 | 180.4 | 3.33 |

Caps cost time: a capped page generates the full 8,192 tokens. Qwen3-VL 8B generated 2.34 million completion
tokens in all, PaddleOCR-VL 3.09 million in 19 minutes. The comparison rows read their pages in two jobs and have no
single figure here; their earlier speed figures are in `../farmshare/`.

## Not scored

- **Ling 3 Flash VL FP8**, job 1860274: completed on FarmShare (816 answered, 79 caps, per
  `execution-plans/general-model-sweep-20261019.md`). The readings are still on the cluster; nothing was retrieved
  to `FarmShare-general-sweep-20261019/` before the SSH login lapsed.
- **Nemotron 3.5 Super VL NVFP4**, job 1860275: the rerun was running on 2026-10-20 with about 457 pages left. Its
  final state is unknown; it could not be checked because the login is down. A partial cache is not scored.
- **Stock PP-OCRv6 medium**, job 1860044: completed (895 raw readings, one blank). Still on the cluster; not
  retrieved.
- **Inkling Small, Q4 GGUF on llama.cpp**, job 1860045: parked by the owner after a three-page pilot (2 answered,
  1 cap). No score.

## Reading

LightOnOCR-3 4B, a 4-billion-parameter OCR model reading the bare image, lands within a point of the three 27B/35B
Qwen models on the 895 pages (62.9 against 62.2-63.9), and on the original 440 it is ahead of all three (54.3 against
49.8-52.4), with the fewest failures of any route on those pages. Its strength is the historical Latin hands (L5,
L6, L7) and Greek; it is weaker on ledgers, Hebrew and Cyrillic. Its Markdown costs it about a point and a half
under this scorer, so the gap may be smaller still. It also reads about four times faster than Qwen3-VL 8B.
Differences of a point between these four are within what one run on these pages can tell apart; no paired test was
run.

The small general models, Qwen3-VL 8B and Qwen3.5 4B, read well when they answer (72.3 and 70.5 on the answered
pages, as good as the 27B models) but loop on a quarter of the pages, mostly in the hard hands and the non-Latin
scripts, and that sets their overall scores 10-13 points below. GLM-OCR and PaddleOCR-VL loop even more, and GLM-OCR
does not read Arabic or Hebrew at all: on Hebrew it returns only the page number. PaddleOCR-VL fails every
newspaper. On the clean material, typescripts (L3) and early print (L8), every route scores between 76 and 96 and the
differences are small.

Every open route is well below the hosted Gemini 3.8 Flash on the 440 pages (70.3); the best open figure there is
54.3. Cyrillic (N2) is poor for every route, at most 21 NES. Repetition loops, not misreading, account for most of
the distance between answered and overall scores for every model, which makes a loop guard or a second reading of
capped pages the first thing the review should consider for any local route.
