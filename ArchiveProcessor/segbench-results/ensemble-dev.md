# W36.seg-ensemble — combining the voters (development set)

Run 2026-10-11 on Dean, Deaver and Herrnstein (551 pages, 494 gaps between two document pages); the test collections were not touched by anything on this page. Truth photo labels throughout. No new model call: every voter is read from its cache. Rule and threshold fitting: `scripts/segbench/ensemble.py` (module docstring).

Voters: C = window-claude; L = window-gemini-lite; W = whole-gemini; F = features-emb-lr-notime.

## Every voter set, threshold fitted leave-one-collection-out

Each development collection's row uses the level fitted on the other two (the smallest at which both reach 98% of pages in an exact document after review), so every figure here is held out in that sense. No review = the rule's decisions alone. Flagged = the gaps sent to review. Errors left = wrong decisions among the auto-accepted gaps, which review never sees.

| rank | voters | held-out collections at 98% after review | flagged per 100 pages | errors left (per 500 pages) | pages in exact doc, no review | after review | worst collection after review | levels (Dean / Deaver / Herrnstein) |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | C | 3 of 3 | 5.8 | 2 (1.8) | 90.7% | 99.0% | 98.3% | <= 0.850 / <= 0.850 / <= 0.850 |
| 2 | CW | 3 of 3 | 6.0 | 2 (1.8) | 93.1% | 99.0% | 98.3% | <= 0.850 / <= 0.850 / <= 0.850 |
| 3 | CL | 3 of 3 | 8.5 | 2 (1.8) | 88.2% | 99.0% | 98.3% | <= 0.850 / <= 0.850 / <= 0.850 |
| 4 | CLW | 3 of 3 | 8.5 | 2 (1.8) | 89.6% | 99.0% | 98.3% | <= 0.850 / <= 0.850 / <= 0.850 |
| 5 | L | 3 of 3 | 37.0 | 2 (1.8) | 84.6% | 99.2% | 98.6% | <= 0.950 / <= 0.950 / <= 0.950 |
| 6 | LW | 3 of 3 | 38.1 | 1 (0.9) | 92.7% | 99.6% | 99.0% | <= 0.950 / <= 0.950 / <= 0.950 |
| 7 | CF | 2 of 3 | 34.1 | 1 (0.9) | 77.0% | 98.3% | 95.0% | <= 0.844 / <= 0.842 / <= 0.790 |
| 8 | CLF | 2 of 3 | 34.1 | 2 (1.8) | 87.8% | 98.3% | 95.0% | <= 0.844 / <= 0.842 / <= 0.644 |
| 9 | CLWF | 2 of 3 | 34.1 | 2 (1.8) | 93.2% | 98.3% | 95.0% | <= 0.844 / <= 0.842 / <= 0.644 |
| 10 | CWF | 2 of 3 | 34.5 | 1 (0.9) | 92.7% | 98.3% | 95.0% | <= 0.844 / <= 0.842 / <= 0.790 |
| 11 | WF | 2 of 3 | 43.9 | 1 (0.9) | 87.1% | 98.3% | 95.0% | <= 0.950 / <= 0.950 / <= 0.912 |
| 12 | LF | 2 of 3 | 48.5 | 1 (0.9) | 78.0% | 98.3% | 95.0% | <= 0.950 / <= 0.950 / <= 0.845 |
| 13 | LWF | 2 of 3 | 48.8 | 1 (0.9) | 90.9% | 98.3% | 95.0% | <= 0.950 / <= 0.950 / <= 0.845 |
| 14 | W | 2 of 3 | 67.0 | 1 (0.9) | 93.1% | 98.8% | 95.7% | <= 0.990 / <= 0.950 / <= 0.990 |
| 15 | F | 2 of 3 | 83.5 | 12 (10.9) | 66.2% | 92.9% | 73.8% | <= 1.000 / <= 0.991 / <= 1.000 |

Finalists (the top 2 by the rule in the module docstring): **C** (window-claude); **CW** (window-claude + whole-gemini).

## Unanimity alone (no fitted parameter)

| voters | flagged per 100 pages | errors left | after review | worst collection after review |
|---|---:|---:|---:|---:|
| C | 0.0 | 11 | 90.7% | 85.2% |
| CW | 1.3 | 9 | 94.2% | 91.2% |
| CL | 4.5 | 8 | 92.9% | 88.8% |
| CLW | 4.9 | 6 | 96.3% | 93.4% |
| L | 0.0 | 30 | 84.6% | 72.3% |
| LW | 4.0 | 11 | 95.2% | 93.4% |
| CF | 14.0 | 6 | 96.1% | 95.0% |
| CLF | 16.3 | 5 | 96.9% | 95.0% |
| CLWF | 16.5 | 4 | 97.3% | 95.0% |
| CWF | 14.7 | 5 | 96.5% | 95.0% |
| WF | 14.2 | 7 | 95.4% | 93.6% |
| LF | 14.2 | 15 | 92.7% | 84.4% |
| LWF | 16.2 | 6 | 96.1% | 93.6% |
| W | 0.0 | 14 | 93.1% | 91.2% |
| F | 0.0 | 78 | 66.2% | 17.7% |

