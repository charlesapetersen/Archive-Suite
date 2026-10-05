# W36.seg-window — Claude over overlapping page windows (development set)

Run 2026-10-05 on Dean, Deaver and Herrnstein (551 pages) only; the test collections were not touched. Model claude-sonnet-5-5 through `claude -p` on the owner's subscription. Windows of 7 pages, stride 3, every gap judged in two windows (see method_window.py for why 7 and not 6). The prompt was written once, after earlier bench items had read development pages, and was not revised against page-level errors; nothing was fitted. So these are development numbers, not held-out ones in the strict sense.

## Two-window agreement

| collection | document gaps | judged twice+ | disagreements | error rate when agreed | error rate when disagreed |
|---|---:|---:|---:|---:|---:|
| Dean | 191 | 191 | 3 | 2.7% (5/188) | 33.3% (1/3) |
| Deaver | 136 | 136 | 1 | 0.7% (1/135) | 0.0% (0/1) |
| Herrnstein | 167 | 167 | 0 | 3.0% (5/167) | — (0/0) |
| pooled | 494 | 494 | 4 | 2.2% (11/490) | 25.0% (1/4) |

## Risk–coverage, photo labels from the truth

Document gaps (both pages are document pages in the truth), pooled over the three collections, accepted when the combined confidence is at or above a threshold (with agreement: only gaps both windows agreed on, at or above it). Thresholds rather than coverage fractions, because the confidences are coarse and a fraction would split ties arbitrarily. Error = accepted gaps whose boundary is wrong.

| signal | threshold | coverage | accepted | errors among accepted | error rate | gaps left to review per 100 pages |
|---|---:|---:|---:|---:|---:|---:|
| confidence | 0.00 | 100.0% | 494 | 12 | 2.4% | 0.0 |
| confidence | 0.80 | 96.8% | 478 | 8 | 1.7% | 2.9 |
| confidence | 0.90 | 90.7% | 448 | 4 | 0.9% | 8.3 |
| confidence | 0.93 | 82.0% | 405 | 4 | 1.0% | 16.2 |
| confidence | 0.95 | 66.0% | 326 | 3 | 0.9% | 30.5 |
| confidence | 0.96 | 50.4% | 249 | 3 | 1.2% | 44.5 |
| confidence | 0.97 | 21.7% | 107 | 1 | 0.9% | 70.2 |
| confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |
| agreement, then confidence | 0.00 | 99.2% | 490 | 11 | 2.2% | 0.7 |
| agreement, then confidence | 0.80 | 96.8% | 478 | 8 | 1.7% | 2.9 |
| agreement, then confidence | 0.90 | 90.7% | 448 | 4 | 0.9% | 8.3 |
| agreement, then confidence | 0.93 | 82.0% | 405 | 4 | 1.0% | 16.2 |
| agreement, then confidence | 0.95 | 66.0% | 326 | 3 | 0.9% | 30.5 |
| agreement, then confidence | 0.96 | 50.4% | 249 | 3 | 1.2% | 44.5 |
| agreement, then confidence | 0.97 | 21.7% | 107 | 1 | 0.9% | 70.2 |
| agreement, then confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |

### Review load to reach 98% pages in an exact document, photo labels from the truth

Simulated review: the owner checks the least-trusted boundaries in one order across all three collections (a single threshold) and each checked boundary is corrected to the truth. Counted in boundaries reviewed per 100 pages.

| signal | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| confidence (no review) | 0 | 0.0 | 90.2% | 85.2% | 96.5% | 90.6% |
| confidence | 16 | 2.9 | 95.2% | 96.4% | 96.5% | 92.8% |
| confidence | 387 | 70.2 | 98.1% | 100.0% | 100.0% | 94.5% |
| confidence (98% in every collection) | 494 | 89.7 | 100.0% | 100.0% | 100.0% | 100.0% |
| agreement, then confidence (no review) | 0 | 0.0 | 90.2% | 85.2% | 96.5% | 90.6% |
| agreement, then confidence | 16 | 2.9 | 95.2% | 96.4% | 96.5% | 92.8% |
| agreement, then confidence | 387 | 70.2 | 98.1% | 100.0% | 100.0% | 94.5% |
| agreement, then confidence (98% in every collection) | 494 | 89.7 | 100.0% | 100.0% | 100.0% | 100.0% |

## Risk–coverage, the model's own photo labels

