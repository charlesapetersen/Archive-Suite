# window-claude-truth-photos on dev

Run 2026-10-05. Method: Claude Sonnet 5.5 (claude -p, subscription) over 7-page windows, stride 3, images at 1600 px plus Apple Vision text; every gap judged in two windows, P(new) averaged; photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing fitted. The prompt was written once from the plan and the draft document rules, after earlier bench items had read development pages, and checked on one probe window for format only; it was not revised against page-level errors.
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 82.7% | 88.5% | 3 | 6 | 0.961 | 0.045 | 0.045 | 40.0% | 4.5 | 100.0% |
| Deaver | 149 | 87 | 96.5% | 98.9% | 1 | 0 | 0.994 | 0.007 | 0.007 | 80.0% | 0.7 | 100.0% |
| Herrnstein | 200 | 106 | 89.5% | 95.3% | 5 | 2 | 0.963 | 0.035 | 0.035 | 78.6% | 3.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 88.8% | 93.7% | 9 | 8 | 0.971 | 0.031 | 0.031 | 70.8% | 3.1 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
