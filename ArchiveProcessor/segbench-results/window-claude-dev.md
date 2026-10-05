# window-claude on dev

Run 2026-10-05. Method: Claude Sonnet 5.5 (claude -p, subscription) over 7-page windows, stride 3, images at 1600 px plus Apple Vision text; every gap judged in two windows, P(new) averaged; the model's own photo labels.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing fitted. The prompt was written once from the plan and the draft document rules, after earlier bench items had read development pages, and checked on one probe window for format only; it was not revised against page-level errors.

The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 85.2% | 91.7% | 2 | 4 | 0.974 | 0.030 | 0.030 | 40.0% | 3.0 | 100.0% |
| Deaver | 149 | 87 | 96.5% | 98.9% | 1 | 0 | 0.994 | 0.007 | 0.007 | 80.0% | 0.7 | 100.0% |
| Herrnstein | 200 | 108 | 91.2% | 95.4% | 2 | 2 | 0.979 | 0.020 | 0.020 | 78.6% | 2.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 316 | 90.3% | 94.9% | 5 | 6 | 0.981 | 0.020 | 0.020 | 70.8% | 2.0 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
