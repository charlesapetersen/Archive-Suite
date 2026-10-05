# W36.seg-second — Gemini Flash-Lite over overlapping page windows, and voting (development set)

Run 2026-10-05 on Dean, Deaver and Herrnstein (551 pages) only; the test collections were not touched. Model gemini-3.1-flash-lite through the Gemini API, thinkingLevel "minimal", temperature 0, JSON response schema. The same windows as window-claude (7 pages, stride 3, every gap judged in two windows), with a NEW prompt that states the owner's domain cues and the approved document rules. The prompt was written after reading the owner's notes on development pages and was not revised against page-level errors; nothing was fitted. Both the model and the prompt differ from window-claude, so a difference between them cannot be put down to either alone.

## Headline

| method | collection | pages in exact doc | docs exact | false splits | false merges | boundary F1 |
|---|---|---:|---:|---:|---:|---:|
| window-gemini-lite | Dean | 86.7% | 94.2% | 3 | 2 | 0.979 |
| window-gemini-lite | Deaver | 72.3% | 82.8% | 17 | 0 | 0.906 |
| window-gemini-lite | Herrnstein | 91.7% | 96.3% | 7 | 1 | 0.959 |
| window-gemini-lite | pooled | 84.6% | 91.8% | 27 | 3 | 0.951 |
| window-gemini-lite-truth-photos | Dean | 86.7% | 94.2% | 3 | 2 | 0.979 |
| window-gemini-lite-truth-photos | Deaver | 72.3% | 82.8% | 17 | 0 | 0.906 |
| window-gemini-lite-truth-photos | Herrnstein | 91.7% | 96.3% | 7 | 1 | 0.959 |
| window-gemini-lite-truth-photos | pooled | 84.6% | 91.8% | 27 | 3 | 0.951 |
| window-claude | Dean | 85.2% | 91.7% | 2 | 4 | 0.974 |
| window-claude | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude | Herrnstein | 91.2% | 95.4% | 2 | 2 | 0.979 |
| window-claude | pooled | 90.3% | 94.9% | 5 | 6 | 0.981 |
| spring-v1 | Dean | 87.2% | 90.9% | 6 | 4 | 0.957 |
| spring-v1 | Deaver | 84.4% | 93.1% | 7 | 0 | 0.959 |
| spring-v1 | Herrnstein | 87.3% | 92.6% | 7 | 2 | 0.953 |
| spring-v1 | pooled | 86.5% | 92.1% | 20 | 6 | 0.957 |

## Two-window agreement

| collection | document gaps | judged twice+ | disagreements | error rate when agreed | error rate when disagreed |
|---|---:|---:|---:|---:|---:|
| Dean | 191 | 191 | 3 | 2.1% (4/188) | 33.3% (1/3) |
| Deaver | 136 | 136 | 8 | 7.0% (9/128) | 100.0% (8/8) |
| Herrnstein | 167 | 167 | 5 | 4.3% (7/162) | 20.0% (1/5) |
| pooled | 494 | 494 | 16 | 4.2% (20/478) | 62.5% (10/16) |

## Risk–coverage, photo labels from the truth

Document gaps (both pages are document pages in the truth), pooled over the three collections, accepted when the combined confidence is at or above a threshold (with agreement: only gaps both windows agreed on, at or above it). Thresholds rather than coverage fractions, because the confidences are coarse and a fraction would split ties arbitrarily. Error = accepted gaps whose boundary is wrong.

