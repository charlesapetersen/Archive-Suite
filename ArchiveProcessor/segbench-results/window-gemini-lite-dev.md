# window-gemini-lite on dev

Run 2026-10-05. Method: Gemini gemini-3.1-flash-lite (API, thinkingLevel minimal, temperature 0) over 7-page windows, stride 3, images at 1600 px plus Apple Vision text, prompt g1 with the owner's domain cues; every gap judged in two windows, P(new) averaged; the model's own photo labels.
Measured on: Dean, Deaver, Herrnstein. Tuned on: nothing fitted. The prompt was written once from the plan, the owner's domain cues and the approved document rules, after earlier bench items had read development pages, and checked on one probe window for format only; it was not revised against page-level errors.

The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 121 | 86.7% | 94.2% | 3 | 2 | 0.979 | 0.025 | 0.025 | 40.0% | 2.5 | 100.0% |
| Deaver | 149 | 87 | 72.3% | 82.8% | 17 | 0 | 0.906 | 0.115 | 0.115 | 20.0% | 11.4 | 100.0% |
| Herrnstein | 200 | 108 | 91.7% | 96.3% | 7 | 1 | 0.959 | 0.040 | 0.040 | 78.6% | 4.0 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 316 | 84.6% | 91.8% | 27 | 3 | 0.951 | 0.055 | 0.055 | 58.3% | 5.4 | 100.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
