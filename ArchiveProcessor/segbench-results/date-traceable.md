# Dating: the staged pipeline against one shot, with the evidence checked (W46.date-traceable)

Written by `scripts/segbench/date_traceable.py score`. The owner's 300 (W41's sample: 119 print their year, 131 do not, 50 decade tags) and the public 300 (Library of Congress By the People transcriptions, catalogue dates). Classes are date_truth's: A the previous document prints the same year, A' chained through it, B a printed same-year document within three, C four or more away, D none in the folder. $0: the 27B ran on FarmShare, the 2B's replies are W41's cached ones; the Gemini arm is W46.date-traceable-paid, the claude -p arm waits for W46.gateway-models-ok.

## Findings

- **The staged pipeline does not beat one shot on the years that matter.** On the 131 documents whose year is not in the corpus text, the best staged configuration (rules, the 2B chooser, the 27B with neighbour dates on what propagation cannot reach, t=3) gets 35.9%; Gemini 3.8 Flash one shot gets 63.4%, the 27B one shot 42.0% with the app's prompt and 45.8% with the trace prompt and neighbour dates. Sending every undated document to the 27B (t=0) gives 37.4%.
- **It is far cheaper.** The t=3 configuration makes 63 27B calls per 1,000 documents (61 GPU-seconds) against 1,000 for one shot (about 969 GPU-seconds with the same prompt).
- **On printed years the rules plus a small chooser come close to the models.** Rules alone 89.1%, with the 2B's reply as chooser 95.0% (Gemini 97.5%). The 27B as chooser is worse than the 2B (91.6%): where the 2B named the document's own year, the 27B kept or chose a year the text mentions in passing ("in the spring of 1961").
- **Propagation alone is as good as the models on class A, at no cost.** Taking the nearest earlier dated document's year gets A 75.8% and A' 71.4% (Gemini 81.8%, the 27B 66.7%), but B 20.0%, C 5.7%: beyond the previous document it mostly propagates a wrong year, and escalating more (lower t) trades A for B. W46.date-enclosure's relation classifier is what would decide which documents to propagate to; it has not shipped.
- **A third of the 27B's citations fail the check, and many of those years are right.** Trace-plain: 198 valid, 101 unsupported, 49 of them with the right year. Reading the failures, most are a quote that does not carry the year as four digits, often because the model read through OCR damage ("27 April I 96I4", "feb, 2 4 , >964", "September 22, 19gS") or a two-digit date, and the checker, which wants the four digits in the quote, refuses them. The rest quote text that is not in the cited document. 146 of 300 replies wrote the citation as {"self": quote} rather than the asked shape and were read as the same citation. Conformal intervals reach about 90% coverage, but the widths (decades on the pipelines) come from a few far-wrong rule picks (1800 from a figure, 2026 from a capture footer), not from honest uncertainty.
- **Apple Vision text dates more of the 'unprinted' documents than the corpus text does.** The rule stage and propagation on Vision text of the first two pages get 48.1% of the 131 (corpus text 31.3%), on the Mac at about 1 s a page and $0: many of these documents do print their date, and ABBYY's layer garbled it ("ISIS" for 1915, "19gS"). The classes A to D are defined on the corpus text, so part of the 'not in text' gap is OCR, not dating. On printed years Vision rules read fewer (85.7% against 89.1%). Filed: W46.date-traceable-vision, the residue and chooser on Vision text.
- Not in this run: the Gemini arm (W46.date-traceable-paid, waits for W46.gateway-models-ok), the claude -p arm (held for the gateway, CLAUDE.md), the relation classifier (W46.date-enclosure), Foundation Models as the R1 chooser. The latest-year rule variant was written after reading the first rule's misses on the owner's set, so its owner figure is tuned; the public set is its check.

## Stage 1: rule candidates

Every date printed in the first 3,000 characters (full dates, numeric dates, month-year, bare years 1800-2030), each with its line. The pick is the first dated form in the first 15 lines, else the most weighted year. Sure = every dated form agrees; ambiguous = the chooser's cases.

