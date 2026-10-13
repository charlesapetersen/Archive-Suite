# Cheaper cloud models for segmentation (W41.seg-cheap)

Run 2026-10-13 through OpenRouter (`scripts/segbench/method_openrouter.py`, the `CHEAP` set). The request is the one `cues-models-Deaver.md` sent the cloud models: method_window_cues's prompt (the owner's cues and rules, with each page's Apple Vision text), the same 7-page windows, combining and assembly, the images at the bench's 1600 px. Reasoning at each model's lowest setting, temperature 0, the maker's own provider pinned where it serves the model (open builds: the provider and precision named). Prices are what OpenRouter charged per call; "batch" applies OpenRouter's `:batch` price (the maker's flex tier) to the same logged tokens and was not itself run. Item spend $2.57.

## The screen, Deaver (development box, 149 pages, 51 windows, own photo labels)

Known points: Gemini 3.8 Flash 97.9% (0 false splits, 1 false merge; $3.61 list / $1.81 batch per 1,000 pages over five boxes, `options.md`). Gemini 3.1 Flash-Lite had 72.3% through the Gemini API with prompt g1 (`gemini-variants-Deaver.md`; the 84.6% the item quotes is its pooled development figure). Re-run here on this route, it scores 83.7%, so the route and prompt variant alone move a weak model by about 11 points. Treat cross-route differences of that size with care. One box: each page is 0.7 points.

| model | provider, reasoning | pages in exact doc | false splits | false merges | failed windows | reasoning tokens/call | cost paid | per 1,000 pages, standard | per 1,000 pages, batch |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Gemini 3.5 Flash-Lite | google-ai-studio, reasoning minimal | 85.1% | 6 | 2 | 0 | 0 | $0.239 | $1.60 | $0.80 |
| GPT-5.6 Luna | openai, reasoning minimal | 96.5% | 1 | 1 | 0 | 380 | $0.302 | $2.03 | $0.84 |
| GPT-5.4 Nano | openai, reasoning minimal | 83.7% | 1 | 5 | 0 | 466 | $0.268 | $1.80 | $0.90 |
| GPT-5.4 Mini | openai, reasoning minimal | not run: its one-window probe ($0.0095 for 4 pages) projects to about $0.90 for Deaver, $6 per 1,000 pages, above Gemini 3.8 Flash, so it cannot be a finalist | | | | | | | |
| GLM-5.3 Flash | z-ai fp8, reasoning minimal | 97.9% | 0 | 1 | 0 | 153 | $0.181 | $1.21 | $0.49 |
| Qwen3.5 Flash | alibaba, reasoning none | 95.7% | 0 | 2 | 3 | 0 | $0.083 | $0.56 | none offered |
| Qwen3.6 Flash | alibaba, reasoning none | 91.5% | 2 | 4 | 2 | 0 | $0.191 | $1.28 | none offered |
| Mistral Small (2603) | mistral, reasoning none | not collected: 27 of 51 windows; OpenRouter returned "rate-limited upstream" (429) for the rest across three tries on 2026-10-13 ($0.0034 per window measured, about $1.15 per 1,000 pages) | | | | | | | |
| Gemma 4 26B-A4B | dekallm bf16, reasoning none | 73.8% | 9 | 5 | 0 | 0 | $0.028 | $0.19 | none offered |
| Llama 4 Maverick | novita fp8, reasoning n/a | 80.9% | 8 | 2 | 0 | 0 | $0.121 | $0.81 | none offered |
| Gemini 3.1 Flash-Lite | google-ai-studio, reasoning minimal | 83.7% | 8 | 1 | 1 | 0 | $0.186 | $1.25 | $0.63 |

**Finalists** (frozen in `cheap-finalists.json` before any test-box call): GLM-5.3 Flash (97.9%), GPT-5.6 Luna (96.5%), Qwen3.5 Flash (95.7%, three windows failed to parse, which counts at the edge of "about two points"). Everything else is five or more points down.

## The finalists on all five boxes (truth photo labels)

Development boxes Dean, Deaver, Herrnstein; test boxes Stanton and RG 165, held out as `ensemble-test.md` held them. Gemini 3.8 Flash's cached windows (options.py's voter G) are scored the same way beside them, at no cost. The five-box run for all three was estimated at $2.87, an item total of $4.57, past the $3 line. So only GLM-5.3 Flash ran ($0.92 estimated, $0.88 paid). Luna and Qwen3.5 Flash wait for the owner (`W41.seg-cheap-more`).

### Review as option F, everything 85% sure or less flagged

