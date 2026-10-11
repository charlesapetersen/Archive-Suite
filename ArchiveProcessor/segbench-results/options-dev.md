# W36.seg-opt-measure — the approaches on the development set

Run 2026-10-11 on Dean, Deaver and Herrnstein (551 pages, 494 gaps between two document pages); the test collections are not touched by anything on this page. Truth photo labels. Every figure is held out per box: each box's row uses the level fitted on the other two. Method: `scripts/segbench/options.py` (module docstring).

Voters: C = window-claude (Claude Sonnet 5.5, prompt w1); G = window-gemini-3.8-flash-low (Gemini 3.8 Flash, thinking low, prompt g1).

## Each approach, held out per box

| approach | rule | boxes at 98% after review | pages in exact doc, no review | flagged per 100 pages | after review | worst box after review | unflagged errors (per 500 pages) | levels (Dean / Deaver / Herrnstein) |
|---|---|---:|---:|---:|---:|---:|---:|---|
| claude (C) | min | 3 of 3 | 90.7% | 5.8 | 99.0% | 98.3% | 2 (1.8) | <= 0.850 / <= 0.850 / <= 0.850 |
| gemini (G) | min | 2 of 3 | 90.7% | 10.3 | 98.6% | 98.0% | 3 (2.7) | <= 0.950 / <= 0.965 / <= 0.965 |
| mix (CG) | min | 3 of 3 | 90.7% | 6.0 | 99.0% | 98.3% | 2 (1.8) | <= 0.850 / <= 0.850 / <= 0.850 |

## The mix: combining rules compared

Ranked by boxes reaching 98% after review, then flagged per 100 pages, then unflagged errors. The first is the mix offered.

| voters | rule | boxes at 98% | flagged per 100 pages | unflagged errors | no review | after review |
|---|---|---:|---:|---:|---:|---:|
| CG | min | 3 of 3 | 6.0 | 2 | 90.7% | 99.0% |
| CG | mean | 2 of 3 | 5.4 | 3 | 90.7% | 98.6% |

## By box (held out)

| approach | box | level (fitted on the other two) | flagged | per 100 pages | unflagged errors | no review | after review |
|---|---|---|---:|---:|---:|---:|---:|
| claude | Dean | <= 0.850 | 13 | 6.4 | 1 | 85.2% | 99.0% |
| claude | Deaver | <= 0.850 | 7 | 4.7 | 0 | 97.9% | 100.0% |
| claude | Herrnstein | <= 0.850 | 12 | 6.0 | 1 | 91.2% | 98.3% |
| gemini | Dean | <= 0.950 | 8 | 4.0 | 2 | 85.2% | 98.0% |
| gemini | Deaver | <= 0.965 | 33 | 22.1 | 0 | 97.9% | 100.0% |
| gemini | Herrnstein | <= 0.965 | 16 | 8.0 | 1 | 91.2% | 98.3% |
| mix | Dean | <= 0.850 | 13 | 6.4 | 1 | 85.2% | 99.0% |
| mix | Deaver | <= 0.850 | 8 | 5.4 | 0 | 97.9% | 100.0% |
| mix | Herrnstein | <= 0.850 | 12 | 6.0 | 1 | 91.2% | 98.3% |

## Frozen for the test set (levels fitted on all three development boxes)

| approach | voters | rule | level |
|---|---|---|---|
| claude | C | min | <= 0.850 |
| gemini | G | min | <= 0.965 |
| mix | CG | min | <= 0.850 |

