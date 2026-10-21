# Letter cues and layout regions in the feature model — W46.fix-seg-scorers

Made by `scripts/segbench/features_cues.py` (definitions in its docstring) from cached Apple Vision text and the PP-DocLayoutV3 pass of `layout.py`; no calls. Development boxes leave-one-collection-out, pooled; Lincoln and CREST from a fit on all three development boxes. Review = least-confident document gaps reviewed for 98% of pages in an exact document, summed over boxes.

## Development boxes (Dean, Deaver, Herrnstein), held out in turn

| model | pages exact | Dean / Deaver / Herrnstein | false splits | false merges | kappa | PQ | MNDD | log loss | review for 98% |
|---|---|---|---|---|---|---|---|---|---|
| base+none | 56.0% | 77.6% / 0.0% / 76.2% | 33 | 88 | 0.513 | 0.702 | 161 | 0.726 | 280 of 494 (56.7%) |
| base+letter | 55.6% | 78.1% / 0.0% / 74.6% | 35 | 90 | 0.497 | 0.692 | 155 | 0.728 | 270 of 494 (54.7%) |
| base+layout | 57.5% | 68.4% / 18.4% / 76.2% | 41 | 56 | 0.597 | 0.723 | 91 | 0.633 | 414 of 494 (83.8%) |
| base+letter+layout | 60.8% | 79.1% / 17.7% / 74.6% | 41 | 53 | 0.609 | 0.730 | 88 | 0.664 | 378 of 494 (76.5%) |
| emb+none | 66.2% | 81.1% / 17.7% / 87.8% | 21 | 57 | 0.682 | 0.749 | 83 | 0.531 | 277 of 494 (56.1%) |
| emb+letter | 64.5% | 74.5% / 20.6% / 87.8% | 26 | 56 | 0.664 | 0.744 | 85 | 0.536 | 273 of 494 (55.3%) |
| emb+layout | 59.1% | 61.7% / 19.9% / 86.7% | 33 | 58 | 0.625 | 0.723 | 82 | 0.542 | 397 of 494 (80.4%) |
| emb+letter+layout | 58.1% | 71.4% / 17.7% / 75.1% | 38 | 55 | 0.615 | 0.719 | 84 | 0.575 | 377 of 494 (76.3%) |

## Lincoln, fitted on the development boxes, no embeddings

| model | pages exact | false splits | false merges | kappa | PQ | MNDD | log loss | review for 98% |
|---|---|---|---|---|---|---|---|---|
| base+none | 33.7% | 23 | 16 | 0.656 | 0.582 | 60 | 0.450 | 258 of 260 (99.2%) |
| base+letter | 32.6% | 21 | 17 | 0.662 | 0.597 | 61 | 0.456 | 259 of 260 (99.6%) |
| base+layout | 41.0% | 11 | 19 | 0.721 | 0.619 | 54 | 0.418 | 260 of 260 (100.0%) |
| base+letter+layout | 42.1% | 14 | 14 | 0.747 | 0.650 | 56 | 0.432 | 260 of 260 (100.0%) |

## CREST, fitted on the development boxes, no embeddings

| model | pages exact | false splits | false merges | kappa | PQ | MNDD | log loss | review for 98% |
|---|---|---|---|---|---|---|---|---|
| base+none | 12.5% | 19 | 10 | 0.427 | 0.405 | 37 | 0.778 | 126 of 127 (99.2%) |
| base+letter | 11.7% | 15 | 12 | 0.430 | 0.402 | 33 | 0.634 | 125 of 127 (98.4%) |
| base+layout | 8.6% | 27 | 11 | 0.300 | 0.257 | 53 | 0.742 | 126 of 127 (99.2%) |
| base+letter+layout | 10.9% | 23 | 10 | 0.374 | 0.332 | 46 | 0.638 | 126 of 127 (99.2%) |

## How often the new cues fire (development document gaps)

| cue | fires | on a true boundary | precision | recall |
|---|---|---|---|---|
| g_salutation | 137 | 136 | 99.3% | 46.3% |
| g_closing | 132 | 129 | 97.7% | 43.9% |
| g_both | 95 | 95 | 100.0% | 32.3% |
| g_running_header | 125 | 66 | 52.8% | 22.4% |
| lay_next_title_top | 236 | 166 | 70.3% | 56.5% |
| lay_next_doc_title | 117 | 86 | 73.5% | 29.3% |
| lay_next_text_only | 159 | 68 | 42.8% | 23.1% |
| lay_prev_seal | 2 | 2 | 100.0% | 0.7% |
| lay_next_seal | 2 | 2 | 100.0% | 0.7% |
| lay_prev_image | 67 | 44 | 65.7% | 15.0% |
| lay_next_image | 69 | 40 | 58.0% | 13.6% |
| lay_next_table | 7 | 2 | 28.6% | 0.7% |

## Standardised weights of the new columns (base+letter+layout, fit on all three development boxes)

| column | weight |
|---|---|
| g_salutation | +0.878 |
| g_closing | +0.691 |
| g_both | +0.220 |
| g_running_header | -0.274 |
| lay_next_title_top | +0.264 |
| lay_next_doc_title | +0.299 |
| lay_next_text_only | -0.192 |
| lay_prev_seal | +0.055 |
| lay_next_seal | +0.043 |
| lay_prev_image | +0.005 |
| lay_next_image | +0.179 |
| lay_next_table | -0.208 |
| lay_hist_l1 | +0.067 |
| lay_log_regions_next | -0.023 |
| lay_region_change | +0.147 |
