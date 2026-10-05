# features-lr — risk-coverage, calibration and weights (development set, leave-one-collection-out)

W36.seg-features checkpoint 1. Logistic regression (L2, lambda 1.0, standardised features, threshold 0.5, none tuned) on per-boundary text, image and capture-time features; each development collection is predicted by a model fitted on the other two. Measured on Dean, Deaver, Herrnstein; tuned on nothing but the fixed choices above; Stanton and RG 165 not touched. Photo labels from the truth. Only gaps between two document pages are counted. 551 pages (about 480 document gaps, two collections per fit) is little data: per-collection numbers move by several points with one or two boundaries, and the weights below are not stable across folds.

## features-lr (with the time gap)

| collection | pages in exact doc | false splits | false merges | boundary F1 | log loss | Brier |
|---|---:|---:|---:|---:|---:|---:|
| Dean | 73.0% | 6 | 10 | 0.930 | 0.287 | 0.078 |
| Deaver | 9.9% | 2 | 67 | 0.303 | 1.351 | 0.380 |
| Herrnstein | 82.9% | 10 | 2 | 0.938 | 0.289 | 0.059 |
| pooled | 59.3% | 18 | 79 | 0.814 | 0.581 | 0.155 |

Risk-coverage: a boundary is auto-accepted when the model's confidence in its decision, max(p, 1-p), is at least the threshold; the rest go to review.