| signal | threshold | coverage | accepted | errors among accepted | error rate | gaps left to review per 100 pages |
|---|---:|---:|---:|---:|---:|---:|
| confidence | 0.00 | 100.0% | 494 | 30 | 6.1% | 0.0 |
| confidence | 0.80 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| confidence | 0.90 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| confidence | 0.93 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| confidence | 0.95 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| confidence | 0.96 | 58.7% | 290 | 3 | 1.0% | 37.0 |
| confidence | 0.97 | 57.7% | 285 | 3 | 1.1% | 37.9 |
| confidence | 0.98 | 27.3% | 135 | 1 | 0.7% | 65.2 |
| agreement, then confidence | 0.00 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| agreement, then confidence | 0.80 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| agreement, then confidence | 0.90 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| agreement, then confidence | 0.93 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| agreement, then confidence | 0.95 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| agreement, then confidence | 0.96 | 58.7% | 290 | 3 | 1.0% | 37.0 |
| agreement, then confidence | 0.97 | 57.7% | 285 | 3 | 1.1% | 37.9 |
| agreement, then confidence | 0.98 | 27.3% | 135 | 1 | 0.7% | 65.2 |

### Review load to reach 98% pages in an exact document, photo labels from the truth

Simulated review: the owner checks the least-trusted boundaries in one order across all three collections (a single threshold) and each checked boundary is corrected to the truth. Counted in boundaries reviewed per 100 pages.

| signal | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| confidence (no review) | 0 | 0.0 | 84.6% | 86.7% | 72.3% | 91.7% |
| confidence | 22 | 4.0 | 92.5% | 96.9% | 85.1% | 93.4% |
| confidence | 204 | 37.0 | 98.3% | 99.0% | 95.0% | 100.0% |
| confidence (98% in every collection) | 359 | 65.2 | 99.6% | 99.0% | 100.0% | 100.0% |
| agreement, then confidence (no review) | 0 | 0.0 | 84.6% | 86.7% | 72.3% | 91.7% |
| agreement, then confidence | 22 | 4.0 | 92.5% | 96.9% | 85.1% | 93.4% |
| agreement, then confidence | 204 | 37.0 | 98.3% | 99.0% | 95.0% | 100.0% |
| agreement, then confidence (98% in every collection) | 359 | 65.2 | 99.6% | 99.0% | 100.0% | 100.0% |

## Risk–coverage, the model's own photo labels

Document gaps (both pages are document pages in the truth), pooled over the three collections, accepted when the combined confidence is at or above a threshold (with agreement: only gaps both windows agreed on, at or above it). Thresholds rather than coverage fractions, because the confidences are coarse and a fraction would split ties arbitrarily. Error = accepted gaps whose boundary is wrong.

| signal | threshold | coverage | accepted | errors among accepted | error rate | gaps left to review per 100 pages |
|---|---:|---:|---:|---:|---:|---:|
| confidence | 0.00 | 100.0% | 494 | 30 | 6.1% | 0.0 |
| confidence | 0.80 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| confidence | 0.90 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| confidence | 0.93 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| confidence | 0.95 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| confidence | 0.96 | 58.7% | 290 | 3 | 1.0% | 37.0 |
| confidence | 0.97 | 57.7% | 285 | 3 | 1.1% | 37.9 |
| confidence | 0.98 | 27.3% | 135 | 1 | 0.7% | 65.2 |
| agreement, then confidence | 0.00 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| agreement, then confidence | 0.80 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| agreement, then confidence | 0.90 | 96.8% | 478 | 20 | 4.2% | 2.9 |
| agreement, then confidence | 0.93 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| agreement, then confidence | 0.95 | 91.3% | 451 | 16 | 3.5% | 7.8 |
| agreement, then confidence | 0.96 | 58.7% | 290 | 3 | 1.0% | 37.0 |
| agreement, then confidence | 0.97 | 57.7% | 285 | 3 | 1.1% | 37.9 |
| agreement, then confidence | 0.98 | 27.3% | 135 | 1 | 0.7% | 65.2 |

### Review load to reach 98% pages in an exact document, the model's own photo labels

Simulated review: the owner checks the least-trusted boundaries in one order across all three collections (a single threshold) and each checked boundary is corrected to the truth, together with the photo/document status of its two pages. Counted in boundaries reviewed per 100 pages.

