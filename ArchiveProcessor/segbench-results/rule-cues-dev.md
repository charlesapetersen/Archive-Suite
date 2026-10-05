# rule-cues on dev

Run 2026-10-05. Method: ordered rule cues (page numbers, openings, date lines, closings, jump lines, blank pages) on Apple Vision text; photo labels from the truth.
Measured on: Dean, Deaver, Herrnstein. Tuned on: leave-one-collection-out on the development set: each collection's row uses rule switches and thresholds fitted on the other two, so every row, and the pooled row, is held out in those. The rule list and its patterns were written after reading development pages, so the rules themselves are not held out.
Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by construction and the document figures isolate boundary finding.
The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five collections, so no collection is fully unseen by the shipped prompt.

| collection | pages | docs | pages in exact doc | docs exact | false splits | false merges | boundary F1 | Pk | WindowDiff | folders perfect | edits/100 pages | photo accuracy |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dean | 202 | 122 | 61.2% | 80.3% | 22 | 5 | 0.892 | 0.134 | 0.134 | 20.0% | 13.4 | 100.0% |
| Deaver | 149 | 87 | 39.0% | 52.9% | 33 | 11 | 0.763 | 0.297 | 0.297 | 20.0% | 29.5 | 100.0% |
| Herrnstein | 200 | 106 | 63.0% | 82.1% | 44 | 1 | 0.802 | 0.226 | 0.226 | 42.9% | 22.5 | 100.0% |
| POOLED Dean+Deaver+Herrnstein | 551 | 315 | 55.8% | 73.3% | 99 | 17 | 0.825 | 0.212 | 0.212 | 33.3% | 21.1 | 100.0% |

Fitted parameters per held-out collection (fitted on the other two):

- Dean (fitted on Deaver + Herrnstein): top 3 lines, end 3 lines, blank < 0 chars, default New; off: none
- Deaver (fitted on Dean + Herrnstein): top 3 lines, end 3 lines, blank < 0 chars, default New; off: flows-on
- Herrnstein (fitted on Dean + Deaver): top 5 lines, end 3 lines, blank < 0 chars, default New; off: bare-number, flows-on

Deciding rule over document gaps, held-out predictions pooled (hits = gaps the rule decided; precision = share decided correctly):

| rule | decides | hits | correct | precision |
|---|---|---:|---:|---:|
| page-number | Cont | 77 | 67 | 87.0% |
| bare-number | Cont | 18 | 14 | 77.8% |
| jump-from | Cont | 14 | 14 | 100.0% |
| opening | New | 18 | 17 | 94.4% |
| date-line | New | 106 | 95 | 89.6% |
| prev-jump | Cont | 4 | 3 | 75.0% |
| prev-closing | New | 39 | 36 | 92.3% |
| flows-on | Cont | 8 | 6 | 75.0% |
| default | default | 210 | 126 | 60.0% |

Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum the counts, so they are page- or item-weighted.