## The finalists by collection (held out)

| voters | collection | level (fitted on the other two) | flagged | per 100 pages | errors left | no review | after review |
|---|---|---|---:|---:|---:|---:|---:|
| C | Dean | <= 0.850 | 13 | 6.4 | 1 | 85.2% | 99.0% |
| C | Deaver | <= 0.850 | 7 | 4.7 | 0 | 97.9% | 100.0% |
| C | Herrnstein | <= 0.850 | 12 | 6.0 | 1 | 91.2% | 98.3% |
| CW | Dean | <= 0.850 | 13 | 6.4 | 1 | 94.4% | 99.0% |
| CW | Deaver | <= 0.850 | 8 | 5.4 | 0 | 93.6% | 100.0% |
| CW | Herrnstein | <= 0.850 | 12 | 6.0 | 1 | 91.2% | 98.3% |

## Risk–coverage, pooled development set

The level swept over every value, pooled over the three collections. Coverage = share of the 494 document gaps auto-accepted. This is the trade-off itself, read in-sample; the held-out levels are the table above. Full curves: ensemble-curves-dev.tsv.

### C (window-claude)

| level | coverage | errors among accepted | error rate | flagged per 100 pages | after review, pooled | worst collection |
|---|---:|---:|---:|---:|---:|---:|
| unanimity | 100.0% | 11 | 2.2% | 0.0 | 90.7% | 85.2% |
| <= 0.625 | 99.4% | 10 | 2.0% | 0.5 | 91.1% | 86.2% |
| <= 0.735 | 98.2% | 8 | 1.6% | 1.6 | 95.0% | 93.4% |
| <= 0.760 | 97.2% | 8 | 1.7% | 2.5 | 95.0% | 93.4% |
| <= 0.840 | 95.1% | 5 | 1.1% | 4.4 | 96.3% | 93.4% |
| <= 0.850 | 93.5% | 2 | 0.4% | 5.8 | 99.0% | 98.3% |
| <= 0.900 | 90.1% | 2 | 0.4% | 8.9 | 99.0% | 98.3% |
| <= 0.925 | 82.0% | 2 | 0.5% | 16.2 | 99.0% | 98.3% |
| <= 0.965 | 21.5% | 0 | 0.0% | 70.4 | 100.0% | 100.0% |

### CW (window-claude + whole-gemini)

| level | coverage | errors among accepted | error rate | flagged per 100 pages | after review, pooled | worst collection |
|---|---:|---:|---:|---:|---:|---:|
| unanimity | 98.6% | 9 | 1.8% | 1.3 | 94.2% | 91.2% |
| <= 0.625 | 98.2% | 9 | 1.9% | 1.6 | 94.2% | 91.2% |
| <= 0.740 | 97.2% | 8 | 1.7% | 2.5 | 95.0% | 93.4% |
| <= 0.825 | 95.1% | 5 | 1.1% | 4.4 | 96.3% | 93.4% |
| <= 0.850 | 93.3% | 2 | 0.4% | 6.0 | 99.0% | 98.3% |
| <= 0.900 | 90.1% | 2 | 0.4% | 8.9 | 99.0% | 98.3% |
| <= 0.925 | 82.0% | 2 | 0.5% | 16.2 | 99.0% | 98.3% |
| <= 0.965 | 21.5% | 0 | 0.0% | 70.4 | 100.0% | 100.0% |

### W (whole-gemini)

| level | coverage | errors among accepted | error rate | flagged per 100 pages | after review, pooled | worst collection |
|---|---:|---:|---:|---:|---:|---:|
| unanimity | 100.0% | 14 | 2.8% | 0.0 | 93.1% | 91.2% |
| <= 0.850 | 99.2% | 10 | 2.0% | 0.7 | 93.1% | 91.2% |
| <= 0.900 | 98.8% | 9 | 1.8% | 1.1 | 93.1% | 91.2% |
| <= 0.950 | 91.3% | 3 | 0.7% | 7.8 | 97.9% | 95.7% |
| <= 0.980 | 81.6% | 3 | 0.7% | 16.5 | 97.9% | 95.7% |
| <= 0.990 | 0.0% | 0 | — | 89.7 | 100.0% | 100.0% |

## Approach G — the phone's "End segment" marks on RG 165

Not measurable: unknown. RG 165 is the only Live Capture box, but its ground-truth folder holds only the CSV and the camera's JPEGs (Pixel 9 HDR+ files, no Archive Capture metadata), and no staging manifest or recorded group list for it survives under Test Files/ (the only other RG 165 files there are the spring Gemini runs' outputs). How many errors the operator's segment marks would have removed cannot be counted from what is kept; it would need a fresh Live Capture box whose groups are saved.

