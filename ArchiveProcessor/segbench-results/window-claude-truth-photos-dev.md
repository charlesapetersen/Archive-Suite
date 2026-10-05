# window-claude-truth-photos on dev

Run 2026-10-05. Method: Claude Sonnet 5.5 (claude -p, subscription) over 7-page windows, stride 3, images at 1600 px plus Apple Vision text; every gap judged in two windows, P(new) averaged; photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing fitted. The prompt was written once from the plan and the draft document rules, after earlier bench items had read development pages, and checked on one probe window for format only; it was not revised against page-level errors.
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 85.2% | 91.7% | 2 | 4 | 0.974 | 0.030 | 0.030 | 40.0% | 3.0 | 100.0% |
| Deaver | 149 | 87 | 96.5% | 98.9% | 1 | 0 | 0.994 | 0.007 | 0.007 | 80.0% | 0.7 | 100.0% |
| Herrnstein | 200 | 108 | 90.6% | 95.4% | 3 | 2 | 0.974 | 0.025 | 0.025 | 78.6% | 2.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 316 | 90.2% | 94.9% | 6 | 6 | 0.979 | 0.022 | 0.022 | 70.8% | 2.2 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
