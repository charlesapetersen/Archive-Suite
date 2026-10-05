# features-lr on dev

Run 2026-10-05. Method: logistic regression on text, image and capture-time-gap features of each boundary, leave-one-collection-out over the development set (fitted on the other two); photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 75.0% | 83.5% | 5 | 8 | 0.943 | 0.065 | 0.065 | 20.0% | 6.4 | 100.0% |
| Deaver | 149 | 87 | 13.5% | 13.8% | 3 | 53 | 0.509 | 0.378 | 0.378 | 0.0% | 37.6 | 100.0% |
| Herrnstein | 200 | 108 | 91.2% | 95.4% | 5 | 1 | 0.969 | 0.030 | 0.030 | 78.6% | 3.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 316 | 63.9% | 68.4% | 13 | 62 | 0.860 | 0.137 | 0.137 | 50.0% | 13.6 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
