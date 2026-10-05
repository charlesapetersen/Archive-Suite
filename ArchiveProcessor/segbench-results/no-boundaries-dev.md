# no-boundaries on dev

Run 2026-10-05. Method: no document boundaries: each folder's pages are one document; photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing (no free parameters).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 0.0% | 0.0% | 0 | 117 | — | 0.582 | 0.582 | 0.0% | 57.9 | 100.0% |
| Deaver | 149 | 87 | 0.0% | 0.0% | 0 | 82 | — | 0.554 | 0.554 | 0.0% | 55.0 | 100.0% |
| Herrnstein | 200 | 106 | 1.7% | 2.8% | 0 | 92 | — | 0.462 | 0.462 | 21.4% | 46.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 0.6% | 1.0% | 0 | 291 | — | 0.531 | 0.531 | 12.5% | 52.8 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