| signal | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| confidence (no review) | 0 | 0.0 | 84.6% | 86.7% | 72.3% | 91.7% |
| confidence | 22 | 4.0 | 92.5% | 96.9% | 85.1% | 93.4% |
| confidence | 204 | 37.0 | 98.3% | 99.0% | 95.0% | 100.0% |
| confidence (98% in every collection) | 359 | 65.2 | 99.6% | 99.0% | 100.0% | 100.0% |
| agreement, then confidence (no review) | 0 | 0.0 | 84.6% | 86.7% | 72.3% | 91.7% |
| agreement, then confidence | 22 | 4.0 | 92.5% | 96.9% | 85.1% | 93.4% |
| agreement, then confidence | 204 | 37.0 | 98.3% | 99.0% | 95.0% | 100.0% |
| agreement, then confidence (98% in every collection) | 359 | 65.2 | 99.6% | 99.0% | 100.0% | 100.0% |

## Voting with window-claude

window-claude's answers come from its cache (no new Claude call). A boundary both models decide the same way, with the same photo calls on its two pages, is accepted; any other is flagged for review. Before review a disagreement takes the more confident model's call. Review corrects a flagged boundary to the truth, with its two pages' photo status.

### Each model's own photo labels

| collection | gaps | flagged | flagged per 100 pages | document gaps flagged | errors left among agreed document gaps | claude's errors at flagged gaps | gemini's errors at flagged gaps | pages in exact doc, no review | after reviewing the flagged |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 201 | 3 | 1.5 | 3 | 4 | 2 | 1 | 86.7% | 88.8% |
| Deaver | 148 | 16 | 10.7 | 16 | 1 | 0 | 16 | 86.5% | 96.5% |
| Herrnstein | 199 | 6 | 3.0 | 6 | 3 | 1 | 5 | 91.2% | 93.4% |
| pooled | 548 | 25 | 4.5 | 25 | 8 | 3 | 22 | 88.2% | 92.5% |

Review load to 98% pages in an exact document, reviewing every flagged boundary first and then the agreed ones least confident first (the lower of the two models' confidences), whole ties at a time:

| target | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| flagged only | 25 | 4.5 | 92.5% | 88.8% | 96.5% | 93.4% |
| 98% pooled | 49 | 8.9 | 98.1% | 99.0% | 96.5% | 98.3% |
| 98% in every collection | 163 | 29.6 | 99.0% | 99.0% | 100.0% | 98.3% |

### Photo labels from the truth

| collection | gaps | flagged | flagged per 100 pages | document gaps flagged | errors left among agreed document gaps | claude's errors at flagged gaps | gemini's errors at flagged gaps | pages in exact doc, no review | after reviewing the flagged |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 201 | 3 | 1.5 | 3 | 4 | 2 | 1 | 86.7% | 88.8% |
| Deaver | 148 | 16 | 10.7 | 16 | 1 | 0 | 16 | 86.5% | 96.5% |
| Herrnstein | 199 | 6 | 3.0 | 6 | 3 | 1 | 5 | 91.2% | 93.4% |
| pooled | 548 | 25 | 4.5 | 25 | 8 | 3 | 22 | 88.2% | 92.5% |

Review load to 98% pages in an exact document, reviewing every flagged boundary first and then the agreed ones least confident first (the lower of the two models' confidences), whole ties at a time:

| target | boundaries reviewed | per 100 pages | pooled | Dean | Deaver | Herrnstein |
|---|---:|---:|---:|---:|---:|---:|
| flagged only | 25 | 4.5 | 92.5% | 88.8% | 96.5% | 93.4% |
| 98% pooled | 49 | 8.9 | 98.1% | 99.0% | 96.5% | 98.3% |
| 98% in every collection | 163 | 29.6 | 99.0% | 99.0% | 100.0% | 98.3% |

## Calls and cost

Windows: 187. Calls made: 187 (0 parse failures). Tokens: 2,138,532 in, 91,940 out (of them 0 thinking). Mean wall time 6.4 s. Cost at the assumed list price ($0.25 / $1.5 per million tokens in / out; the models endpoint gives no prices): $0.67.

