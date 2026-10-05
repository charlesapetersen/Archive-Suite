# spring-v1 on dev

Run 2026-10-05. Method: spring 2026 Gemini improved_v1 prompt (the one the app ships), saved March outputs.
Measured on: Dean, Deaver, Herrnstein. Tuned on: the spring prompts were written while looking at errors on all five collections (Dean, Deaver, Herrnstein, Stanton, RG 165), so these development numbers are NOT held out.

The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 84.7% | 87.7% | 7 | 6 | 0.945 | 0.070 | 0.070 | 20.0% | 7.4 | 83.3% |
| Deaver | 149 | 87 | 84.4% | 93.1% | 7 | 0 | 0.959 | 0.047 | 0.047 | 40.0% | 4.7 | 100.0% |
| Herrnstein | 200 | 106 | 85.6% | 92.5% | 10 | 2 | 0.938 | 0.075 | 0.075 | 57.1% | 11.0 | 68.4% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 84.9% | 90.8% | 24 | 8 | 0.946 | 0.066 | 0.066 | 45.8% | 8.0 | 78.8% |

Failed pages (no label saved: the call failed or the reply had no tag): 8 (Dean 3, Deaver 4, Herrnstein 1). Each is scored as New, which is what the app does with a missing classification, and its errors count against the run.
All three spring runs sent the previous page's image and the end of its text with each page; there is no saved run without the previous image.

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
