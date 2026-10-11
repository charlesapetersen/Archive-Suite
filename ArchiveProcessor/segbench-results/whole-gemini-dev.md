# whole-gemini on dev

Run 2026-10-11. Method: Gemini gemini-3.8-flash (API, thinkingLevel low, temperature 0), the whole folder in one call, folders taken from the truth's label photos; images at 1600 px plus Apple Vision text, prompt wh1 with the owner's domain cues; every gap judged once; photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing fitted. The prompt is method_gemini's g1 adapted to a folder of document pages, written once and checked on one probe folder for format only; not revised against page-level errors.
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 94.4% | 93.4% | 0 | 4 | 0.982 | 0.020 | 0.020 | 40.0% | 2.0 | 100.0% |
| Deaver | 149 | 89 | 93.6% | 96.6% | 1 | 1 | 0.988 | 0.014 | 0.014 | 60.0% | 1.3 | 100.0% |
| Herrnstein | 200 | 108 | 91.2% | 95.4% | 6 | 2 | 0.958 | 0.040 | 0.040 | 78.6% | 4.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 318 | 93.1% | 95.0% | 7 | 7 | 0.976 | 0.026 | 0.026 | 66.7% | 2.5 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
