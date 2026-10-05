
## W36.seg-window — Claude over overlapping page windows (development set)

Claude Sonnet 5.5 via `claude -p`, 7-page windows, stride 3, every gap judged twice. Prompt written after reading dev pages, not tuned on its errors. Detail and the risk–coverage and review-load tables: window-claude-report.md.

| variant | collection | pages in exact doc | docs exact | false splits | false merges | boundary F1 |
|---|---|---:|---:|---:|---:|---:|
| window-claude | Dean | 85.2% | 91.7% | 2 | 4 | 0.974 |
| window-claude | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude | Herrnstein | 91.2% | 95.4% | 2 | 2 | 0.979 |
| window-claude | pooled | 90.3% | 94.9% | 5 | 6 | 0.981 |
| window-claude-truth-photos | Dean | 85.2% | 91.7% | 2 | 4 | 0.974 |
| window-claude-truth-photos | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude-truth-photos | Herrnstein | 91.2% | 95.4% | 2 | 2 | 0.979 |
| window-claude-truth-photos | pooled | 90.3% | 94.9% | 5 | 6 | 0.981 |
| spring-v1 (for comparison) | Dean | 87.2% | 90.9% | 6 | 4 | 0.957 |
| spring-v1 (for comparison) | Deaver | 84.4% | 93.1% | 7 | 0 | 0.959 |
| spring-v1 (for comparison) | Herrnstein | 87.3% | 92.6% | 7 | 2 | 0.953 |
| spring-v1 (for comparison) | pooled | 86.5% | 92.1% | 20 | 6 | 0.957 |

Against spring-v1 (the shipped per-page prompt, 86.5% pooled; tuned on all five collections), the window method scores 90.3% pooled, +3.9 points, with its own photo labels. Review load to 98% pages in an exact document, pooled, by a single confidence threshold: 34 boundaries (6 per 100 pages) with its own photo labels, 34 (6 per 100) with the truth's. Two-window agreement adds nothing: the windows disagreed on 4 of 494 document gaps, and those already had the lowest confidence. Most of the high-confidence errors sit at the truth-check's suspected label errors; with those corrected as suggested (not yet the owner's ruling) the figures change a good deal, see the sensitivity section of window-claude-report.md.
