# all-new on dev

Run 2026-10-05. Method: every document page starts a new document; photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing (no free parameters).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 43.9% | 71.1% | 75 | 0 | 0.756 | 0.373 | 0.373 | 0.0% | 37.1 | 100.0% |
| Deaver | 149 | 87 | 34.8% | 56.3% | 54 | 0 | 0.752 | 0.365 | 0.365 | 0.0% | 36.2 | 100.0% |
| Herrnstein | 200 | 108 | 37.0% | 62.0% | 73 | 0 | 0.720 | 0.367 | 0.367 | 28.6% | 36.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 316 | 39.0% | 63.9% | 202 | 0 | 0.743 | 0.369 | 0.369 | 16.7% | 36.7 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