Document gaps (both pages are document pages in the truth), pooled over the three collections, accepted when the combined confidence is at or above a threshold (with agreement: only gaps both windows agreed on, at or above it). Thresholds rather than coverage fractions, because the confidences are coarse and a fraction would split ties arbitrarily. Error = accepted gaps whose boundary is wrong.

| signal | threshold | coverage | accepted | errors among accepted | error rate | gaps left to review per 100 pages |
|---|---:|---:|---:|---:|---:|---:|
| confidence | 0.00 | 100.0% | 494 | 12 | 2.4% | 0.0 |
| confidence | 0.80 | 96.8% | 478 | 8 | 1.7% | 2.9 |
| confidence | 0.90 | 90.7% | 448 | 4 | 0.9% | 8.3 |
| confidence | 0.93 | 82.0% | 405 | 4 | 1.0% | 16.2 |
| confidence | 0.95 | 66.0% | 326 | 3 | 0.9% | 30.5 |
| confidence | 0.96 | 50.4% | 249 | 3 | 1.2% | 44.5 |
| confidence | 0.97 | 21.7% | 107 | 1 | 0.9% | 70.2 |
| confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |
| agreement, then confidence | 0.00 | 99.2% | 490 | 11 | 2.2% | 0.7 |
| agreement, then confidence | 0.80 | 96.8% | 478 | 8 | 1.7% | 2.9 |
| agreement, then confidence | 0.90 | 90.7% | 448 | 4 | 0.9% | 8.3 |
| agreement, then confidence | 0.93 | 82.0% | 405 | 4 | 1.0% | 16.2 |
| agreement, then confidence | 0.95 | 66.0% | 326 | 3 | 0.9% | 30.5 |
| agreement, then confidence | 0.96 | 50.4% | 249 | 3 | 1.2% | 44.5 |
| agreement, then confidence | 0.97 | 21.7% | 107 | 1 | 0.9% | 70.2 |
| agreement, then confidence | 0.98 | 1.0% | 5 | 1 | 20.0% | 88.7 |

### Review load to reach 98% pages in an exact document, the model's own photo labels

Simulated review: the owner checks the least-trusted boundaries in one order across all three collections (a single threshold) and each checked boundary is corrected to the truth, together with the photo/document status of its two pages. Counted in boundaries reviewed per 100 pages.

| signal | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| confidence (no review) | 0 | 0.0 | 90.0% | 85.2% | 96.5% | 90.1% |
| confidence | 3 | 0.5 | 90.3% | 86.2% | 96.5% | 90.1% |
| confidence | 23 | 4.2 | 95.6% | 98.0% | 96.5% | 92.3% |
| confidence | 388 | 70.4 | 98.1% | 100.0% | 100.0% | 94.5% |
| confidence (98% in every collection) | 548 | 99.5 | 100.0% | 100.0% | 100.0% | 100.0% |
| agreement, then confidence (no review) | 0 | 0.0 | 90.0% | 85.2% | 96.5% | 90.1% |
| agreement, then confidence | 3 | 0.5 | 90.3% | 86.2% | 96.5% | 90.1% |
| agreement, then confidence | 23 | 4.2 | 95.6% | 98.0% | 96.5% | 92.3% |
| agreement, then confidence | 388 | 70.4 | 98.1% | 100.0% | 100.0% | 94.5% |
| agreement, then confidence (98% in every collection) | 548 | 99.5 | 100.0% | 100.0% | 100.0% | 100.0% |

## Sensitivity: the suspected label errors corrected

The truth-check (02-truth-check.md) suspects Dean 13 and 15 ("-2-" pages labelled New) and a one-row shift at Herrnstein 19-25. The owner has NOT ruled on them; this applies them as suggested (`SUSPECTED` in method_window.py) to show how much of the result they carry. Own photo labels.

| truth | pooled | Dean | Deaver | Herrnstein | doc-gap errors | of them at confidence >= 0.95 | boundaries reviewed to 98% pooled | per 100 pages |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| as labelled | 90.0% | 85.2% | 96.5% | 90.1% | 12 | 3 | 388 | 70.4 |
| suspected errors corrected | 90.9% | 85.2% | 96.5% | 92.8% | 10 | 1 | 29 | 5.3 |

## Calls

Windows: 187. Calls made: 187 (0 parse failures, 0 errors, 0 usage-limit stops). Mean wall time per call 13 s. The notional list price the CLI reports, which the subscription does not charge: $26.72.

