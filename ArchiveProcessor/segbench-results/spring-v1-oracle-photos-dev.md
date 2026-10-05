# spring-v1-oracle-photos on dev

Run 2026-10-05. Method: spring improved_v1 saved outputs with truth photo pages forced to their Box/Folder labels (isolates boundary finding).
Measured on: Dean, Deaver, Herrnstein. Tuned on: the spring prompts were written while looking at errors on all five collections (Dean, Deaver, Herrnstein, Stanton, RG 165), so these development numbers are NOT held out.
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 85.7% | 88.5% | 7 | 6 | 0.945 | 0.065 | 0.065 | 20.0% | 6.4 | 100.0% |
| Deaver | 149 | 87 | 84.4% | 93.1% | 7 | 0 | 0.959 | 0.047 | 0.047 | 40.0% | 4.7 | 100.0% |
| Herrnstein | 200 | 106 | 86.7% | 93.4% | 10 | 2 | 0.938 | 0.060 | 0.060 | 64.3% | 6.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 85.7% | 91.4% | 24 | 8 | 0.946 | 0.058 | 0.058 | 50.0% | 5.8 | 100.0% |

Failed pages (no label saved: the call failed or the reply had no tag): 8 (Dean 3, Deaver 4, Herrnstein 1). Each is scored as New, which is what the app does with a missing classification, and its errors count against the run.
All three spring runs sent the previous page's image and the end of its text with each page; there is no saved run without the previous image.

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
