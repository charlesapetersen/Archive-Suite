# rule-cues-sketch on dev

Run 2026-10-05. Method: page-number and salutation cues on Apple Vision text (sketch; W36.seg-base builds the real one).
Measured on: Dean, Deaver, Herrnstein. Tuned on: still tuning (development set only).
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 61.2% | 80.3% | 42 | 2 | 0.839 | 0.219 | 0.219 | 0.0% | 21.8 | 100.0% |
| Deaver | 149 | 87 | 33.3% | 54.0% | 54 | 1 | 0.747 | 0.372 | 0.372 | 0.0% | 36.9 | 100.0% |
| Herrnstein | 200 | 106 | 66.9% | 85.8% | 41 | 0 | 0.818 | 0.206 | 0.206 | 42.9% | 20.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 55.6% | 74.9% | 137 | 3 | 0.804 | 0.255 | 0.255 | 25.0% | 25.4 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
