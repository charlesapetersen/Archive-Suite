# Cheaper cloud models for segmentation (W41.seg-cheap)

Run 2026-10-13 through OpenRouter (`scripts/segbench/method_openrouter.py`, the `CHEAP` set). The request is the one `cues-models-Deaver.md` sent the cloud models: method_window_cues's prompt (the owner's cues and rules, with each page's Apple Vision text), the same 7-page windows, combining and assembly, the images at the bench's 1600 px. Reasoning at each model's lowest setting, temperature 0, the maker's own provider pinned where it serves the model (open builds: the provider and precision named). Prices are what OpenRouter charged per call; "batch" applies OpenRouter's `:batch` price (the maker's flex tier) to the same logged tokens and was not itself run. Item spend $2.57 (W41.seg-cheap), then $1.79 for the two remaining finalists on five boxes (W41.seg-cheap-more, 2026-10-14): $4.37 in all, against the $4.57 the owner approved.

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

Development boxes Dean, Deaver, Herrnstein; test boxes Stanton and RG 165, held out as `ensemble-test.md` held them. Gemini 3.8 Flash's cached windows (options.py's voter G) are scored the same way beside them, at no cost. The five-box run for all three was estimated at $2.87, an item total of $4.57, past the $3 line. So GLM-5.3 Flash ran first ($0.92 estimated, $0.88 paid). Luna and Qwen3.5 Flash followed on 2026-10-14, once the owner approved the extra cost (`W41.seg-cheap-more`): $1.53 and $0.42 estimated, $1.44 and $0.35 paid. Luna parsed every window. Qwen3.5 Flash failed to parse 5 of the 259 new windows (8 of 310 counting Deaver's), and each failed window votes 0.5 "new" on its gaps.

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
| GPT-5.6 Luna | Dean | 202 | 85.2% | 3 | 1.5 | 87.2% | 5 | |
| GPT-5.6 Luna | Deaver | 149 | 96.5% | 1 | 0.7 | 96.5% | 2 | |
| GPT-5.6 Luna | Herrnstein | 200 | 90.1% | 2 | 1.0 | 91.7% | 4 | |
| GPT-5.6 Luna | **dev pooled** | 551 | 90.0% | 6 | 1.1 | 91.3% | 11 | no |
| GPT-5.6 Luna | Stanton | 250 | 83.5% | 11 | 4.4 | 88.5% | 8 | |
| GPT-5.6 Luna | RG165 | 113 | 87.4% | 0 | 0.0 | 87.4% | 3 | |
| GPT-5.6 Luna | **test pooled** | 363 | 84.5% | 11 | 3.0 | 88.2% | 11 | no |
| Qwen3.5 Flash | Dean | 202 | 83.7% | 14 | 6.9 | 86.7% | 5 | |
| Qwen3.5 Flash | Deaver | 149 | 95.7% | 25 | 16.8 | 97.9% | 1 | |
| Qwen3.5 Flash | Herrnstein | 200 | 77.9% | 21 | 10.5 | 94.5% | 3 | |
| Qwen3.5 Flash | **dev pooled** | 551 | 84.9% | 60 | 10.9 | 92.5% | 9 | no |
| Qwen3.5 Flash | Stanton | 250 | 76.5% | 28 | 11.2 | 88.9% | 7 | |
| Qwen3.5 Flash | RG165 | 113 | 80.5% | 5 | 4.4 | 95.4% | 2 | |
| Qwen3.5 Flash | **test pooled** | 363 | 77.6% | 33 | 9.1 | 90.6% | 9 | no |

### The level fitted per model, as options.py did

0.85 was Claude's fitted level. Gemini and GLM give higher confidences and flag little at it, so neither reaches 99% there. Here each model gets its own level: held out per development box (fitted on the other two), and for the test boxes, fitted on all three. At the 98% bar Gemini's row reproduces `options.md` exactly, which checks this path.

| model | bar | dev, held out: after checking | flagged per 100 pages | level for the test boxes | test: no checking | after checking | flagged per 100 pages | unflagged errors |
|---|---|---:|---:|---|---:|---:|---:|---:|
| Gemini 3.8 Flash (low), the bar | 99% | 100.0% | 39.4 | <= 0.985 | 88.8% | 100.0% | 51.0 | 0 |
| Gemini 3.8 Flash (low), the bar | 98% | 98.6% | 10.3 | <= 0.965 | 88.8% | 100.0% | 24.2 | 0 |
| GLM-5.3 Flash | 99% | 99.4% | 60.1 | <= 0.975 | 82.1% | 100.0% | 81.0 | 0 |
| GLM-5.3 Flash | 98% | 97.3% | 17.1 | <= 0.925 | 82.1% | 98.5% | 33.1 | 1 |
| GPT-5.6 Luna | 99% | 100.0% | 86.0 | <= 0.990 | 84.5% | 100.0% | 86.2 | 0 |
| GPT-5.6 Luna | 98% | 98.8% | 60.8 | <= 0.990 | 84.5% | 100.0% | 86.2 | 0 |
| Qwen3.5 Flash | 99% | 99.6% | 69.5 | <= 0.975 | 77.6% | 100.0% | 82.4 | 0 |
| Qwen3.5 Flash | 98% | 99.6% | 55.0 | <= 0.950 | 77.6% | 100.0% | 55.9 | 0 |

| model | pages | calls | cost paid | per 1,000 pages, standard | per 1,000 pages, batch |
|---|---:|---:|---:|---:|---:|
| GLM-5.3 Flash | 914 | 313 | $1.056 | $1.16 | $0.46 |
| GPT-5.6 Luna | 914 | 310 | $1.741 | $1.90 | $0.78 |
| Qwen3.5 Flash | 914 | 337 | $0.436 | $0.48 | none offered |

## Verdict (2026-10-13)

**A cheaper model segments Deaver as well, but GLM-5.3 Flash does not hold up off it.** It matched Gemini 3.8 Flash on Deaver (97.9%) at about a third of the price ($1.16 against $3.61 per 1,000 pages at list; $0.46 against $1.81 at batch). Across the other four boxes it fell behind. On the test boxes it puts 82.1% of pages in the exact document with no checking, against Gemini's 88.8%, and its confidence ranks its own errors less well. Reaching 99% after checking costs 81 flagged boundaries per 100 test pages, against Gemini's 51. At the 98% bar it is 33 against 24, and it still lets one error through unflagged where Gemini lets none. Checking is the owner's time, and at the 98% bar about nine more boundaries per 100 pages outweighs a saving of $2.45 per 1,000 pages. So GLM-5.3 Flash is a budget option for a user who checks everything flagged, not a replacement for the Gemini default.

**A single screen box over-rewards.** The Deaver leader tied Gemini there, then fell 6.7 points behind it (no checking) on the held-out test boxes.

## Verdict on the other two finalists (2026-10-14, W41.seg-cheap-more)

**Neither GPT-5.6 Luna nor Qwen3.5 Flash holds up off Deaver either, so the answer to question 3 stands: no cheaper model replaces Gemini 3.8 Flash.** Both fall further behind on the test boxes than they did on Deaver.

- **GPT-5.6 Luna** ($1.90 per 1,000 pages at list, $0.78 at batch) puts 84.5% of test pages in the exact document with no checking, against Gemini's 88.8%. It costs nearly as much as Gemini at batch, and its confidences are the least useful of the four for review. They sit so high that the fitted level is 0.990 at both bars, which flags 86 boundaries per 100 test pages to reach 99% (Gemini: 51) and the same 86 at 98% (Gemini: 24). At option F's fixed 0.85 it flags only 3 per 100 and lets 11 errors through. It is worse than GLM-5.3 Flash on every measure here and costs more, so it is out.
- **Qwen3.5 Flash** ($0.48 per 1,000 pages, the cheapest, no batch price) has the lowest no-checking score: 77.6% on the test boxes, and 77.9% on Herrnstein, a development box. Checking rescues it. At the 98% bar it reaches 100% on the test boxes with 56 flagged per 100 pages, against Gemini's 24. That is about 32 more boundaries checked per 100 pages to save $3.13 per 1,000 pages against Gemini's list price, or $1.33 against its batch price. That is 320 more boundaries per 1,000 pages, for about a dollar or three. The owner's time costs more than that.

**So GLM-5.3 Flash remains the only budget option worth naming.** At the 98% bar it flags 33 per 100 test pages, against Qwen's 56 and Luna's 86, for $1.16 per 1,000 pages ($0.46 at batch). Gemini 3.8 Flash stays the default. All three finalists scored lower off Deaver, so a future cheap-model screen should rank on two development boxes at least, not on Deaver alone.

**The rest are out.** Gemini 3.5 Flash-Lite 85.1%, GPT-5.4 Nano 83.7%, Llama 4 Maverick 80.9% and Gemma 4 26B-A4B 73.8% each have six or more false splits on one box. GPT-5.4 Mini costs more per page than Gemini 3.8 Flash. Mistral Small could not be measured (rate-limited upstream).
