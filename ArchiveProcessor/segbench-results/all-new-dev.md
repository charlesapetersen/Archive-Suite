# all-new on dev

Run 2026-10-05. Method: every document page starts a new document; photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing (no free parameters).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 45.4% | 73.0% | 74 | 0 | 0.760 | 0.368 | 0.368 | 0.0% | 36.6 | 100.0% |
| Deaver | 149 | 87 | 34.8% | 56.3% | 54 | 0 | 0.752 | 0.365 | 0.365 | 0.0% | 36.2 | 100.0% |
| Herrnstein | 200 | 106 | 35.9% | 61.3% | 75 | 0 | 0.710 | 0.377 | 0.377 | 28.6% | 37.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 39.2% | 64.4% | 203 | 0 | 0.741 | 0.370 | 0.370 | 16.7% | 36.8 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