| set | class | n | any candidate | truth among them | pick right | sure (right) | single (right) | ambiguous (right) | latest-year rule right |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| owner | in text | 119 | 119 | 119 | 106 (89.1%) | 63 (60) | 27 (27) | 29 (19) | 110 (92.4%) |
| owner | A | 33 | 6 | 1 | 1 (3.0%) | 3 (1) | 2 (0) | 1 (0) | 1 (3.0%) |
| owner | A' | 7 | 2 | 2 | 1 (14.3%) | 1 (1) | 0 (0) | 1 (0) | 1 (14.3%) |
| owner | B | 35 | 10 | 0 | 0 (0.0%) | 4 (0) | 2 (0) | 4 (0) | 0 (0.0%) |
| owner | C | 35 | 14 | 0 | 0 (0.0%) | 1 (0) | 6 (0) | 7 (0) | 0 (0.0%) |
| owner | D | 21 | 5 | 1 | 0 (0.0%) | 2 (0) | 0 (0) | 3 (0) | 0 (0.0%) |
| owner | rule time | | | | 0.36 ms a document on this Mac | | | | |
| public | in text | 257 | 255 | 255 | 236 (91.8%) | 170 (166) | 46 (46) | 39 (24) | 237 (92.2%) |
| public | not in text | 43 | 16 | 8 | 8 (18.6%) | 11 (8) | 3 (0) | 2 (0) | 8 (18.6%) |
| public | rule time | | | | 0.23 ms a document on this Mac | | | | |

## One shot, owner set (exact year)

The app's prompt (cached W41 replies) and the trace prompt sent to every document.

| configuration | in text | A | A' | B | C | D | not in text | decade | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gemini-3.8-flash | 97.5% | 81.8% | 71.4% | 62.9% | 45.7% | 61.9% | 63.4% | 68.0% | 92.7% | 0/300 | none asked | – | 92.4%, 3.0 y |
| qwen3.6-27b-nothink (app prompt) | 97.5% | 66.7% | 71.4% | 40.0% | 20.0% | 33.3% | 42.0% | 58.0% | 81.3% | 0/300 | none asked | – | 91.6%, 11.0 y |
| mlx-date-2b-8bit-nothink (app prompt) | 95.0% | 69.7% | 71.4% | 37.1% | 11.4% | 28.6% | 38.9% | 56.0% | 81.3% | 0/300 | none asked | – | 92.4%, 16.0 y |
| 27B trace-plain | 95.8% | 75.8% | 42.9% | 45.7% | 17.1% | 28.6% | 42.7% | 56.0% | 83.3% | 1/300 | 198 / 101 | 49 | 91.6%, 9.6 y |
| 27B trace-neigh | 96.6% | 72.7% | 71.4% | 51.4% | 17.1% | 33.3% | 45.8% | 54.0% | 83.0% | 8/300 | 197 / 95 | 51 | 89.3%, 13.8 y |
| 27B trace-shots | 96.6% | 72.7% | 57.1% | 40.0% | 17.1% | 33.3% | 42.0% | 56.0% | 80.7% | 8/300 | 192 / 100 | 48 | 91.6%, 15.6 y |

## The staged pipeline, owner set (exact year)

t = the escalation threshold: a document printing no date takes the year of the nearest earlier document printing one when that is at most t documents back, else goes to the residue stage. t=0 sends every undated document there; t=3 only those propagation cannot reach (it looks three back). A row with no residue stage gives no year to what propagation does not reach.

