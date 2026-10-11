# features-lr on dev

Run 2026-10-11. Method: logistic regression on text, image and capture-time-gap features of each boundary, leave-one-collection-out over the development set (fitted on the other two); photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 74.0% | 81.8% | 6 | 10 | 0.930 | 0.080 | 0.080 | 20.0% | 7.9 | 100.0% |
| Deaver | 149 | 89 | 17.0% | 16.9% | 1 | 51 | 0.559 | 0.351 | 0.351 | 0.0% | 34.9 | 100.0% |
| Herrnstein | 200 | 108 | 91.7% | 95.4% | 4 | 1 | 0.974 | 0.025 | 0.025 | 78.6% | 2.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 318 | 64.7% | 68.2% | 11 | 62 | 0.864 | 0.133 | 0.133 | 50.0% | 13.2 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