| model | boxes | pages | no checking | flagged | per 100 pages | after checking | unflagged errors | reaches 99% |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Gemini 3.8 Flash (low), the bar | Dean | 202 | 85.2% | 2 | 1.0 | 94.4% | 4 | |
| Gemini 3.8 Flash (low), the bar | Deaver | 149 | 97.9% | 1 | 0.7 | 97.9% | 1 | |
| Gemini 3.8 Flash (low), the bar | Herrnstein | 200 | 91.2% | 5 | 2.5 | 91.2% | 4 | |
| Gemini 3.8 Flash (low), the bar | **dev pooled** | 551 | 90.7% | 8 | 1.5 | 94.2% | 9 | no |
| Gemini 3.8 Flash (low), the bar | Stanton | 250 | 89.3% | 6 | 2.4 | 92.6% | 3 | |
| Gemini 3.8 Flash (low), the bar | RG165 | 113 | 87.4% | 1 | 0.9 | 87.4% | 3 | |
| Gemini 3.8 Flash (low), the bar | **test pooled** | 363 | 88.8% | 7 | 1.9 | 91.2% | 6 | no |
| GLM-5.3 Flash | Dean | 202 | 85.2% | 8 | 4.0 | 96.4% | 3 | |
| GLM-5.3 Flash | Deaver | 149 | 97.9% | 9 | 6.0 | 97.9% | 1 | |
| GLM-5.3 Flash | Herrnstein | 200 | 89.5% | 15 | 7.5 | 93.4% | 2 | |
| GLM-5.3 Flash | **dev pooled** | 551 | 90.2% | 32 | 5.8 | 95.8% | 6 | no |
| GLM-5.3 Flash | Stanton | 250 | 81.5% | 26 | 10.4 | 91.4% | 3 | |
| GLM-5.3 Flash | RG165 | 113 | 83.9% | 4 | 3.5 | 89.7% | 2 | |
| GLM-5.3 Flash | **test pooled** | 363 | 82.1% | 30 | 8.3 | 90.9% | 5 | no |

### The level fitted per model, as options.py did

0.85 was Claude's fitted level. Gemini and GLM give higher confidences and flag little at it, so neither reaches 99% there. Here each model gets its own level: held out per development box (fitted on the other two), and for the test boxes, fitted on all three. At the 98% bar Gemini's row reproduces `options.md` exactly, which checks this path.

| model | bar | dev, held out: after checking | flagged per 100 pages | level for the test boxes | test: no checking | after checking | flagged per 100 pages | unflagged errors |
|---|---|---:|---:|---|---:|---:|---:|---:|
| Gemini 3.8 Flash (low), the bar | 99% | 100.0% | 39.4 | <= 0.985 | 88.8% | 100.0% | 51.0 | 0 |
| Gemini 3.8 Flash (low), the bar | 98% | 98.6% | 10.3 | <= 0.965 | 88.8% | 100.0% | 24.2 | 0 |
| GLM-5.3 Flash | 99% | 99.4% | 60.1 | <= 0.975 | 82.1% | 100.0% | 81.0 | 0 |
| GLM-5.3 Flash | 98% | 97.3% | 17.1 | <= 0.925 | 82.1% | 98.5% | 33.1 | 1 |

| model | pages | calls | cost paid | per 1,000 pages, standard | per 1,000 pages, batch |
|---|---:|---:|---:|---:|---:|
| GLM-5.3 Flash | 914 | 313 | $1.056 | $1.16 | $0.46 |

Not yet run on all five boxes: GPT-5.6 Luna, Qwen3.5 Flash.

## Verdict (2026-10-13)

**A cheaper model segments Deaver as well, but GLM-5.3 Flash does not hold up off it.** It matched Gemini 3.8 Flash on Deaver (97.9%) at about a third of the price ($1.16 against $3.61 per 1,000 pages at list; $0.46 against $1.81 at batch). Across the other four boxes it fell behind. On the test boxes it puts 82.1% of pages in the exact document with no checking, against Gemini's 88.8%, and its confidence ranks its own errors less well. Reaching 99% after checking costs 81 flagged boundaries per 100 test pages, against Gemini's 51. At the 98% bar it is 33 against 24, and it still lets one error through unflagged where Gemini lets none. Checking is the owner's time, and at the 98% bar about nine more boundaries per 100 pages outweighs a saving of $2.45 per 1,000 pages. So GLM-5.3 Flash is a budget option for a user who checks everything flagged, not a replacement for the Gemini default.

**A single screen box over-rewards.** The Deaver leader tied Gemini there, then fell 6.7 points behind it (no checking) on the held-out test boxes. GPT-5.6 Luna (96.5% on Deaver, $2.03 / $0.84) and Qwen3.5 Flash (95.7%, $0.56, no batch) are the two finalists not yet measured off Deaver. Their five-box run is estimated at $1.95, for an item total of about $4.57 against the $3 line, so it is the owner's call. Qwen3.5 Flash is the cheapest candidate and the one with the most to gain from a fair five-box test.

**The rest are out.** Gemini 3.5 Flash-Lite 85.1%, GPT-5.4 Nano 83.7%, Llama 4 Maverick 80.9% and Gemma 4 26B-A4B 73.8% each have six or more false splits on one box. GPT-5.4 Mini costs more per page than Gemini 3.8 Flash. Mistral Small could not be measured (rate-limited upstream).
