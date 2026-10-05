# features-lr on dev

Run 2026-10-05. Method: logistic regression on text, image and capture-time-gap features of each boundary, leave-one-collection-out over the development set (fitted on the other two); photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 73.0% | 80.3% | 6 | 10 | 0.930 | 0.080 | 0.080 | 20.0% | 7.9 | 100.0% |
| Deaver | 149 | 87 | 9.9% | 9.2% | 2 | 67 | 0.303 | 0.466 | 0.466 | 0.0% | 46.3 | 100.0% |
| Herrnstein | 200 | 106 | 82.9% | 88.7% | 10 | 2 | 0.938 | 0.060 | 0.060 | 42.9% | 6.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 59.3% | 63.5% | 18 | 79 | 0.814 | 0.177 | 0.177 | 29.2% | 17.6 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
