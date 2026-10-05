# W36.seg-window — Claude over overlapping page windows (development set)

Run 2026-10-05 on Dean, Deaver and Herrnstein (551 pages) only; the test collections were not touched. Model claude-sonnet-5-5 through `claude -p` on the owner's subscription. Windows of 7 pages, stride 3, every gap judged in two windows (see method_window.py for why 7 and not 6). The prompt was written once, after earlier bench items had read development pages, and was not revised against page-level errors; nothing was fitted. So these are development numbers, not held-out ones in the strict sense.

## Two-window agreement

| collection | document gaps | judged twice+ | disagreements | error rate when agreed | error rate when disagreed |
|---|---:|---:|---:|---:|---:|
| Dean | 191 | 191 | 3 | 4.3% (8/188) | 33.3% (1/3) |
| Deaver | 136 | 136 | 1 | 0.7% (1/135) | 0.0% (0/1) |
| Herrnstein | 167 | 167 | 0 | 4.2% (7/167) | — (0/0) |
| pooled | 494 | 494 | 4 | 3.3% (16/490) | 25.0% (1/4) |

## Risk–coverage, photo labels from the truth

Document gaps (both pages are document pages in the truth), pooled over the three collections, accepted when the combined confidence is at or above a threshold (with agreement: only gaps both windows agreed on, at or above it). Thresholds rather than coverage fractions, because the confidences are coarse and a fraction would split ties arbitrarily. Error = accepted gaps whose boundary is wrong.

| signal | threshold | coverage | accepted | errors among accepted | error rate | gaps left to review per 100 pages |
|---|---:|---:|---:|---:|---:|---:|
| confidence | 0.00 | 100.0% | 494 | 17 | 3.4% | 0.0 |
| confidence | 0.80 | 96.8% | 478 | 13 | 2.7% | 2.9 |
| confidence | 0.90 | 90.7% | 448 | 9 | 2.0% | 8.3 |
| confidence | 0.93 | 82.0% | 405 | 9 | 2.2% | 16.2 |
| confidence | 0.95 | 66.0% | 326 | 7 | 2.1% | 30.5 |
| confidence | 0.96 | 50.4% | 249 | 7 | 2.8% | 44.5 |
| confidence | 0.97 | 21.7% | 107 | 3 | 2.8% | 70.2 |
| confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |
| agreement, then confidence | 0.00 | 99.2% | 490 | 16 | 3.3% | 0.7 |
| agreement, then confidence | 0.80 | 96.8% | 478 | 13 | 2.7% | 2.9 |
| agreement, then confidence | 0.90 | 90.7% | 448 | 9 | 2.0% | 8.3 |
| agreement, then confidence | 0.93 | 82.0% | 405 | 9 | 2.2% | 16.2 |
| agreement, then confidence | 0.95 | 66.0% | 326 | 7 | 2.1% | 30.5 |
| agreement, then confidence | 0.96 | 50.4% | 249 | 7 | 2.8% | 44.5 |
| agreement, then confidence | 0.97 | 21.7% | 107 | 3 | 2.8% | 70.2 |
| agreement, then confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |

### Review load to reach 98% pages in an exact document, photo labels from the truth

Simulated review: the owner checks the least-trusted boundaries in one order across all three collections (a single threshold) and each checked boundary is corrected to the truth. Counted in boundaries reviewed per 100 pages.

| signal | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| confidence (no review) | 0 | 0.0 | 88.8% | 82.7% | 96.5% | 89.5% |
| confidence | 6 | 1.1 | 92.3% | 91.8% | 96.5% | 89.5% |
| confidence | 147 | 26.7 | 95.9% | 96.9% | 100.0% | 91.7% |
| confidence | 468 | 84.9 | 98.1% | 100.0% | 100.0% | 94.5% |
| confidence (98% in every collection) | 494 | 89.7 | 100.0% | 100.0% | 100.0% | 100.0% |
| agreement, then confidence (no review) | 0 | 0.0 | 88.8% | 82.7% | 96.5% | 89.5% |
| agreement, then confidence | 6 | 1.1 | 92.3% | 91.8% | 96.5% | 89.5% |
| agreement, then confidence | 147 | 26.7 | 95.9% | 96.9% | 100.0% | 91.7% |
| agreement, then confidence | 468 | 84.9 | 98.1% | 100.0% | 100.0% | 94.5% |
| agreement, then confidence (98% in every collection) | 494 | 89.7 | 100.0% | 100.0% | 100.0% | 100.0% |

