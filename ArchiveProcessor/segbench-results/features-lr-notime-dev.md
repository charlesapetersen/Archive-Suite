# features-lr-notime on dev

Run 2026-10-05. Method: logistic regression on text, image features of each boundary, leave-one-collection-out over the development set (fitted on the other two); photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 72.4% | 77.9% | 23 | 8 | 0.876 | 0.154 | 0.154 | 20.0% | 15.3 | 100.0% |
| Deaver | 149 | 87 | 0.0% | 0.0% | 3 | 79 | 0.068 | 0.554 | 0.554 | 0.0% | 55.0 | 100.0% |
| Herrnstein | 200 | 106 | 71.8% | 84.9% | 10 | 5 | 0.921 | 0.075 | 0.075 | 57.1% | 7.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 52.5% | 58.7% | 36 | 92 | 0.757 | 0.234 | 0.234 | 37.5% | 23.2 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
