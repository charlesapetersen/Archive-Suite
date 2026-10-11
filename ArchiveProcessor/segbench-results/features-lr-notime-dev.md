# features-lr-notime on dev

Run 2026-10-11. Method: logistic regression on text, image features of each boundary, leave-one-collection-out over the development set (fitted on the other two); photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 77.6% | 86.0% | 23 | 3 | 0.897 | 0.129 | 0.129 | 0.0% | 12.9 | 100.0% |
| Deaver | 149 | 89 | 0.0% | 0.0% | 2 | 81 | 0.067 | 0.561 | 0.561 | 0.0% | 55.7 | 100.0% |
| Herrnstein | 200 | 108 | 76.2% | 88.9% | 8 | 4 | 0.938 | 0.060 | 0.060 | 64.3% | 6.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 318 | 56.0% | 62.9% | 33 | 88 | 0.773 | 0.221 | 0.221 | 37.5% | 22.0 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
