# features-lr — risk-coverage, calibration and weights (development set, leave-one-collection-out)

W36.seg-features. Logistic regression (L2, lambda 1.0, standardised features, threshold 0.5, none tuned) on per-boundary text, image and capture-time features, and in the -emb variants also on-device embedding similarities (Apple Vision image feature print, NaturalLanguage English sentence embedding; embed.swift); each development collection is predicted by a model fitted on the other two. Measured on Dean, Deaver, Herrnstein; tuned on nothing but the fixed choices above; Stanton and RG 165 not touched. Photo labels from the truth. Only gaps between two document pages are counted. 551 pages (about 480 document gaps, two collections per fit) is little data: per-collection numbers move by several points with one or two boundaries, and the weights below are not stable across folds.

## features-lr (base, with the time gap)

| collection | pages in exact doc | false splits | false merges | boundary F1 | log loss | Brier | ECE |
|---|---:|---:|---:|---:|---:|---:|---:|
| Dean | 74.0% | 6 | 10 | 0.930 | 0.213 | 0.061 | 0.040 |
| Deaver | 17.0% | 1 | 51 | 0.559 | 1.415 | 0.344 | 0.350 |
| Herrnstein | 91.7% | 4 | 1 | 0.974 | 0.112 | 0.029 | 0.051 |
| pooled | 64.7% | 11 | 62 | 0.864 | 0.510 | 0.128 | 0.106 |

Risk-coverage: a boundary is auto-accepted when the model's confidence in its decision, max(p, 1-p), is at least the threshold; the rest go to review.