## Risk–coverage, the model's own photo labels

Document gaps (both pages are document pages in the truth), pooled over the three collections, accepted when the combined confidence is at or above a threshold (with agreement: only gaps both windows agreed on, at or above it). Thresholds rather than coverage fractions, because the confidences are coarse and a fraction would split ties arbitrarily. Error = accepted gaps whose boundary is wrong.

| signal | threshold | coverage | accepted | errors among accepted | error rate | gaps left to review per 100 pages |
|---|---:|---:|---:|---:|---:|---:|
| confidence | 0.00 | 100.0% | 494 | 17 | 3.4% | 0.0 |
| confidence | 0.80 | 96.8% | 478 | 13 | 2.7% | 2.9 |
| confidence | 0.90 | 90.7% | 448 | 9 | 2.0% | 8.3 |
| confidence | 0.93 | 82.0% | 405 | 9 | 2.2% | 16.2 |
| confidence | 0.95 | 66.0% | 326 | 7 | 2.1% | 30.5 |
| confidence | 0.96 | 50.4% | 249 | 7 | 2.8% | 44.5 |
| confidence | 0.97 | 21.7% | 107 | 3 | 2.8% | 70.2 |
| confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |
| agreement, then confidence | 0.00 | 99.2% | 490 | 16 | 3.3% | 0.7 |
| agreement, then confidence | 0.80 | 96.8% | 478 | 13 | 2.7% | 2.9 |
| agreement, then confidence | 0.90 | 90.7% | 448 | 9 | 2.0% | 8.3 |
| agreement, then confidence | 0.93 | 82.0% | 405 | 9 | 2.2% | 16.2 |
| agreement, then confidence | 0.95 | 66.0% | 326 | 7 | 2.1% | 30.5 |
| agreement, then confidence | 0.96 | 50.4% | 249 | 7 | 2.8% | 44.5 |
| agreement, then confidence | 0.97 | 21.7% | 107 | 3 | 2.8% | 70.2 |
| agreement, then confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |

### Review load to reach 98% pages in an exact document, the model's own photo labels

Simulated review: the owner checks the least-trusted boundaries in one order across all three collections (a single threshold) and each checked boundary is corrected to the truth, together with the photo/document status of its two pages. Counted in boundaries reviewed per 100 pages.

| signal | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| confidence (no review) | 0 | 0.0 | 88.8% | 82.7% | 96.5% | 89.5% |
| confidence | 6 | 1.1 | 92.3% | 91.8% | 96.5% | 89.5% |
| confidence | 147 | 26.7 | 95.9% | 96.9% | 100.0% | 91.7% |
| confidence | 469 | 85.1 | 98.1% | 100.0% | 100.0% | 94.5% |
| confidence (98% in every collection) | 548 | 99.5 | 100.0% | 100.0% | 100.0% | 100.0% |
| agreement, then confidence (no review) | 0 | 0.0 | 88.8% | 82.7% | 96.5% | 89.5% |
| agreement, then confidence | 6 | 1.1 | 92.3% | 91.8% | 96.5% | 89.5% |
| agreement, then confidence | 147 | 26.7 | 95.9% | 96.9% | 100.0% | 91.7% |
| agreement, then confidence | 469 | 85.1 | 98.1% | 100.0% | 100.0% | 94.5% |
| agreement, then confidence (98% in every collection) | 548 | 99.5 | 100.0% | 100.0% | 100.0% | 100.0% |

## Sensitivity: the suspected label errors corrected

The truth-check (02-truth-check.md) suspects Dean 13 and 15 ("-2-" pages labelled New) and a one-row shift at Herrnstein 19-25. The owner has NOT ruled on them; this applies them as suggested (`SUSPECTED` in method_window.py) to show how much of the result they carry. Own photo labels.

| truth | pooled | Dean | Deaver | Herrnstein | doc-gap errors | of them at confidence >= 0.95 | boundaries reviewed to 98% pooled | per 100 pages |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| as labelled | 88.8% | 82.7% | 96.5% | 89.5% | 17 | 7 | 469 | 85.1 |
| suspected errors corrected | 90.7% | 84.7% | 96.5% | 92.8% | 11 | 1 | 147 | 26.7 |

## Calls

Windows: 187. Calls made: 187 (0 parse failures, 0 errors, 0 usage-limit stops). Mean wall time per call 13 s. The notional list price the CLI reports, which the subscription does not charge: $26.72.

