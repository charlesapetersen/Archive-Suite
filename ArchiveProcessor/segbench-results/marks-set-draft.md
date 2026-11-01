# Marks set: the two drafts of the 150 pages

W46.fix-marks-set-draft. `marks_set.py report` over the 150 pages of `marks-set-selection.json` (40 in the owner core). Draft figures, not truth; the JSON beside this file has every count.

| | gemini3.7-flash-gw | qwen3-vl-8b-mlx4 |
|---|---|---|
| Pages read | 0 | 150 |
| Parsed | 0 | 146 |
| Hit the output cap | 0 | 4 |
| Marks | 0 | 189 |
| Pages with a mark | 0 | 98 |
| Pages with handwriting | 0 | 96 |
| Median seconds a page | None | 12.16 |
| annotation | 0 | 119 |
| marginal_note | 0 | 17 |
| stamp | 0 | 2 |
| signature_initials | 0 | 15 |
| redaction | 0 | 0 |
| other | 0 | 36 |
| Marks dropped (bad class or box) | 0 | 4 |

## Agreement between the drafts

No page has both drafts yet.

## Measurement card

- **Truth.** None. Both columns are drafts; the owner core (W46.marks-core-owner-ok) is the first truth.
- **Selection.** `marks-set-selection.json`: phase A independent of every route, phase B by the Qwen3.6-27B pre-flag's band (neither drafter).
- **Comparison.** One instruction, each route in its own box form; Gemini at 2,400 px, the 8B at 1,400 px.
- **Noise.** One pass each at temperature 0; no rerun floor.
- **Scope.** Agreement is not accuracy: two drafts can agree and both be wrong. Neither drafter may be ranked on these pages (MRK-1). Counts are of the drawn, enriched set, not the corpus. The phase and core fractions are not validated final owner-core inclusion probabilities (P3-3, W46.marks-sampling-support): report core results descriptively, A-core and B-core apart, as an enriched set; no population recall, mixed share or corpus-weighted routing benefit is weighted from them. The independent mixed share and interval are mixed-def-score's; within-core paired route comparisons stand.