| configuration | in text | A | A' | B | C | D | not in text | decade | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rules only|no residue stage|t=3 | 89.1% | 75.8% | 71.4% | 20.0% | 5.7% | 9.5% | 31.3% | 30.0% | 66.0% | 19/300 | 270 / 11 | 6 | 90.8%, unbounded (12 with no year) |
| rules only|27B trace-plain|t=0 | 89.1% | 66.7% | 42.9% | 34.3% | 8.6% | 23.8% | 34.4% | 46.0% | 74.3% | 1/300 | 229 / 70 | 34 | 90.1%, 37.6 y |
| rules only|27B trace-plain|t=1 | 89.1% | 75.8% | 28.6% | 31.4% | 14.3% | 9.5% | 34.4% | 42.0% | 71.7% | 1/300 | 260 / 39 | 15 | 88.5%, 60.8 y |
| rules only|27B trace-plain|t=2 | 89.1% | 75.8% | 57.1% | 28.6% | 11.4% | 9.5% | 34.4% | 42.0% | 71.3% | 1/300 | 270 / 29 | 12 | 91.6%, 87.5 y |
| rules only|27B trace-plain|t=3 | 89.1% | 75.8% | 71.4% | 25.7% | 11.4% | 9.5% | 34.4% | 42.0% | 70.3% | 0/300 | 278 / 22 | 11 | 91.6%, 80.2 y |
| rules only|27B trace-neigh|t=0 | 89.1% | 63.6% | 71.4% | 37.1% | 11.4% | 23.8% | 36.6% | 44.0% | 74.0% | 7/300 | 227 / 66 | 35 | 92.4%, 97.4 y |
| rules only|27B trace-neigh|t=1 | 89.1% | 75.8% | 57.1% | 37.1% | 14.3% | 14.3% | 38.2% | 42.0% | 72.7% | 3/300 | 259 / 38 | 17 | 91.6%, 80.4 y |
| rules only|27B trace-neigh|t=2 | 89.1% | 75.8% | 71.4% | 34.3% | 11.4% | 9.5% | 36.6% | 42.0% | 72.0% | 1/300 | 273 / 26 | 13 | 91.6%, 87.5 y |
| rules only|27B trace-neigh|t=3 | 89.1% | 75.8% | 71.4% | 28.6% | 11.4% | 9.5% | 35.1% | 42.0% | 70.7% | 0/300 | 278 / 22 | 12 | 91.6%, 80.2 y |
| rules only|27B trace-shots|t=0 | 89.1% | 63.6% | 42.9% | 31.4% | 11.4% | 23.8% | 33.6% | 44.0% | 72.7% | 7/300 | 224 / 69 | 33 | 91.6%, 80.7 y |
| rules only|27B trace-shots|t=1 | 89.1% | 75.8% | 28.6% | 28.6% | 17.1% | 9.5% | 34.4% | 42.0% | 71.3% | 3/300 | 259 / 38 | 14 | 88.5%, 60.8 y |
| rules only|27B trace-shots|t=2 | 89.1% | 75.8% | 57.1% | 28.6% | 11.4% | 9.5% | 34.4% | 42.0% | 70.7% | 2/300 | 269 / 29 | 13 | 91.6%, 87.5 y |
| rules only|27B trace-shots|t=3 | 89.1% | 75.8% | 71.4% | 25.7% | 11.4% | 9.5% | 34.4% | 40.0% | 70.0% | 1/300 | 276 / 23 | 12 | 91.6%, 80.2 y |
| 2B chooser|no residue stage|t=3 | 95.0% | 75.8% | 71.4% | 20.0% | 5.7% | 14.3% | 32.1% | 30.0% | 68.7% | 19/300 | 269 / 12 | 7 | 90.8%, unbounded (12 with no year) |
| 2B chooser|27B trace-plain|t=0 | 95.0% | 66.7% | 42.9% | 34.3% | 8.6% | 28.6% | 35.1% | 46.0% | 77.0% | 1/300 | 228 / 71 | 35 | 90.8%, 34.6 y |
| 2B chooser|27B trace-plain|t=1 | 95.0% | 75.8% | 28.6% | 31.4% | 14.3% | 14.3% | 35.1% | 42.0% | 74.3% | 1/300 | 259 / 40 | 16 | 88.5%, 46.6 y |
| 2B chooser|27B trace-plain|t=2 | 95.0% | 75.8% | 57.1% | 28.6% | 11.4% | 14.3% | 35.1% | 42.0% | 74.0% | 1/300 | 269 / 30 | 13 | 91.6%, 80.4 y |
| 2B chooser|27B trace-plain|t=3 | 95.0% | 75.8% | 71.4% | 25.7% | 11.4% | 14.3% | 35.1% | 42.0% | 73.0% | 0/300 | 277 / 23 | 12 | 91.6%, 66.1 y |
| 2B chooser|27B trace-neigh|t=0 | 95.0% | 63.6% | 71.4% | 37.1% | 11.4% | 28.6% | 37.4% | 44.0% | 76.7% | 7/300 | 226 / 67 | 36 | 92.4%, 88.3 y |
| 2B chooser|27B trace-neigh|t=1 | 95.0% | 75.8% | 57.1% | 37.1% | 14.3% | 19.0% | 38.9% | 42.0% | 75.3% | 3/300 | 258 / 39 | 18 | 91.6%, 66.3 y |
| 2B chooser|27B trace-neigh|t=2 | 95.0% | 75.8% | 71.4% | 34.3% | 11.4% | 14.3% | 37.4% | 42.0% | 74.7% | 1/300 | 272 / 27 | 14 | 91.6%, 80.4 y |
| 2B chooser|27B trace-neigh|t=3 | 95.0% | 75.8% | 71.4% | 28.6% | 11.4% | 14.3% | 35.9% | 42.0% | 73.3% | 0/300 | 277 / 23 | 13 | 91.6%, 66.1 y |
| 2B chooser|27B trace-shots|t=0 | 95.0% | 63.6% | 42.9% | 31.4% | 11.4% | 28.6% | 34.4% | 44.0% | 75.3% | 7/300 | 223 / 70 | 34 | 91.6%, 66.4 y |
| 2B chooser|27B trace-shots|t=1 | 95.0% | 75.8% | 28.6% | 28.6% | 17.1% | 14.3% | 35.1% | 42.0% | 74.0% | 3/300 | 258 / 39 | 15 | 88.5%, 46.6 y |
| 2B chooser|27B trace-shots|t=2 | 95.0% | 75.8% | 57.1% | 28.6% | 11.4% | 14.3% | 35.1% | 42.0% | 73.3% | 2/300 | 268 / 30 | 14 | 91.6%, 80.4 y |
| 2B chooser|27B trace-shots|t=3 | 95.0% | 75.8% | 71.4% | 25.7% | 11.4% | 14.3% | 35.1% | 40.0% | 72.7% | 1/300 | 275 / 24 | 13 | 91.6%, 66.1 y |
| 27B chooser|no residue stage|t=3 | 91.6% | 75.8% | 71.4% | 20.0% | 5.7% | 14.3% | 32.1% | 30.0% | 67.0% | 19/300 | 269 / 12 | 7 | 90.8%, unbounded (12 with no year) |
| 27B chooser|27B trace-plain|t=0 | 91.6% | 66.7% | 42.9% | 34.3% | 8.6% | 28.6% | 35.1% | 46.0% | 75.3% | 1/300 | 228 / 71 | 35 | 90.8%, 34.6 y |
| 27B chooser|27B trace-plain|t=1 | 91.6% | 75.8% | 28.6% | 31.4% | 14.3% | 14.3% | 35.1% | 42.0% | 72.7% | 1/300 | 259 / 40 | 16 | 88.5%, 46.6 y |
| 27B chooser|27B trace-plain|t=2 | 91.6% | 75.8% | 57.1% | 28.6% | 11.4% | 14.3% | 35.1% | 42.0% | 72.3% | 1/300 | 269 / 30 | 13 | 91.6%, 80.4 y |
| 27B chooser|27B trace-plain|t=3 | 91.6% | 75.8% | 71.4% | 25.7% | 11.4% | 14.3% | 35.1% | 42.0% | 71.3% | 0/300 | 277 / 23 | 12 | 91.6%, 66.1 y |
| 27B chooser|27B trace-neigh|t=0 | 91.6% | 63.6% | 71.4% | 37.1% | 11.4% | 28.6% | 37.4% | 44.0% | 75.0% | 7/300 | 226 / 67 | 36 | 92.4%, 88.3 y |
| 27B chooser|27B trace-neigh|t=1 | 91.6% | 75.8% | 57.1% | 37.1% | 14.3% | 19.0% | 38.9% | 42.0% | 73.7% | 3/300 | 258 / 39 | 18 | 91.6%, 66.3 y |
| 27B chooser|27B trace-neigh|t=2 | 91.6% | 75.8% | 71.4% | 34.3% | 11.4% | 14.3% | 37.4% | 42.0% | 73.0% | 1/300 | 272 / 27 | 14 | 91.6%, 80.4 y |
| 27B chooser|27B trace-neigh|t=3 | 91.6% | 75.8% | 71.4% | 28.6% | 11.4% | 14.3% | 35.9% | 42.0% | 71.7% | 0/300 | 277 / 23 | 13 | 91.6%, 66.1 y |
| 27B chooser|27B trace-shots|t=0 | 91.6% | 63.6% | 42.9% | 31.4% | 11.4% | 28.6% | 34.4% | 44.0% | 73.7% | 7/300 | 223 / 70 | 34 | 91.6%, 66.4 y |
| 27B chooser|27B trace-shots|t=1 | 91.6% | 75.8% | 28.6% | 28.6% | 17.1% | 14.3% | 35.1% | 42.0% | 72.3% | 3/300 | 258 / 39 | 15 | 88.5%, 46.6 y |
| 27B chooser|27B trace-shots|t=2 | 91.6% | 75.8% | 57.1% | 28.6% | 11.4% | 14.3% | 35.1% | 42.0% | 71.7% | 2/300 | 268 / 30 | 14 | 91.6%, 80.4 y |
| 27B chooser|27B trace-shots|t=3 | 91.6% | 75.8% | 71.4% | 25.7% | 11.4% | 14.3% | 35.1% | 40.0% | 71.0% | 1/300 | 275 / 24 | 13 | 91.6%, 66.1 y |

