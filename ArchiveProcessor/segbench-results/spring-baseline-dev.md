# spring-baseline on dev

Run 2026-10-05. Method: spring 2026 Gemini baseline prompt, saved March outputs.
Measured on: Dean, Deaver, Herrnstein. Tuned on: the spring prompts were written while looking at errors on all five collections (Dean, Deaver, Herrnstein, Stanton, RG 165), so these development numbers are NOT held out.

The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 63.3% | 68.9% | 3 | 20 | 0.894 | 0.119 | 0.119 | 0.0% | 11.9 | 83.3% |
| Deaver | 149 | 87 | 80.9% | 85.1% | 2 | 4 | 0.963 | 0.068 | 0.068 | 20.0% | 6.7 | 62.5% |
| Herrnstein | 200 | 106 | 77.9% | 82.1% | 3 | 9 | 0.933 | 0.075 | 0.075 | 50.0% | 8.0 | 84.2% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 73.2% | 77.8% | 8 | 33 | 0.926 | 0.089 | 0.089 | 33.3% | 9.1 | 78.8% |

Failed pages (no label saved: the call failed or the reply had no tag): 5 (Dean 3, Deaver 2, Herrnstein 0). Each is scored as New, which is what the app does with a missing classification, and its errors count against the run.
All three spring runs sent the previous page's image and the end of its text with each page; there is no saved run without the previous image.

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
