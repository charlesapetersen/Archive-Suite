# W36.seg-whole — one long-context call per folder, as a third voter (development set)

Run 2026-10-11 on Dean, Deaver and Herrnstein (551 pages) only; the test collections were not touched. Model gemini-3.8-flash through the Gemini API, thinkingLevel "low", temperature 0, JSON response schema; prompt wh1 (g1's owner's cues and document rules, adapted to a folder of document pages). 21 folders of two pages or more, the longest 82 pages. Folders come from the truth's label photos, so every figure here uses truth photo labels and measures boundary finding only. The prompt was written after reading the owner's notes on development pages, checked on one probe folder for format only and not revised against page-level errors; nothing was fitted.

## Headline

| method | collection | pages in exact doc | docs exact | false splits | false merges | boundary F1 |
|---|---|---:|---:|---:|---:|---:|
| whole-gemini | Dean | 94.4% | 93.4% | 0 | 4 | 0.982 |
| whole-gemini | Deaver | 93.6% | 96.6% | 1 | 1 | 0.988 |
| whole-gemini | Herrnstein | 91.2% | 95.4% | 6 | 2 | 0.958 |
| whole-gemini | pooled | 93.1% | 95.0% | 7 | 7 | 0.976 |
| whole-gemini-c10 | Dean | 85.2% | 91.7% | 2 | 4 | 0.974 |
| whole-gemini-c10 | Deaver | 95.0% | 94.4% | 1 | 2 | 0.982 |
| whole-gemini-c10 | Herrnstein | 89.5% | 94.4% | 3 | 2 | 0.974 |
| whole-gemini-c10 | pooled | 89.4% | 93.4% | 6 | 8 | 0.976 |
| window-claude-truth-photos | Dean | 85.2% | 91.7% | 2 | 4 | 0.974 |
| window-claude-truth-photos | Deaver | 96.5% | 98.9% | 1 | 0 | 0.994 |
| window-claude-truth-photos | Herrnstein | 91.2% | 95.4% | 2 | 2 | 0.979 |
| window-claude-truth-photos | pooled | 90.3% | 94.9% | 5 | 6 | 0.981 |
| window-gemini-lite-truth-photos | Dean | 86.7% | 94.2% | 3 | 2 | 0.979 |
| window-gemini-lite-truth-photos | Deaver | 72.3% | 82.8% | 17 | 0 | 0.906 |
| window-gemini-lite-truth-photos | Herrnstein | 91.7% | 96.3% | 7 | 1 | 0.959 |
| window-gemini-lite-truth-photos | pooled | 84.6% | 91.8% | 27 | 3 | 0.951 |
| spring-v1-oracle-photos | Dean | 85.7% | 88.5% | 7 | 6 | 0.945 |
| spring-v1-oracle-photos | Deaver | 84.4% | 93.1% | 7 | 0 | 0.959 |
| spring-v1-oracle-photos | Herrnstein | 86.7% | 93.4% | 10 | 2 | 0.938 |
| spring-v1-oracle-photos | pooled | 85.7% | 91.4% | 24 | 8 | 0.946 |

## Does one long call degrade with length?

Every document gap inside a folder of two pages or more, judged once by each variant. The same model and prompt; only how much of the folder the call sees differs. A folder of 10 pages or fewer is the same call in both, so those rows match by construction.

### By folder length

| folder length (pages) | folders | gaps | whole: errors | whole: error rate | 10-page pieces: errors | 10-page pieces: error rate | gaps only whole got wrong | gaps only the pieces got wrong |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2–10 | 5 | 21 | 0 | 0.0% | 0 | 0.0% | 0 | 0 |
| 11–20 | 7 | 101 | 7 | 6.9% | 4 | 4.0% | 4 | 1 |
| 21–40 | 6 | 168 | 4 | 2.4% | 4 | 2.4% | 1 | 1 |
| 41+ | 3 | 204 | 3 | 1.5% | 6 | 2.9% | 0 | 3 |
| all | 21 | 494 | 14 | 2.8% | 14 | 2.8% | 5 | 5 |

### By the gap's place in the whole-folder call

Gap 1 is between the folder's first and second page. Only folders longer than 10 pages, so the rows say whether a long call is worse late in the folder than early in it.

| gap position in the call | gaps | whole: errors | whole: error rate | 10-page pieces: errors |
|---|---:|---:|---:|---:|
| 1–10 | 160 | 6 | 3.8% | 7 |
| 11–20 | 121 | 5 | 4.1% | 2 |
| 21–40 | 108 | 3 | 2.8% | 4 |
| 41 and later | 84 | 0 | 0.0% | 1 |

## The same model over 7-page windows, Deaver

compare_gemini.py ran gemini-3.8-flash (low) over window-claude's 7-page windows with prompt g1 on Deaver only. Scored here with truth photo labels, beside this item's two variants on the same box.

| method | pages in exact doc | false splits | false merges |
|---|---:|---:|---:|
| gemini-3.8-flash, 7-page windows (g1) | 97.9% | 0 | 1 |
| whole-gemini | 93.6% | 1 | 1 |
| whole-gemini-c10 | 95.0% | 1 | 2 |

## Its own confidence (whole-gemini)

| threshold | accepted | errors among accepted | error rate | left to review per 100 pages |
|---:|---:|---:|---:|---:|
| 0.00 | 494 | 14 | 2.8% | 0.0 |
| 0.80 | 494 | 14 | 2.8% | 0.0 |
| 0.90 | 490 | 10 | 2.0% | 0.7 |
| 0.95 | 488 | 9 | 1.8% | 1.1 |
| 0.98 | 451 | 3 | 0.7% | 7.8 |

Review load to 98% pooled by its own confidence alone: 494 boundaries (89.7 per 100 pages). The step before it is 91 boundaries at 97.9%: the confidences are coarse (403 of 494 gaps share one value), and a threshold cannot split a tie.

## Voting

Truth photo labels throughout, so only boundaries between two document pages are voted on. window-claude and window-gemini-lite come from their caches (no new call). A boundary every voter decides the same way is accepted; any other is flagged for review. Before review a disagreement takes the majority, a tie the most confident voter. Review corrects a boundary to the truth. After the flagged ones, the agreed boundaries are reviewed least confident first (the lowest of the voters' confidences), whole ties at a time.

| voters | flagged | flagged per 100 pages | each voter's errors (all / at flagged) | errors left among agreed | pages in exact doc, no review | after reviewing the flagged | 98% pooled after | per 100 pages | 98% in every collection after |
|---|---:|---:|---|---:|---:|---:|---:|---:|---:|
| window-claude + whole-gemini | 7 | 1.3 | window-claude 11/2; whole-gemini 14/5 | 9 | 93.1% | 94.2% | 30 | 5.4 | 35 |
| window-claude + window-gemini-lite | 25 | 4.5 | window-claude 11/3; window-gemini-lite 30/22 | 8 | 88.2% | 92.9% | 44 | 8.0 | 49 |
| window-claude + window-gemini-lite + whole-gemini | 27 | 4.9 | window-claude 11/5; window-gemini-lite 30/24; whole-gemini 14/8 | 6 | 89.6% | 96.3% | 44 | 8.0 | 49 |

## Calls and cost

Calls made: 82 (0 parse failures). Tokens: 1,671,593 in, 52,807 out (of them 0 thinking). Longest call 41 s. Cost at the assumed list price ($0.75 / $3.75 per million tokens in / out, 3.8 Flash's introductory price): $1.45.

