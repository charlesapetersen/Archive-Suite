# W36.seg-ensemble — the finalists on the test collections (scored once)

Run 2026-10-11 on Stanton and RG 165 (363 pages), never used to choose or tune anything: the finalists and the rule were frozen on the development set (ensemble-dev.md, ensemble-finalists.json) before these collections' calls were made, and each finalist's level was fitted on all three development collections. Truth photo labels throughout. The spring 2026 prompts saw all five collections; the voters' prompts here were written after reading development pages and the owner's notes, not test pages.

| voters | level (fitted on dev) | collection | pages | flagged | per 100 pages | errors left | pages in exact doc, no review | after review | docs exact after review |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| C | <= 0.850 | Stanton | 250 | 32 | 12.8 | 2 | 86.8% | 97.1% | 96.4% |
| C | <= 0.850 | RG165 | 113 | 5 | 4.4 | 1 | 87.4% | 97.7% | 93.9% |
| C | <= 0.850 | pooled | 363 | 37 | 10.2 | 3 | 87.0% | 97.3% | 95.9% |
| CW | <= 0.850 | Stanton | 250 | 33 | 13.2 | 2 | 89.3% | 97.1% | 96.4% |
| CW | <= 0.850 | RG165 | 113 | 6 | 5.3 | 1 | 87.4% | 97.7% | 93.9% |
| CW | <= 0.850 | pooled | 363 | 39 | 10.7 | 3 | 88.8% | 97.3% | 95.9% |

## Each voter alone on the test set (no review)

| voter | collection | pages in exact doc | false splits | false merges |
|---|---|---:|---:|---:|
| window-claude | Stanton | 86.8% | 7 | 4 |
| window-claude | RG165 | 87.4% | 1 | 2 |
| whole-gemini | Stanton | 83.1% | 5 | 4 |
| whole-gemini | RG165 | 87.4% | 1 | 2 |

Against the development set (ensemble-dev.md): a drop here is the honest size of what choosing the voter set and levels on the development set bought.

