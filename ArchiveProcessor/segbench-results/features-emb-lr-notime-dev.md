# features-emb-lr-notime on dev

Run 2026-10-11. Method: logistic regression on text, image, on-device embedding features of each boundary, leave-one-collection-out over the development set (fitted on the other two); photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 81.1% | 82.6% | 3 | 11 | 0.938 | 0.070 | 0.070 | 20.0% | 6.9 | 100.0% |
| Deaver | 149 | 89 | 17.7% | 20.2% | 14 | 42 | 0.600 | 0.378 | 0.378 | 0.0% | 37.6 | 100.0% |
| Herrnstein | 200 | 108 | 87.8% | 90.7% | 4 | 4 | 0.957 | 0.040 | 0.040 | 64.3% | 4.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 318 | 66.2% | 67.9% | 21 | 57 | 0.859 | 0.142 | 0.142 | 41.7% | 14.2 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
