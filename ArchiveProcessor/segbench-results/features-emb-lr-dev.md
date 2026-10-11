# features-emb-lr on dev

Run 2026-10-11. Method: logistic regression on text, image, on-device embedding and capture-time-gap features of each boundary, leave-one-collection-out over the development set (fitted on the other two); photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 69.4% | 77.7% | 4 | 13 | 0.924 | 0.085 | 0.085 | 20.0% | 8.4 | 100.0% |
| Deaver | 149 | 89 | 23.4% | 25.8% | 11 | 39 | 0.643 | 0.338 | 0.338 | 0.0% | 33.6 | 100.0% |
| Herrnstein | 200 | 108 | 89.0% | 91.7% | 3 | 4 | 0.963 | 0.035 | 0.035 | 71.4% | 3.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 318 | 63.7% | 67.9% | 18 | 56 | 0.865 | 0.135 | 0.135 | 45.8% | 13.4 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