**Dean** (191 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 60 | 31.4% | 1 | 1.7% | 64.9 |
| 0.98 | 79 | 41.4% | 3 | 3.8% | 55.4 |
| 0.95 | 106 | 55.5% | 4 | 3.8% | 42.1 |
| 0.90 | 124 | 64.9% | 6 | 4.8% | 33.2 |
| 0.85 | 140 | 73.3% | 8 | 5.7% | 25.2 |
| 0.80 | 146 | 76.4% | 8 | 5.5% | 22.3 |
| 0.70 | 165 | 86.4% | 9 | 5.5% | 12.9 |
| 0.60 | 179 | 93.7% | 12 | 6.7% | 5.9 |
| 0.50 | 191 | 100.0% | 16 | 8.4% | 0.0 |

Best error rate at coverage of at least 50%: 3.6% (4 of the 112 most confident gaps, coverage 58.6%); the cut is chosen on these same predictions, so this is optimistic.

**Deaver** (136 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 10 | 7.4% | 3 | 30.0% | 84.6 |
| 0.98 | 22 | 16.2% | 12 | 54.5% | 76.5 |
| 0.95 | 40 | 29.4% | 28 | 70.0% | 64.4 |
| 0.90 | 51 | 37.5% | 35 | 68.6% | 57.0 |
| 0.85 | 63 | 46.3% | 36 | 57.1% | 49.0 |
| 0.80 | 68 | 50.0% | 36 | 52.9% | 45.6 |
| 0.70 | 87 | 64.0% | 40 | 46.0% | 32.9 |
| 0.60 | 117 | 86.0% | 59 | 50.4% | 12.8 |
| 0.50 | 136 | 100.0% | 69 | 50.7% | 0.0 |

Best error rate at coverage of at least 50%: 45.5% (40 of the 88 most confident gaps, coverage 64.7%); the cut is chosen on these same predictions, so this is optimistic.

**Herrnstein** (167 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 83 | 49.7% | 3 | 3.6% | 42.0 |
| 0.98 | 89 | 53.3% | 3 | 3.4% | 39.0 |
| 0.95 | 102 | 61.1% | 3 | 2.9% | 32.5 |
| 0.90 | 115 | 68.9% | 3 | 2.6% | 26.0 |
| 0.85 | 126 | 75.4% | 4 | 3.2% | 20.5 |
| 0.80 | 133 | 79.6% | 4 | 3.0% | 17.0 |
| 0.70 | 147 | 88.0% | 6 | 4.1% | 10.0 |
| 0.60 | 158 | 94.6% | 7 | 4.4% | 4.5 |
| 0.50 | 167 | 100.0% | 12 | 7.2% | 0.0 |

Best error rate at coverage of at least 50%: 2.5% (3 of the 120 most confident gaps, coverage 71.9%); the cut is chosen on these same predictions, so this is optimistic.

**pooled** (494 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 153 | 31.0% | 7 | 4.6% | 61.9 |
| 0.98 | 190 | 38.5% | 18 | 9.5% | 55.2 |
| 0.95 | 248 | 50.2% | 35 | 14.1% | 44.6 |
| 0.90 | 290 | 58.7% | 44 | 15.2% | 37.0 |
| 0.85 | 329 | 66.6% | 48 | 14.6% | 29.9 |
| 0.80 | 347 | 70.2% | 48 | 13.8% | 26.7 |
| 0.70 | 399 | 80.8% | 55 | 13.8% | 17.2 |
| 0.60 | 454 | 91.9% | 78 | 17.2% | 7.3 |
| 0.50 | 494 | 100.0% | 97 | 19.6% | 0.0 |

Best error rate at coverage of at least 50%: 13.5% (51 of the 378 most confident gaps, coverage 76.5%); the cut is chosen on these same predictions, so this is optimistic.

Calibration (pooled held-out predictions, P(new document) in ten equal-width bins):

| P(new) bin | gaps | mean predicted | observed share new |
|---|---:|---:|---:|
| 0.0–0.1 | 124 | 0.031 | 0.315 |
| 0.1–0.2 | 43 | 0.138 | 0.070 |
| 0.2–0.3 | 36 | 0.247 | 0.111 |
| 0.3–0.4 | 39 | 0.353 | 0.538 |
| 0.4–0.5 | 22 | 0.440 | 0.545 |
| 0.5–0.6 | 18 | 0.549 | 0.611 |
| 0.6–0.7 | 16 | 0.651 | 0.875 |
| 0.7–0.8 | 16 | 0.758 | 0.812 |
| 0.8–0.9 | 14 | 0.857 | 0.929 |
| 0.9–1.0 | 166 | 0.988 | 0.970 |

Weights: standardised logistic weights per fold (positive = favours a new document; the fold is named by its held-out collection) and permutation importance (rise in pooled held-out log loss when the feature is shuffled within the held-out collection; mean of 20 shuffles). Sorted by importance.

| feature | importance | weight (Dean out) | weight (Deaver out) | weight (Herrnstein out) |
|---|---:|---:|---:|---:|
| next_salutation | 0.3190 | +1.45 | +1.86 | +2.11 |
| log_time_gap | 0.1094 | +1.67 | +0.33 | +1.81 |
| next_pn_top_ge2 | 0.0697 | -0.89 | -0.69 | -0.82 |
| paper_diff | 0.0326 | +0.63 | +0.59 | +0.21 |
| tfidf_cosine | 0.0278 | -1.06 | -0.15 | -0.81 |
| prev_closing | 0.0261 | +0.45 | +0.57 | +0.37 |
| pn_sequence | 0.0216 | -0.52 | -0.56 | -0.68 |
| next_date_top | 0.0214 | +0.27 | +0.62 | +0.47 |
| next_memo | 0.0146 | +0.22 | +0.35 | +0.35 |
| next_starts_lower | 0.0084 | -0.19 | -0.10 | -0.23 |
| prev_ends_open | 0.0080 | -0.11 | -0.27 | -0.22 |
| log_chars_next | 0.0074 | +0.62 | +0.07 | +0.32 |
| ink_diff | 0.0057 | -0.54 | -0.17 | -0.22 |
| abs_log_len_ratio | 0.0016 | +0.05 | +0.08 | +0.09 |
| paper_lum_diff | 0.0015 | -0.14 | -0.24 | -0.16 |
| prev_enclosure | 0.0009 | +0.01 | +0.38 | +0.16 |
| next_page_of_ge2 | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_top_eq1 | 0.0000 | +0.00 | +0.37 | +0.27 |
| prev_page_of_last | 0.0000 | +0.00 | +0.00 | +0.00 |
| missing_image | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_eq1 | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_any_ge2 | -0.0015 | -0.18 | -0.61 | +0.09 |
| aspect_change | -0.0419 | +0.07 | -0.22 | +0.05 |
| orientation_change | -0.0490 | +0.01 | -0.24 | +0.05 |

The time gap ranks 2 of 26 by importance (0.1094); the largest is next_salutation (0.3190).

## features-lr-notime (without the time gap)

| collection | pages in exact doc | false splits | false merges | boundary F1 | log loss | Brier |
|---|---:|---:|---:|---:|---:|---:|
| Dean | 72.4% | 23 | 8 | 0.876 | 0.319 | 0.099 |
| Deaver | 0.0% | 3 | 79 | 0.068 | 1.588 | 0.429 |
| Herrnstein | 71.8% | 10 | 5 | 0.921 | 0.264 | 0.067 |
| pooled | 52.5% | 36 | 92 | 0.757 | 0.649 | 0.179 |

Risk-coverage: a boundary is auto-accepted when the model's confidence in its decision, max(p, 1-p), is at least the threshold; the rest go to review.

**Dean** (191 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 62 | 32.5% | 1 | 1.6% | 63.9 |
| 0.98 | 88 | 46.1% | 1 | 1.1% | 51.0 |
| 0.95 | 103 | 53.9% | 2 | 1.9% | 43.6 |
| 0.90 | 112 | 58.6% | 4 | 3.6% | 39.1 |
| 0.85 | 130 | 68.1% | 6 | 4.6% | 30.2 |
| 0.80 | 141 | 73.8% | 8 | 5.7% | 24.8 |
| 0.70 | 159 | 83.2% | 11 | 6.9% | 15.8 |
| 0.60 | 178 | 93.2% | 23 | 12.9% | 6.4 |
| 0.50 | 191 | 100.0% | 31 | 16.2% | 0.0 |

Best error rate at coverage of at least 50%: 1.0% (1 of the 101 most confident gaps, coverage 52.9%); the cut is chosen on these same predictions, so this is optimistic.

**Deaver** (136 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 13 | 9.6% | 6 | 46.2% | 82.6 |
| 0.98 | 37 | 27.2% | 25 | 67.6% | 66.4 |
| 0.95 | 43 | 31.6% | 31 | 72.1% | 62.4 |
| 0.90 | 52 | 38.2% | 36 | 69.2% | 56.4 |
| 0.85 | 64 | 47.1% | 36 | 56.2% | 48.3 |
| 0.80 | 73 | 53.7% | 39 | 53.4% | 42.3 |
| 0.70 | 99 | 72.8% | 52 | 52.5% | 24.8 |
| 0.60 | 130 | 95.6% | 79 | 60.8% | 4.0 |
| 0.50 | 136 | 100.0% | 82 | 60.3% | 0.0 |

Best error rate at coverage of at least 50%: 50.6% (41 of the 81 most confident gaps, coverage 59.6%); the cut is chosen on these same predictions, so this is optimistic.

**Herrnstein** (167 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 76 | 45.5% | 2 | 2.6% | 45.5 |
| 0.98 | 89 | 53.3% | 2 | 2.2% | 39.0 |
| 0.95 | 94 | 56.3% | 2 | 2.1% | 36.5 |
| 0.90 | 107 | 64.1% | 3 | 2.8% | 30.0 |
| 0.85 | 115 | 68.9% | 3 | 2.6% | 26.0 |
| 0.80 | 127 | 76.0% | 4 | 3.1% | 20.0 |
| 0.70 | 147 | 88.0% | 6 | 4.1% | 10.0 |
| 0.60 | 156 | 93.4% | 10 | 6.4% | 5.5 |
| 0.50 | 167 | 100.0% | 15 | 9.0% | 0.0 |

Best error rate at coverage of at least 50%: 2.0% (2 of the 101 most confident gaps, coverage 60.5%); the cut is chosen on these same predictions, so this is optimistic.

**pooled** (494 document gaps)

| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |
|---:|---:|---:|---:|---:|---:|
| 0.99 | 151 | 30.6% | 9 | 6.0% | 62.3 |
| 0.98 | 214 | 43.3% | 28 | 13.1% | 50.8 |
| 0.95 | 240 | 48.6% | 35 | 14.6% | 46.1 |
| 0.90 | 271 | 54.9% | 43 | 15.9% | 40.5 |
| 0.85 | 309 | 62.6% | 45 | 14.6% | 33.6 |
| 0.80 | 341 | 69.0% | 51 | 15.0% | 27.8 |
| 0.70 | 405 | 82.0% | 69 | 17.0% | 16.2 |
| 0.60 | 464 | 93.9% | 112 | 24.1% | 5.4 |
| 0.50 | 494 | 100.0% | 128 | 25.9% | 0.0 |

Best error rate at coverage of at least 50%: 14.3% (45 of the 314 most confident gaps, coverage 63.6%); the cut is chosen on these same predictions, so this is optimistic.

Calibration (pooled held-out predictions, P(new document) in ten equal-width bins):

| P(new) bin | gaps | mean predicted | observed share new |
|---|---:|---:|---:|
| 0.0–0.1 | 107 | 0.026 | 0.364 |
| 0.1–0.2 | 53 | 0.149 | 0.113 |
| 0.2–0.3 | 46 | 0.248 | 0.326 |
| 0.3–0.4 | 36 | 0.346 | 0.750 |
| 0.4–0.5 | 17 | 0.449 | 0.294 |
| 0.5–0.6 | 13 | 0.547 | 0.154 |
| 0.6–0.7 | 23 | 0.640 | 0.304 |
| 0.7–0.8 | 18 | 0.745 | 0.833 |
| 0.8–0.9 | 17 | 0.861 | 0.882 |
| 0.9–1.0 | 164 | 0.990 | 0.976 |

Weights: standardised logistic weights per fold (positive = favours a new document; the fold is named by its held-out collection) and permutation importance (rise in pooled held-out log loss when the feature is shuffled within the held-out collection; mean of 20 shuffles). Sorted by importance.

| feature | importance | weight (Dean out) | weight (Deaver out) | weight (Herrnstein out) |
|---|---:|---:|---:|---:|
| next_salutation | 0.3719 | +1.72 | +1.87 | +2.06 |
| next_pn_top_ge2 | 0.0866 | -0.88 | -0.75 | -0.91 |
| tfidf_cosine | 0.0494 | -1.47 | -0.19 | -1.29 |
| paper_diff | 0.0404 | +0.67 | +0.63 | +0.42 |
| prev_closing | 0.0310 | +0.19 | +0.57 | +0.62 |
| pn_sequence | 0.0255 | -0.58 | -0.57 | -0.80 |
| next_memo | 0.0234 | +0.28 | +0.35 | +0.10 |
| next_date_top | 0.0189 | +0.17 | +0.69 | +0.36 |
| log_chars_next | 0.0116 | +0.51 | -0.00 | +0.71 |
| next_starts_lower | 0.0086 | -0.17 | -0.09 | -0.21 |
| prev_ends_open | 0.0071 | -0.15 | -0.23 | -0.16 |
| ink_diff | 0.0061 | -0.50 | -0.15 | -0.24 |
| abs_log_len_ratio | 0.0050 | +0.11 | +0.09 | +0.28 |
| paper_lum_diff | 0.0026 | -0.01 | -0.32 | -0.20 |
| prev_enclosure | 0.0012 | +0.06 | +0.42 | +0.08 |
| next_page_of_eq1 | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_page_of_ge2 | 0.0000 | +0.00 | +0.00 | +0.00 |
| prev_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_blank | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_top_eq1 | 0.0000 | +0.00 | +0.38 | +0.32 |
| prev_page_of_last | 0.0000 | +0.00 | +0.00 | +0.00 |
| missing_image | 0.0000 | +0.00 | +0.00 | +0.00 |
| next_pn_any_ge2 | -0.0039 | -0.13 | -0.59 | +0.27 |
| aspect_change | -0.0412 | +0.14 | -0.22 | +0.15 |
| orientation_change | -0.0485 | +0.07 | -0.25 | +0.15 |

## Why the held-out collections differ

Mean of selected features at true boundaries (new) and true continuations (cont), per collection. A feature that separates the classes in only one collection cannot be learned when that collection is held out: the model is fitted on the other two.

| feature | Dean new | Dean cont | Deaver new | Deaver cont | Herrnstein new | Herrnstein cont |
|---|---:|---:|---:|---:|---:|---:|
| next_salutation | 0.624 | 0.000 | 0.000 | 0.000 | 0.848 | 0.027 |
| prev_closing | 0.504 | 0.027 | 0.000 | 0.000 | 0.598 | 0.027 |
| next_pn_any_ge2 | 0.034 | 0.581 | 0.085 | 0.074 | 0.033 | 0.747 |
| next_date_top | 0.641 | 0.216 | 0.146 | 0.111 | 0.815 | 0.387 |
| tfidf_cosine | 0.148 | 0.171 | 0.130 | 0.414 | 0.201 | 0.196 |
| next_starts_lower | 0.034 | 0.081 | 0.146 | 0.463 | 0.087 | 0.053 |
| orientation_change | 0.009 | 0.027 | 0.415 | 0.148 | 0.000 | 0.040 |
| paper_diff | 26.920 | 17.272 | 22.102 | 19.222 | 30.451 | 9.005 |
| log_time_gap | 2.122 | 1.742 | 2.720 | 1.642 | 2.383 | 1.910 |