## One shot, public set (exact year)

The app's prompt (cached W41 replies) and the trace prompt sent to every document.

| configuration | in text | not in text | all | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mlx-date-2b-8bit-nothink (app prompt) | 95.3% | 90.7% | 94.7% | 97.3% | 0/300 | none asked | – | 93.0%, 2.0 y |
| 27B trace-plain | 96.9% | 58.1% | 91.3% | 94.3% | 5/300 | 230 / 65 | 51 | 90.7%, unbounded (4 with no year) |

## The staged pipeline, public set (exact year)

t = the escalation threshold: a document printing no date takes the year of the nearest earlier document printing one when that is at most t documents back, else goes to the residue stage. t=0 sends every undated document there; t=3 only those propagation cannot reach (it looks three back). A row with no residue stage gives no year to what propagation does not reach.

| configuration | in text | not in text | all | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rules only|no residue stage|t=3 | 91.8% | 18.6% | 81.3% | 83.7% | 29/300 | 258 / 13 | 10 | 37.2%, unbounded (27 with no year) |
| rules only|27B trace-plain|t=3 | 92.6% | 53.5% | 87.0% | 91.0% | 4/300 | 260 / 36 | 25 | 90.7%, unbounded (4 with no year) |
| 2B chooser|no residue stage|t=3 | 96.1% | 18.6% | 85.0% | 86.7% | 29/300 | 259 / 12 | 10 | 37.2%, unbounded (27 with no year) |
| 2B chooser|27B trace-plain|t=3 | 96.9% | 53.5% | 90.7% | 94.0% | 4/300 | 261 / 35 | 25 | 90.7%, unbounded (4 with no year) |
| 27B chooser|no residue stage|t=3 | 95.3% | 18.6% | 84.3% | 85.3% | 29/300 | 259 / 12 | 10 | 37.2%, unbounded (27 with no year) |
| 27B chooser|27B trace-plain|t=3 | 96.1% | 53.5% | 90.0% | 92.7% | 4/300 | 261 / 35 | 25 | 90.7%, unbounded (4 with no year) |

