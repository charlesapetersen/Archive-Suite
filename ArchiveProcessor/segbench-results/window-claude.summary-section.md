
## W36.seg-window — Claude over overlapping page windows (development set)

Claude Sonnet 5.5 via `claude -p`, 7-page windows, stride 3, every gap judged twice. Prompt written after reading dev pages, not tuned on its errors. Detail and the risk–coverage and review-load tables: window-claude-report.md.

| variant | collection | pages in exact doc | docs exact | false splits | false merges | boundary F1 |
|---|---|---:|---:|---:|---:|---:|
| window-claude | Dean | 85.2% | 91.7% | 2 | 4 | 0.974 |
| window-claude | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude | Herrnstein | 90.1% | 94.4% | 3 | 2 | 0.974 |
| window-claude | pooled | 90.0% | 94.6% | 6 | 6 | 0.979 |
| window-claude-truth-photos | Dean | 85.2% | 91.7% | 2 | 4 | 0.974 |
| window-claude-truth-photos | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude-truth-photos | Herrnstein | 90.6% | 95.4% | 3 | 2 | 0.974 |
| window-claude-truth-photos | pooled | 90.2% | 94.9% | 6 | 6 | 0.979 |
| spring-v1 (for comparison) | Dean | 87.2% | 90.9% | 6 | 4 | 0.957 |
| spring-v1 (for comparison) | Deaver | 84.4% | 93.1% | 7 | 0 | 0.959 |
| spring-v1 (for comparison) | Herrnstein | 86.2% | 91.7% | 8 | 2 | 0.948 |
| spring-v1 (for comparison) | pooled | 86.1% | 91.8% | 21 | 6 | 0.955 |

Against spring-v1 (the shipped per-page prompt, 86.1% pooled; tuned on all five collections), the window method scores 90.0% pooled, +3.9 points, with its own photo labels. Review load to 98% pages in an exact document, pooled, by a single confidence threshold: 388 boundaries (70 per 100 pages) with its own photo labels, 387 (70 per 100) with the truth's. Two-window agreement adds nothing: the windows disagreed on 4 of 494 document gaps, and those already had the lowest confidence. Most of the high-confidence errors sit at the truth-check's suspected label errors; with those corrected as suggested (not yet the owner's ruling) the figures change a good deal, see the sensitivity section of window-claude-report.md.
