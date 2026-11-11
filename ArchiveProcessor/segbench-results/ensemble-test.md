# W36.seg-ensemble — the finalists on the test collections (scored once)

Run 2026-10-11 on Stanton and RG 165 (363 pages), never used to choose or tune anything: the finalists and the rule were frozen on the development set (ensemble-dev.md, ensemble-finalists.json) before these collections' calls were made, and each finalist's level was fitted on all three development collections. Truth photo labels throughout. The spring 2026 prompts saw all five collections; the voters' prompts here were written after reading development pages and the owner's notes, not test pages.
Rescored 2026-11-11 (W46.stale-figures) from the cached calls, no new call: the Stanton truth now carries the owner's 2026-10-31 rulings at 101|102 and 102|103 (W46.seg-truth-rescore, seg-truth-rescore.md), which this page had missed. Levels, finalists and calls are untouched; only Stanton's no-review figures, its documents exact after review and its false merges moved (each finalist about 2 points, pooled 1.5).


| voters | level (fitted on dev) | collection | pages | flagged | per 100 pages | errors left | pages in exact doc, no review | after review | docs exact after review |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| C | <= 0.850 | Stanton | 250 | 32 | 12.8 | 2 | 84.8% | 97.1% | 96.5% |
| C | <= 0.850 | RG165 | 113 | 5 | 4.4 | 1 | 87.4% | 97.7% | 93.9% |
| C | <= 0.850 | pooled | 363 | 37 | 10.2 | 3 | 85.5% | 97.3% | 95.9% |
| CW | <= 0.850 | Stanton | 250 | 33 | 13.2 | 2 | 87.2% | 97.1% | 96.5% |
| CW | <= 0.850 | RG165 | 113 | 6 | 5.3 | 1 | 87.4% | 97.7% | 93.9% |
| CW | <= 0.850 | pooled | 363 | 39 | 10.7 | 3 | 87.3% | 97.3% | 95.9% |

## Each voter alone on the test set (no review)

| voter | collection | pages in exact doc | false splits | false merges |
|---|---|---:|---:|---:|
| window-claude | Stanton | 84.8% | 7 | 6 |
| window-claude | RG165 | 87.4% | 1 | 2 |
| whole-gemini | Stanton | 81.1% | 5 | 6 |
| whole-gemini | RG165 | 87.4% | 1 | 2 |

Against the development set (ensemble-dev.md): a drop here is the honest size of what choosing the voter set and levels on the development set bought.

## Measurement card

Added 2026-11-11 (W46.p13-wording, measurement review pass 13, P13-8) after the W46.stale-figures rescore.

- **Truth.** The owner's ruled test boxes, Stanton (with the owner's 2026-10-31 segmentation-sheet rulings at 101|102 and 102|103, W46.seg-truth-rescore) and RG 165, with the truth's photo labels; neither carries an unsure gap. No scored voter drafted a truth.
- **Selection.** The two test collections whole, set aside before the finalists, the rule and the levels were frozen on the development boxes (Dean, Deaver, Herrnstein; ensemble-dev.md, ensemble-finalists.json). No page or voter was chosen by a test result; no ABBYY text was used. The spring 2026 prompts saw all five collections (above).
- **Comparison.** Every finalist and voter on the same 363 pages from the same cached calls, the same scorer and the same truth; the 2026-11-11 rescore changed only the truth, nothing refit or re-chosen.
- **Noise.** n is 250 and 113 pages, one box each, scored once at temperature 0; no interval is computed here. The rerun floor is 1.4-3.2 points of pages exact a box (seg-boxes-score.md §Noise), so a gap between rows under it, C 85.5% against CW 87.3% included, is a tie. Gaps in one box are not independent.
- **Scope.** Two boxes, two finalists and their voters' prompts (window-claude, and whole-gemini: Gemini 3.8 Flash, one call per folder). It does not settle the app's routes, which options.md and seg-boxes-score.md measure, or boxes outside these collections.