## The Vision-text arm (R1), owner set (exact year)

The rule stage and propagation on Apple Vision text (the app's settings, segbench `ocr.swift`) of the first two pages of each document and of the three before it, 300 documents, beside the corpus text cache on the same documents. Rendering and reading took 1.02 s a page on this Mac. The 2B chooser's replies were made from the corpus text; on Vision text it is kept only when it names a Vision candidate. The route's own chooser (Foundation Models) is not measured.

| configuration | in text | A | A' | B | C | D | not in text | decade | within 1, all | invalid | evidence valid / unsupported | right but unsupported | 90% conformal coverage, width (not in text) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rules only | 85.7% | 78.8% | 71.4% | 42.9% | 25.7% | 38.1% | 48.1% | 24.0% | 69.7% | 7/300 | 268 / 25 | 16 | 92.4%, 84.4 y |
| rules only (corpus text, same documents) | 89.1% | 75.8% | 71.4% | 20.0% | 5.7% | 9.5% | 31.3% | 30.0% | 66.0% | 19/300 | 270 / 11 | 6 | 90.8%, unbounded (12 with no year) |
| 2B chooser | 89.9% | 78.8% | 71.4% | 40.0% | 25.7% | 38.1% | 47.3% | 24.0% | 71.7% | 7/300 | 269 / 24 | 16 | 92.4%, 84.4 y |
| 2B chooser (corpus text, same documents) | 95.0% | 75.8% | 71.4% | 20.0% | 5.7% | 14.3% | 32.1% | 30.0% | 68.7% | 19/300 | 269 / 12 | 7 | 90.8%, unbounded (12 with no year) |

## Cost

GPU-seconds a reply: the job's measured wall time on one L40S (16 requests at once), shared over the arms by tokens. A configuration's cost per 1,000 documents is its calls times these; the 2B chooser runs on the Mac at 1.39 s a document. No money on any arm.

| arm | replies | GPU-seconds a reply |
|---|---:|---:|
| choose | 97 | 0.39 |
| trace-plain | 600 | 0.64 |
| trace-neigh | 300 | 0.97 |
| trace-shots | 300 | 1.15 |

| configuration | 27B calls per 1,000 | GPU-seconds per 1,000 | Mac seconds per 1,000 |
|---|---:|---:|---:|
| owner|rules only|no residue stage|t=3 | 0 | 0 | 0 |
| owner|rules only|27B trace-plain|t=0 | 413 | 263 | 0 |
| owner|rules only|27B trace-plain|t=1 | 183 | 116 | 0 |
| owner|rules only|27B trace-plain|t=2 | 100 | 64 | 0 |
| owner|rules only|27B trace-plain|t=3 | 63 | 40 | 0 |
| owner|rules only|27B trace-neigh|t=0 | 413 | 401 | 0 |
| owner|rules only|27B trace-neigh|t=1 | 183 | 178 | 0 |
| owner|rules only|27B trace-neigh|t=2 | 100 | 97 | 0 |
| owner|rules only|27B trace-neigh|t=3 | 63 | 61 | 0 |
| owner|rules only|27B trace-shots|t=0 | 413 | 477 | 0 |
| owner|rules only|27B trace-shots|t=1 | 183 | 212 | 0 |
| owner|rules only|27B trace-shots|t=2 | 100 | 115 | 0 |
| owner|rules only|27B trace-shots|t=3 | 63 | 73 | 0 |
| owner|2B chooser|no residue stage|t=3 | 0 | 0 | 260 |
| owner|2B chooser|27B trace-plain|t=0 | 413 | 263 | 260 |
| owner|2B chooser|27B trace-plain|t=1 | 183 | 116 | 260 |
| owner|2B chooser|27B trace-plain|t=2 | 100 | 64 | 260 |
| owner|2B chooser|27B trace-plain|t=3 | 63 | 40 | 260 |
| owner|2B chooser|27B trace-neigh|t=0 | 413 | 401 | 260 |
| owner|2B chooser|27B trace-neigh|t=1 | 183 | 178 | 260 |
| owner|2B chooser|27B trace-neigh|t=2 | 100 | 97 | 260 |
| owner|2B chooser|27B trace-neigh|t=3 | 63 | 61 | 260 |
| owner|2B chooser|27B trace-shots|t=0 | 413 | 477 | 260 |
| owner|2B chooser|27B trace-shots|t=1 | 183 | 212 | 260 |
| owner|2B chooser|27B trace-shots|t=2 | 100 | 115 | 260 |
| owner|2B chooser|27B trace-shots|t=3 | 63 | 73 | 260 |
| owner|27B chooser|no residue stage|t=3 | 187 | 73 | 0 |
| owner|27B chooser|27B trace-plain|t=0 | 600 | 336 | 0 |
| owner|27B chooser|27B trace-plain|t=1 | 370 | 190 | 0 |
| owner|27B chooser|27B trace-plain|t=2 | 287 | 137 | 0 |
| owner|27B chooser|27B trace-plain|t=3 | 250 | 113 | 0 |
| owner|27B chooser|27B trace-neigh|t=0 | 600 | 474 | 0 |
| owner|27B chooser|27B trace-neigh|t=1 | 370 | 251 | 0 |
| owner|27B chooser|27B trace-neigh|t=2 | 287 | 170 | 0 |
| owner|27B chooser|27B trace-neigh|t=3 | 250 | 134 | 0 |
| owner|27B chooser|27B trace-shots|t=0 | 600 | 550 | 0 |
| owner|27B chooser|27B trace-shots|t=1 | 370 | 285 | 0 |
| owner|27B chooser|27B trace-shots|t=2 | 287 | 188 | 0 |
| owner|27B chooser|27B trace-shots|t=3 | 250 | 146 | 0 |
| public|rules only|no residue stage|t=3 | 0 | 0 | 0 |
| public|rules only|27B trace-plain|t=3 | 97 | 61 | 0 |
| public|2B chooser|no residue stage|t=3 | 0 | 0 | 190 |
| public|2B chooser|27B trace-plain|t=3 | 97 | 61 | 190 |
| public|27B chooser|no residue stage|t=3 | 137 | 54 | 0 |
| public|27B chooser|27B trace-plain|t=3 | 233 | 115 | 0 |