**Dean** (191 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 83 | 43.5% | 1 | 1.2% | 53.5 |
| 0.98 | 100 | 52.4% | 1 | 1.0% | 45.0 |
| 0.95 | 122 | 63.9% | 2 | 1.6% | 34.2 |
| 0.90 | 138 | 72.3% | 3 | 2.2% | 26.2 |
| 0.85 | 143 | 74.9% | 4 | 2.8% | 23.8 |
| 0.80 | 156 | 81.7% | 6 | 3.8% | 17.3 |
| 0.70 | 173 | 90.6% | 9 | 5.2% | 8.9 |
| 0.60 | 180 | 94.2% | 9 | 5.0% | 5.4 |
| 0.50 | 191 | 100.0% | 16 | 8.4% | 0.0 |

Best error rate at coverage of at least 50%: 1.0% (1 of the 104 most confident gaps, coverage 54.5%); the cut is chosen on these same predictions, so this is optimistic.

**Deaver** (136 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 22 | 16.2% | 11 | 50.0% | 76.5 |
| 0.98 | 35 | 25.7% | 23 | 65.7% | 67.8 |
| 0.95 | 52 | 38.2% | 32 | 61.5% | 56.4 |
| 0.90 | 70 | 51.5% | 36 | 51.4% | 44.3 |
| 0.85 | 77 | 56.6% | 36 | 46.8% | 39.6 |
| 0.80 | 82 | 60.3% | 37 | 45.1% | 36.2 |
| 0.70 | 101 | 74.3% | 44 | 43.6% | 23.5 |
| 0.60 | 116 | 85.3% | 45 | 38.8% | 13.4 |
| 0.50 | 136 | 100.0% | 52 | 38.2% | 0.0 |

Best error rate at coverage of at least 50%: 37.9% (47 of the 124 most confident gaps, coverage 91.2%); the cut is chosen on these same predictions, so this is optimistic.

**Herrnstein** (167 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 88 | 52.7% | 0 | 0.0% | 39.5 |
| 0.98 | 99 | 59.3% | 0 | 0.0% | 34.0 |
| 0.95 | 114 | 68.3% | 1 | 0.9% | 26.5 |
| 0.90 | 130 | 77.8% | 1 | 0.8% | 18.5 |
| 0.85 | 140 | 83.8% | 1 | 0.7% | 13.5 |
| 0.80 | 149 | 89.2% | 1 | 0.7% | 9.0 |
| 0.70 | 155 | 92.8% | 2 | 1.3% | 6.0 |
| 0.60 | 165 | 98.8% | 5 | 3.0% | 1.0 |
| 0.50 | 167 | 100.0% | 5 | 3.0% | 0.0 |

Best error rate at coverage of at least 50%: 0.0% (0 of the 84 most confident gaps, coverage 50.3%); the cut is chosen on these same predictions, so this is optimistic.

**pooled** (494 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 193 | 39.1% | 12 | 6.2% | 54.6 |
| 0.98 | 234 | 47.4% | 24 | 10.3% | 47.2 |
| 0.95 | 288 | 58.3% | 35 | 12.2% | 37.4 |
| 0.90 | 338 | 68.4% | 40 | 11.8% | 28.3 |
| 0.85 | 360 | 72.9% | 41 | 11.4% | 24.3 |
| 0.80 | 387 | 78.3% | 44 | 11.4% | 19.4 |
| 0.70 | 429 | 86.8% | 55 | 12.8% | 11.8 |
| 0.60 | 461 | 93.3% | 59 | 12.8% | 6.0 |
| 0.50 | 494 | 100.0% | 73 | 14.8% | 0.0 |

Best error rate at coverage of at least 50%: 10.9% (41 of the 375 most confident gaps, coverage 75.9%); the cut is chosen on these same predictions, so this is optimistic.

Calibration (pooled held-out predictions, P(new document) in ten equal-width bins; ECE is the gap-weighted mean of |mean predicted - observed| over the bins):

| P(new) bin | gaps | mean predicted | observed share new |
|---|---:|---:|---:|
| 0.0–0.1 | 153 | 0.028 | 0.248 |
| 0.1–0.2 | 34 | 0.148 | 0.088 |
| 0.2–0.3 | 30 | 0.253 | 0.267 |
| 0.3–0.4 | 17 | 0.334 | 0.118 |
| 0.4–0.5 | 17 | 0.440 | 0.647 |
| 0.5–0.6 | 16 | 0.546 | 0.812 |
| 0.6–0.7 | 15 | 0.656 | 0.867 |
| 0.7–0.8 | 12 | 0.750 | 0.750 |
| 0.8–0.9 | 15 | 0.847 | 0.933 |
| 0.9–1.0 | 185 | 0.989 | 0.989 |

Weights: standardised logistic weights per fold (positive = favours a new document; the fold is named by its held-out collection) and permutation importance (rise in pooled held-out log loss when the feature is shuffled within the held-out collection; mean of 20 shuffles). Sorted by importance.

| feature | importance | weight (Dean out) | weight (Deaver out) | weight (Herrnstein out) |
|---|---:|---:|---:|---:|
| next_salutation | 0.3373 | +1.90 | +2.70 | +2.21 |
| log_time_gap | 0.2479 | +2.71 | +1.08 | +2.11 |
| next_pn_top_ge2 | 0.0683 | -1.00 | -0.89 | -0.94 |
| paper_diff | 0.0657 | +0.99 | +1.03 | +0.39 |
| prev_closing | 0.0362 | +0.63 | +0.86 | +0.59 |
| tfidf_cosine | 0.0189 | -0.92 | -0.13 | -0.62 |
| next_starts_lower | 0.0188 | -0.35 | -0.21 | -0.32 |
| next_memo | 0.0183 | +0.18 | +0.84 | +0.90 |
| pn_sequence | 0.0158 | -0.52 | -0.34 | -0.55 |
| paper_lum_diff | 0.0136 | -0.37 | -0.74 | -0.29 |
| next_date_top | 0.0118 | +0.21 | +0.48 | +0.28 |
| prev_ends_open | 0.0116 | -0.21 | -0.36 | -0.30 |
| log_chars_next | 0.0102 | +0.65 | +0.29 | +0.54 |
| ink_diff | 0.0057 | -0.55 | -0.18 | -0.36 |
| abs_log_len_ratio | 0.0036 | +0.19 | +0.17 | +0.15 |
| next_pn_any_ge2 | 0.0025 | -0.29 | -0.94 | -0.06 |
| missing_image | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_eq1 | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_top_eq1 | 0.0000 | +0.00 | +0.30 | +0.28 |
| next_page_of_ge2 | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_page_of_last | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_enclosure | -0.0018 | -0.12 | +0.46 | +0.34 |
| aspect_change | -0.0680 | +0.04 | -0.31 | +0.09 |
| orientation_change | -0.0763 | -0.03 | -0.33 | +0.09 |

The time gap ranks 2 of 26 by importance (0.2479); the largest is next_salutation (0.3373).

## features-lr-notime (base, without the time gap)

| collection | pages in exact doc | false splits | false merges | boundary F1 | log loss | Brier | ECE |
|---|---:|---:|---:|---:|---:|---:|---:|
| Dean | 77.6% | 23 | 3 | 0.897 | 0.252 | 0.083 | 0.070 |
| Deaver | 0.0% | 2 | 81 | 0.067 | 2.084 | 0.448 | 0.443 |
| Herrnstein | 76.2% | 8 | 4 | 0.938 | 0.162 | 0.047 | 0.053 |
| pooled | 56.0% | 33 | 88 | 0.773 | 0.726 | 0.172 | 0.137 |

Risk-coverage: a boundary is auto-accepted when the model's confidence in its decision, max(p, 1-p), is at least the threshold; the rest go to review.

**Dean** (191 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 86 | 45.0% | 0 | 0.0% | 52.0 |
| 0.98 | 97 | 50.8% | 0 | 0.0% | 46.5 |
| 0.95 | 107 | 56.0% | 1 | 0.9% | 41.6 |
| 0.90 | 121 | 63.4% | 1 | 0.8% | 34.7 |
| 0.85 | 134 | 70.2% | 4 | 3.0% | 28.2 |
| 0.80 | 146 | 76.4% | 5 | 3.4% | 22.3 |
| 0.70 | 162 | 84.8% | 10 | 6.2% | 14.4 |
| 0.60 | 180 | 94.2% | 20 | 11.1% | 5.4 |
| 0.50 | 191 | 100.0% | 26 | 13.6% | 0.0 |

Best error rate at coverage of at least 50%: 0.0% (0 of the 96 most confident gaps, coverage 50.3%); the cut is chosen on these same predictions, so this is optimistic.

**Deaver** (136 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 42 | 30.9% | 31 | 73.8% | 63.1 |
| 0.98 | 47 | 34.6% | 36 | 76.6% | 59.7 |
| 0.95 | 48 | 35.3% | 37 | 77.1% | 59.1 |
| 0.90 | 56 | 41.2% | 38 | 67.9% | 53.7 |
| 0.85 | 65 | 47.8% | 39 | 60.0% | 47.7 |
| 0.80 | 71 | 52.2% | 40 | 56.3% | 43.6 |
| 0.70 | 99 | 72.8% | 58 | 58.6% | 24.8 |
| 0.60 | 120 | 88.2% | 72 | 60.0% | 10.7 |
| 0.50 | 136 | 100.0% | 83 | 61.0% | 0.0 |

Best error rate at coverage of at least 50%: 54.7% (47 of the 86 most confident gaps, coverage 63.2%); the cut is chosen on these same predictions, so this is optimistic.

**Herrnstein** (167 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 78 | 46.7% | 0 | 0.0% | 44.5 |
| 0.98 | 91 | 54.5% | 1 | 1.1% | 38.0 |
| 0.95 | 104 | 62.3% | 1 | 1.0% | 31.5 |
| 0.90 | 119 | 71.3% | 1 | 0.8% | 24.0 |
| 0.85 | 139 | 83.2% | 2 | 1.4% | 14.0 |
| 0.80 | 148 | 88.6% | 3 | 2.0% | 9.5 |
| 0.70 | 154 | 92.2% | 5 | 3.2% | 6.5 |
| 0.60 | 160 | 95.8% | 9 | 5.6% | 3.5 |
| 0.50 | 167 | 100.0% | 12 | 7.2% | 0.0 |

Best error rate at coverage of at least 50%: 0.0% (0 of the 84 most confident gaps, coverage 50.3%); the cut is chosen on these same predictions, so this is optimistic.

**pooled** (494 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 206 | 41.7% | 31 | 15.0% | 52.3 |
| 0.98 | 235 | 47.6% | 37 | 15.7% | 47.0 |
| 0.95 | 259 | 52.4% | 39 | 15.1% | 42.6 |
| 0.90 | 296 | 59.9% | 40 | 13.5% | 35.9 |
| 0.85 | 338 | 68.4% | 45 | 13.3% | 28.3 |
| 0.80 | 365 | 73.9% | 48 | 13.2% | 23.4 |
| 0.70 | 415 | 84.0% | 73 | 17.6% | 14.3 |
| 0.60 | 460 | 93.1% | 101 | 22.0% | 6.2 |
| 0.50 | 494 | 100.0% | 121 | 24.5% | 0.0 |

Best error rate at coverage of at least 50%: 13.0% (40 of the 308 most confident gaps, coverage 62.3%); the cut is chosen on these same predictions, so this is optimistic.

Calibration (pooled held-out predictions, P(new document) in ten equal-width bins; ECE is the gap-weighted mean of |mean predicted - observed| over the bins):

| P(new) bin | gaps | mean predicted | observed share new |
|---|---:|---:|---:|
| 0.0–0.1 | 125 | 0.025 | 0.312 |
| 0.1–0.2 | 54 | 0.140 | 0.111 |
| 0.2–0.3 | 34 | 0.257 | 0.588 |
| 0.3–0.4 | 22 | 0.353 | 0.545 |
| 0.4–0.5 | 20 | 0.438 | 0.550 |
| 0.5–0.6 | 14 | 0.551 | 0.357 |
| 0.6–0.7 | 23 | 0.661 | 0.304 |
| 0.7–0.8 | 16 | 0.756 | 0.688 |
| 0.8–0.9 | 15 | 0.859 | 0.867 |
| 0.9–1.0 | 171 | 0.991 | 0.994 |

Weights: standardised logistic weights per fold (positive = favours a new document; the fold is named by its held-out collection) and permutation importance (rise in pooled held-out log loss when the feature is shuffled within the held-out collection; mean of 20 shuffles). Sorted by importance.

| feature | importance | weight (Dean out) | weight (Deaver out) | weight (Herrnstein out) |
|---|---:|---:|---:|---:|
| next_salutation | 0.4089 | +2.24 | +2.71 | +2.02 |
| next_pn_top_ge2 | 0.0868 | -0.93 | -0.99 | -1.00 |
| paper_diff | 0.0802 | +0.97 | +1.10 | +0.60 |
| prev_closing | 0.0447 | +0.34 | +0.96 | +0.87 |
| tfidf_cosine | 0.0436 | -1.48 | -0.18 | -1.18 |
| next_memo | 0.0395 | +0.29 | +0.77 | +0.61 |
| pn_sequence | 0.0189 | -0.57 | -0.36 | -0.71 |
| next_starts_lower | 0.0145 | -0.26 | -0.13 | -0.27 |
| paper_lum_diff | 0.0132 | -0.15 | -0.85 | -0.28 |
| log_chars_next | 0.0125 | +0.56 | +0.15 | +0.91 |
| prev_ends_open | 0.0102 | -0.20 | -0.29 | -0.22 |
| next_date_top | 0.0097 | +0.05 | +0.64 | +0.19 |
| abs_log_len_ratio | 0.0084 | +0.19 | +0.16 | +0.34 |
| ink_diff | 0.0057 | -0.50 | -0.12 | -0.38 |
| prev_page_of_last | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_eq1 | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_ge2 | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_top_eq1 | 0.0000 | +0.00 | +0.35 | +0.31 |
| missing_image | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_enclosure | -0.0008 | -0.03 | +0.53 | +0.27 |
| next_pn_any_ge2 | -0.0018 | -0.15 | -0.87 | +0.19 |
| aspect_change | -0.0626 | +0.15 | -0.33 | +0.19 |
| orientation_change | -0.0704 | +0.07 | -0.35 | +0.19 |

## features-emb-lr (embeddings, with the time gap)

| collection | pages in exact doc | false splits | false merges | boundary F1 | log loss | Brier | ECE |
|---|---:|---:|---:|---:|---:|---:|---:|
| Dean | 69.4% | 4 | 13 | 0.924 | 0.226 | 0.068 | 0.062 |
| Deaver | 23.4% | 11 | 39 | 0.643 | 1.188 | 0.319 | 0.310 |
| Herrnstein | 89.0% | 3 | 4 | 0.963 | 0.104 | 0.029 | 0.040 |
| pooled | 63.7% | 18 | 56 | 0.865 | 0.450 | 0.124 | 0.084 |

Risk-coverage: a boundary is auto-accepted when the model's confidence in its decision, max(p, 1-p), is at least the threshold; the rest go to review.

**Dean** (191 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 73 | 38.2% | 1 | 1.4% | 58.4 |
| 0.98 | 94 | 49.2% | 1 | 1.1% | 48.0 |
| 0.95 | 126 | 66.0% | 1 | 0.8% | 32.2 |
| 0.90 | 146 | 76.4% | 4 | 2.7% | 22.3 |
| 0.85 | 158 | 82.7% | 6 | 3.8% | 16.3 |
| 0.80 | 166 | 86.9% | 7 | 4.2% | 12.4 |
| 0.70 | 176 | 92.1% | 12 | 6.8% | 7.4 |
| 0.60 | 185 | 96.9% | 17 | 9.2% | 3.0 |
| 0.50 | 191 | 100.0% | 17 | 8.9% | 0.0 |

Best error rate at coverage of at least 50%: 0.8% (1 of the 128 most confident gaps, coverage 67.0%); the cut is chosen on these same predictions, so this is optimistic.

**Deaver** (136 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 16 | 11.8% | 6 | 37.5% | 80.5 |
| 0.98 | 20 | 14.7% | 10 | 50.0% | 77.9 |
| 0.95 | 41 | 30.1% | 22 | 53.7% | 63.8 |
| 0.90 | 59 | 43.4% | 30 | 50.8% | 51.7 |
| 0.85 | 76 | 55.9% | 34 | 44.7% | 40.3 |
| 0.80 | 86 | 63.2% | 38 | 44.2% | 33.6 |
| 0.70 | 101 | 74.3% | 40 | 39.6% | 23.5 |
| 0.60 | 120 | 88.2% | 44 | 36.7% | 10.7 |
| 0.50 | 136 | 100.0% | 50 | 36.8% | 0.0 |

Best error rate at coverage of at least 50%: 36.0% (41 of the 114 most confident gaps, coverage 83.8%); the cut is chosen on these same predictions, so this is optimistic.

**Herrnstein** (167 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 93 | 55.7% | 0 | 0.0% | 37.0 |
| 0.98 | 109 | 65.3% | 0 | 0.0% | 29.0 |
| 0.95 | 129 | 77.2% | 1 | 0.8% | 19.0 |
| 0.90 | 135 | 80.8% | 1 | 0.7% | 16.0 |
| 0.85 | 148 | 88.6% | 1 | 0.7% | 9.5 |
| 0.80 | 151 | 90.4% | 1 | 0.7% | 8.0 |
| 0.70 | 158 | 94.6% | 4 | 2.5% | 4.5 |
| 0.60 | 164 | 98.2% | 5 | 3.0% | 1.5 |
| 0.50 | 167 | 100.0% | 7 | 4.2% | 0.0 |

Best error rate at coverage of at least 50%: 0.0% (0 of the 84 most confident gaps, coverage 50.3%); the cut is chosen on these same predictions, so this is optimistic.

**pooled** (494 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 182 | 36.8% | 7 | 3.8% | 56.6 |
| 0.98 | 223 | 45.1% | 11 | 4.9% | 49.2 |
| 0.95 | 296 | 59.9% | 24 | 8.1% | 35.9 |
| 0.90 | 340 | 68.8% | 35 | 10.3% | 27.9 |
| 0.85 | 382 | 77.3% | 41 | 10.7% | 20.3 |
| 0.80 | 403 | 81.6% | 46 | 11.4% | 16.5 |
| 0.70 | 435 | 88.1% | 56 | 12.9% | 10.7 |
| 0.60 | 469 | 94.9% | 66 | 14.1% | 4.5 |
| 0.50 | 494 | 100.0% | 74 | 15.0% | 0.0 |

Best error rate at coverage of at least 50%: 6.0% (15 of the 251 most confident gaps, coverage 50.8%); the cut is chosen on these same predictions, so this is optimistic.

Calibration (pooled held-out predictions, P(new document) in ten equal-width bins; ECE is the gap-weighted mean of |mean predicted - observed| over the bins):

| P(new) bin | gaps | mean predicted | observed share new |
|---|---:|---:|---:|
| 0.0–0.1 | 157 | 0.028 | 0.210 |
| 0.1–0.2 | 36 | 0.141 | 0.250 |
| 0.2–0.3 | 20 | 0.248 | 0.350 |
| 0.3–0.4 | 12 | 0.329 | 0.333 |
| 0.4–0.5 | 13 | 0.452 | 0.231 |
| 0.5–0.6 | 12 | 0.553 | 0.583 |
| 0.6–0.7 | 22 | 0.655 | 0.727 |
| 0.7–0.8 | 12 | 0.746 | 0.750 |
| 0.8–0.9 | 27 | 0.855 | 0.926 |
| 0.9–1.0 | 183 | 0.988 | 0.989 |

Weights: standardised logistic weights per fold (positive = favours a new document; the fold is named by its held-out collection) and permutation importance (rise in pooled held-out log loss when the feature is shuffled within the held-out collection; mean of 20 shuffles). Sorted by importance.

| feature | importance | weight (Dean out) | weight (Deaver out) | weight (Herrnstein out) |
|---|---:|---:|---:|---:|
| next_salutation | 0.3337 | +1.97 | +2.63 | +2.28 |
| log_time_gap | 0.1466 | +2.49 | +0.64 | +1.79 |
| paper_diff | 0.0744 | +1.19 | +1.00 | +0.43 |
| next_pn_top_ge2 | 0.0689 | -0.97 | -0.78 | -1.01 |
| img_embed_cos | 0.0551 | -0.72 | -0.46 | -0.69 |
| prev_closing | 0.0281 | +0.41 | +0.70 | +0.81 |
| pn_sequence | 0.0188 | -0.53 | -0.34 | -0.49 |
| seam_embed_cos | 0.0186 | -0.68 | -0.28 | -0.70 |
| paper_lum_diff | 0.0186 | -0.74 | -0.62 | -0.43 |
| next_starts_lower | 0.0152 | -0.33 | -0.20 | -0.39 |
| next_memo | 0.0127 | +0.13 | +0.80 | +0.91 |
| next_date_top | 0.0127 | +0.25 | +0.58 | +0.38 |
| text_embed_cos | 0.0117 | -0.16 | -0.46 | +0.08 |
| tfidf_cosine | 0.0087 | -0.79 | -0.09 | -0.59 |
| prev_ends_open | 0.0079 | -0.13 | -0.25 | -0.32 |
| ink_diff | 0.0077 | -0.57 | -0.19 | -0.44 |
| log_chars_next | 0.0034 | +0.39 | +0.21 | +0.25 |
| missing_image | 0.0000 | +0.00 | +0.00 | +0.00 |
| missing_text_embed | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| missing_img_embed | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_page_of_last | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_eq1 | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_ge2 | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_top_eq1 | 0.0000 | +0.00 | +0.24 | +0.25 |
| next_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| abs_log_len_ratio | -0.0002 | -0.10 | -0.39 | -0.11 |
| next_pn_any_ge2 | -0.0005 | -0.16 | -1.01 | +0.09 |
| prev_enclosure | -0.0014 | -0.06 | +0.32 | +0.20 |
| aspect_change | -0.0773 | -0.05 | -0.34 | -0.00 |
| orientation_change | -0.0850 | -0.12 | -0.36 | -0.00 |

The time gap ranks 2 of 31 by importance (0.1466); the largest is next_salutation (0.3337).

## features-emb-lr-notime (embeddings, without the time gap)

| collection | pages in exact doc | false splits | false merges | boundary F1 | log loss | Brier | ECE |
|---|---:|---:|---:|---:|---:|---:|---:|
| Dean | 81.1% | 3 | 11 | 0.938 | 0.209 | 0.065 | 0.051 |
| Deaver | 17.7% | 14 | 42 | 0.600 | 1.473 | 0.362 | 0.331 |
| Herrnstein | 87.8% | 4 | 4 | 0.957 | 0.134 | 0.036 | 0.027 |
| pooled | 66.2% | 21 | 57 | 0.859 | 0.531 | 0.137 | 0.095 |

Risk-coverage: a boundary is auto-accepted when the model's confidence in its decision, max(p, 1-p), is at least the threshold; the rest go to review.

**Dean** (191 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 69 | 36.1% | 0 | 0.0% | 60.4 |
| 0.98 | 93 | 48.7% | 0 | 0.0% | 48.5 |
| 0.95 | 116 | 60.7% | 1 | 0.9% | 37.1 |
| 0.90 | 133 | 69.6% | 2 | 1.5% | 28.7 |
| 0.85 | 140 | 73.3% | 2 | 1.4% | 25.2 |
| 0.80 | 155 | 81.2% | 5 | 3.2% | 17.8 |
| 0.70 | 172 | 90.1% | 11 | 6.4% | 9.4 |
| 0.60 | 178 | 93.2% | 13 | 7.3% | 6.4 |
| 0.50 | 191 | 100.0% | 14 | 7.3% | 0.0 |

Best error rate at coverage of at least 50%: 0.0% (0 of the 96 most confident gaps, coverage 50.3%); the cut is chosen on these same predictions, so this is optimistic.

**Deaver** (136 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 23 | 16.9% | 13 | 56.5% | 75.8 |
| 0.98 | 31 | 22.8% | 20 | 64.5% | 70.5 |
| 0.95 | 39 | 28.7% | 28 | 71.8% | 65.1 |
| 0.90 | 52 | 38.2% | 33 | 63.5% | 56.4 |
| 0.85 | 62 | 45.6% | 36 | 58.1% | 49.7 |
| 0.80 | 73 | 53.7% | 41 | 56.2% | 42.3 |
| 0.70 | 90 | 66.2% | 43 | 47.8% | 30.9 |
| 0.60 | 114 | 83.8% | 47 | 41.2% | 14.8 |
| 0.50 | 136 | 100.0% | 56 | 41.2% | 0.0 |

Best error rate at coverage of at least 50%: 40.2% (49 of the 122 most confident gaps, coverage 89.7%); the cut is chosen on these same predictions, so this is optimistic.

**Herrnstein** (167 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 90 | 53.9% | 1 | 1.1% | 38.5 |
| 0.98 | 104 | 62.3% | 1 | 1.0% | 31.5 |
| 0.95 | 123 | 73.7% | 1 | 0.8% | 22.0 |
| 0.90 | 139 | 83.2% | 2 | 1.4% | 14.0 |
| 0.85 | 145 | 86.8% | 2 | 1.4% | 11.0 |
| 0.80 | 152 | 91.0% | 3 | 2.0% | 7.5 |
| 0.70 | 159 | 95.2% | 4 | 2.5% | 4.0 |
| 0.60 | 164 | 98.2% | 6 | 3.7% | 1.5 |
| 0.50 | 167 | 100.0% | 8 | 4.8% | 0.0 |

Best error rate at coverage of at least 50%: 0.0% (0 of the 84 most confident gaps, coverage 50.3%); the cut is chosen on these same predictions, so this is optimistic.

**pooled** (494 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 182 | 36.8% | 14 | 7.7% | 56.6 |
| 0.98 | 228 | 46.2% | 21 | 9.2% | 48.3 |
| 0.95 | 278 | 56.3% | 30 | 10.8% | 39.2 |
| 0.90 | 324 | 65.6% | 37 | 11.4% | 30.9 |
| 0.85 | 347 | 70.2% | 40 | 11.5% | 26.7 |
| 0.80 | 380 | 76.9% | 49 | 12.9% | 20.7 |
| 0.70 | 421 | 85.2% | 58 | 13.8% | 13.2 |
| 0.60 | 456 | 92.3% | 66 | 14.5% | 6.9 |
| 0.50 | 494 | 100.0% | 78 | 15.8% | 0.0 |

Best error rate at coverage of at least 50%: 9.7% (24 of the 248 most confident gaps, coverage 50.2%); the cut is chosen on these same predictions, so this is optimistic.

Calibration (pooled held-out predictions, P(new document) in ten equal-width bins; ECE is the gap-weighted mean of |mean predicted - observed| over the bins):

| P(new) bin | gaps | mean predicted | observed share new |
|---|---:|---:|---:|
| 0.0–0.1 | 148 | 0.027 | 0.243 |
| 0.1–0.2 | 31 | 0.156 | 0.226 |
| 0.2–0.3 | 24 | 0.237 | 0.208 |
| 0.3–0.4 | 16 | 0.344 | 0.188 |
| 0.4–0.5 | 17 | 0.455 | 0.353 |
| 0.5–0.6 | 21 | 0.549 | 0.714 |
| 0.6–0.7 | 19 | 0.653 | 0.737 |
| 0.7–0.8 | 17 | 0.744 | 0.765 |
| 0.8–0.9 | 25 | 0.853 | 0.800 |
| 0.9–1.0 | 176 | 0.988 | 0.994 |

Weights: standardised logistic weights per fold (positive = favours a new document; the fold is named by its held-out collection) and permutation importance (rise in pooled held-out log loss when the feature is shuffled within the held-out collection; mean of 20 shuffles). Sorted by importance.

| feature | importance | weight (Dean out) | weight (Deaver out) | weight (Herrnstein out) |
|---|---:|---:|---:|---:|
| next_salutation | 0.4106 | +2.31 | +2.63 | +2.25 |
| paper_diff | 0.0915 | +1.20 | +1.08 | +0.71 |
| img_embed_cos | 0.0877 | -1.09 | -0.55 | -1.09 |
| next_pn_top_ge2 | 0.0530 | -0.65 | -0.78 | -0.96 |
| next_memo | 0.0272 | +0.26 | +0.79 | +0.74 |
| pn_sequence | 0.0246 | -0.63 | -0.34 | -0.64 |
| seam_embed_cos | 0.0243 | -0.61 | -0.29 | -0.67 |
| prev_closing | 0.0229 | +0.10 | +0.69 | +0.95 |
| paper_lum_diff | 0.0198 | -0.59 | -0.64 | -0.53 |
| text_embed_cos | 0.0180 | -0.29 | -0.64 | -0.09 |
| next_starts_lower | 0.0124 | -0.26 | -0.14 | -0.32 |
| tfidf_cosine | 0.0122 | -1.15 | -0.07 | -0.96 |
| next_date_top | 0.0119 | +0.05 | +0.72 | +0.34 |
| ink_diff | 0.0107 | -0.56 | -0.20 | -0.53 |
| prev_ends_open | 0.0070 | -0.04 | -0.22 | -0.27 |
| log_chars_next | 0.0045 | +0.38 | +0.16 | +0.44 |
| abs_log_len_ratio | 0.0029 | -0.27 | -0.54 | -0.17 |
| prev_enclosure | 0.0009 | +0.05 | +0.37 | +0.19 |
| next_pn_top_eq1 | 0.0000 | +0.00 | +0.24 | +0.26 |
| next_page_of_ge2 | 0.0000 | +0.00 | +0.00 | +0.00 |
| missing_image | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_eq1 | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_page_of_last | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| missing_img_embed | 0.0000 | +0.00 | +0.00 | +0.00 |
| missing_text_embed | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_any_ge2 | -0.0001 | -0.17 | -1.05 | +0.24 |
| aspect_change | -0.0836 | +0.07 | -0.36 | +0.08 |
| orientation_change | -0.0913 | -0.01 | -0.38 | +0.08 |

## Why the held-out collections differ

Mean of selected features at true boundaries (new) and true continuations (cont), per collection. A feature that separates the classes in only one collection cannot be learned when that collection is held out: the model is fitted on the other two.

| feature | Dean new | Dean cont | Deaver new | Deaver cont | Herrnstein new | Herrnstein cont |
|---|---:|---:|---:|---:|---:|---:|
| next_salutation | 0.629 | 0.000 | 0.000 | 0.000 | 0.851 | 0.000 |
| prev_closing | 0.517 | 0.013 | 0.000 | 0.000 | 0.596 | 0.014 |
| next_pn_any_ge2 | 0.017 | 0.600 | 0.083 | 0.077 | 0.032 | 0.781 |
| next_date_top | 0.629 | 0.240 | 0.143 | 0.115 | 0.809 | 0.397 |
| tfidf_cosine | 0.147 | 0.171 | 0.136 | 0.415 | 0.200 | 0.199 |
| next_starts_lower | 0.034 | 0.080 | 0.143 | 0.481 | 0.085 | 0.055 |
| orientation_change | 0.009 | 0.027 | 0.417 | 0.135 | 0.000 | 0.041 |
| paper_diff | 26.820 | 17.554 | 22.189 | 18.970 | 30.721 | 8.093 |
| log_time_gap | 2.129 | 1.735 | 2.706 | 1.624 | 2.390 | 1.841 |
| img_embed_cos | 0.877 | 0.922 | 0.659 | 0.772 | 0.846 | 0.893 |
| text_embed_cos | 0.736 | 0.813 | 0.838 | 0.918 | 0.812 | 0.847 |
| seam_embed_cos | 0.603 | 0.665 | 0.589 | 0.655 | 0.626 | 0.696 |

