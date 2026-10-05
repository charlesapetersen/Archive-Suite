
## W36.seg-window — Claude over overlapping page windows (development set)

Claude Sonnet 5.5 via `claude -p`, 7-page windows, stride 3, every gap judged twice. Prompt written after reading dev pages, not tuned on its errors. Detail and the risk–coverage and review-load tables: window-claude-report.md.

| variant | collection | pages in exact doc | docs exact | false splits | false merges | boundary F1 |
|---|---|---:|---:|---:|---:|---:|
| window-claude | Dean | 82.7% | 88.5% | 3 | 6 | 0.961 |
| window-claude | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude | Herrnstein | 89.5% | 95.3% | 5 | 2 | 0.963 |
| window-claude | pooled | 88.8% | 93.7% | 9 | 8 | 0.971 |
| window-claude-truth-photos | Dean | 82.7% | 88.5% | 3 | 6 | 0.961 |
| window-claude-truth-photos | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude-truth-photos | Herrnstein | 89.5% | 95.3% | 5 | 2 | 0.963 |
| window-claude-truth-photos | pooled | 88.8% | 93.7% | 9 | 8 | 0.971 |
| spring-v1 (for comparison) | Dean | 84.7% | 87.7% | 7 | 6 | 0.945 |
| spring-v1 (for comparison) | Deaver | 84.4% | 93.1% | 7 | 0 | 0.959 |
| spring-v1 (for comparison) | Herrnstein | 85.6% | 92.5% | 10 | 2 | 0.938 |
| spring-v1 (for comparison) | pooled | 84.9% | 90.8% | 24 | 8 | 0.946 |

Against spring-v1 (the shipped per-page prompt, 84.9% pooled; tuned on all five collections), the window method scores 88.8% pooled, +3.9 points, with its own photo labels. Review load to 98% pages in an exact document, pooled, by a single confidence threshold: 469 boundaries (85 per 100 pages) with its own photo labels, 468 (85 per 100) with the truth's. Two-window agreement adds nothing: the windows disagreed on 4 of 494 document gaps, and those already had the lowest confidence. Most of the high-confidence errors sit at the truth-check's suspected label errors; with those corrected as suggested (not yet the owner's ruling) the figures change a good deal, see the sensitivity section of window-claude-report.md.
