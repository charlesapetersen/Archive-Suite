# Gemini 4 Hydrogen on the owner's 96 (W46.gemini4-hydrogen-96)

Gemini 4 Hydrogen (`gemini-4-hydrogen`, returned as gemini-4-hydrogen), read on 2026-11-18 through AI Studio's `generateContent` on the personal key (paid tier: every call's `serviceTier` was standard), with the cloud panel's Gemini 3.8 Flash settings: the same 99 frozen 2,400 px JPEGs, the same prompt, temperature 0, thinking level low, 8,192 output tokens, the API's default media resolution (`scripts/segbench/ocr_hydrogen96.py`). Gemini 3.8 Flash and Qwen3.6 27B are their cached cloud-panel readings (W41.ocr-panel-cloud). NES is `ocr_panel_score.score`; the 96 are the 99 settled jobs less the three agreement letters.

## Verdict

Hydrogen does not resolve ahead of Gemini 3.8 Flash on the 96 (a tie under the rerun tie rule, 0.49 points or an interval across 0), so the app's default reader stays Gemini 3.8 Flash. From 1 Jan 2027 the two cost the same per token, so only the reading would separate them.

Per page Hydrogen costs more than the same price suggests: at low thinking it spent 751 thinking tokens a page, billed as output, where 3.8 Flash's cached calls billed none, so it is $11.39 per 1,000 pages against 3.8's $6.44 at the January price ($3.22 today). It answered every page (3.8 Flash refused two printed pages) and named the page kind right more often. The bench's headline sets p081 apart (no correctable truth): there 3.8 Flash is 96.47, Hydrogen 96.90 and Qwen3.6 27B 95.38.

| | Gemini 4 Hydrogen (drafter's relative) | Gemini 3.8 Flash (the truth's drafter) | Qwen3.6 27B (non-drafter) |
|---|---:|---:|---:|
| pages answered | 96/96 | 94/96 | 95/96 |
| NES on the pages answered | 96.89 | 96.44 | 95.34 |
| NES, all 96 (failure = 0) | 96.89 | 94.43 | 94.35 |
| kind right | 93 | 87 | 86 |
| hand pages, NES (owner-checked 16, failure = 0) | 94.65 | 95.81 | 92.61 |
| $ per 1,000 pages | $11.39 (billed tokens at list $1.5/$7.5) | $3.22 billed at $0.75/$3.75; $6.44 at $1.5/$7.5 from 1 Jan 2027 | (cloud panel) |
| median seconds a page | 6.3 | 4.8 | |

- Hydrogen less 3.8 Flash, pages both answered: +0.54 NES points on 94 pages (95% bootstrap -0.40 to +1.77; permutation p 0.406): **tie**.
- Hydrogen less Qwen3.6 27B, pages both answered: +1.54 NES points on 95 pages (95% bootstrap -0.48 to +3.51; permutation p 0.146): **tie**.
- Hydrogen less 3.8 Flash on the 16 hand pages (failure = 0): -1.17 NES points on 16 pages (95% bootstrap -3.86 to +0.63; permutation p 0.480): **tie**.

| kind | pages | Gemini 4 Hydrogen NES answered | Gemini 3.8 Flash NES answered | Qwen3.6 27B NES answered |
|---|---:|---:|---:|---:|
| handwritten | 16 | 94.65 (16) | 95.81 (16) | 92.61 (16) |
| mixed | 2 | 75.76 (2) | 77.06 (2) | 72.00 (2) |
| printed | 28 | 96.27 (28) | 93.92 (26) | 94.82 (28) |
| typewritten | 50 | 98.80 (50) | 98.73 (50) | 97.49 (49) |

Hydrogen used 140,231 input, 45,699 answer and 72,089 thinking tokens on the 96 (751 thinking a page); the 96 cost $1.0938, and the item $1.1286 in all (the 99 jobs and the one-page probe that is the first of them). Second arm: not run: the low arm spent $1.1286 of the $2.00 cap, and the default (dynamic) thinking is expected to spend at least as many thinking tokens as low (not measured), so a second arm of the same pages would pass the cap.

## Original pages (96, excluding the agreement-only letters)

| route | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | kind right % | cost / page |
|---|---:|---:|---:|---:|---:|---:|---:|
| gemini4-hydrogen · AI Studio, personal key | 96/96/96 | 96.89 | 97.65 | 0.55 | 0.43 | 97 | $0.01139 (billed tokens at list) |

## Measurement card

- **Truth.** The adjudicated 96 (`ocr_panel.TRUTH`, with the 2026-10-29 corrections and the owner's handwriting sheet of 2026-10-31). Its drafter is Gemini 3.8 Flash; Hydrogen is a later Gemini, so its row is a drafter's relative and may share the drafter's readings where the owner did not check. Qwen3.6 27B is the non-drafter beside it. The owner checked the 16 hand pages blind (`ocr-hands-rescore.md`).
- **Selection.** The frozen 96; no page chosen by a route or by ABBYY text. Every page where Apple Vision (26.6) read fewer than 20 words was replaced at the draw (19 of them, 4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as empty, and every comparison with Vision on them is on pages Vision could read. By the owner's answers, 15 of the 19 replaced pages were few-word pages, and 19 of 200 drawn owner pages (about 10%) hold only a few words (`ocr-vision-unfiltered.md`).
- **Comparison.** The same images, prompt, temperature, thinking level and output cap as 3.8 Flash's cloud panel row; 3.8 went through OpenRouter to Google AI Studio, Hydrogen straight to AI Studio. Only the owner's set was read: the item's scope is the 96, and its $2 cap leaves no room for the 895, so the public half is not run (the "both sets" rule's missing half; nothing is filed, since no route waits on it).
- **Noise.** n = 96, paired page bootstrap; the rerun floor is W46.ocr-rerun-noise's (Gemini 3.7 Flash moved 0.24 points across identical runs), so a gap under 0.49 points or an interval across 0 is a tie.
- **Scope.** One arm, low thinking; Hydrogen's default thinking was not read. Prices are list prices as of November 2026; the key reports no cost, so the cost is the billed tokens at list.
