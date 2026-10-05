# spring-v2 on dev

Run 2026-10-05. Method: spring 2026 Gemini improved_v2 prompt, saved March outputs.
Measured on: Dean, Deaver, Herrnstein. Tuned on: the spring prompts were written while looking at errors on all five collections (Dean, Deaver, Herrnstein, Stanton, RG 165), so these development numbers are NOT held out.

The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 75.0% | 77.9% | 4 | 14 | 0.920 | 0.095 | 0.095 | 0.0% | 9.4 | 83.3% |
| Deaver | 149 | 87 | 75.2% | 85.1% | 11 | 2 | 0.925 | 0.108 | 0.108 | 20.0% | 10.7 | 62.5% |
| Herrnstein | 200 | 106 | 91.7% | 97.2% | 1 | 1 | 0.989 | 0.020 | 0.020 | 85.7% | 3.0 | 89.5% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 80.9% | 86.3% | 16 | 17 | 0.943 | 0.071 | 0.071 | 54.2% | 7.4 | 81.8% |

Failed pages (no label saved: the call failed or the reply had no tag): 23 (Dean 4, Deaver 16, Herrnstein 3). Each is scored as New, which is what the app does with a missing classification, and its errors count against the run.
All three spring runs sent the previous page's image and the end of its text with each page; there is no saved run without the previous image.

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
