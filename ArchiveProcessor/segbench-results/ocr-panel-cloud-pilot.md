# W41.ocr-panel-cloud — three-page pilot

**Superseded (2026-10-15): the owner approved the full panel and it ran; results in [ocr-panel-cloud.md](ocr-panel-cloud.md).** This page is the pilot as it stood.

Owner authorization, 2026-10-15: three pages per route, well under $1, then ask again. **The full panel has not run and is not approved.**

Frozen pages: p010 (clipping), p062 (typescript/bullets), p086 (difficult handwriting). These are the local panel’s original, byte-identical JPEGs (2400 px ceiling) and owner-ruled transcription prompt. No ladder variants. p086 is agreement with the drafting models, not adjudicated accuracy. Two accuracy pages cannot establish a ranking.

## Measured calls and extrapolation

| route | endpoint / precision | completed / 3 | pilot cost | mean input / output / reasoning tokens | 99 pages, mean cost | 99 pages, worst pilot-page cost |
|---|---|---:|---:|---:|---:|---:|
| gemini3.1-pro | google-ai-studio / unpublished | 3 | $0.055694 | 1430/1309/584 | $1.838 | $3.311 |
| gemini3.5-flash | google-ai-studio / unpublished | 3 | $0.024913 | 1430/684/0 | $0.822 | $0.944 |
| gemini3.8-flash | google-ai-studio / unpublished | 3 | $0.011378 | 1430/725/0 | $0.375 | $0.456 |
| gemini3.5-flash-lite | google-ai-studio / unpublished | 3 | $0.006172 | 1430/651/0 | $0.204 | $0.243 |
| claude-sonnet5.5 | anthropic / unpublished | 3 | $0.058652 | 4530/1049/0 | $1.936 | $2.214 |
| gpt5.6-sol | openai / unpublished | 3 | $0.083226 | 2880/667/0 | $2.746 | $2.955 |
| gpt5.6-luna | openai / unpublished | 3 | $0.004700 | 2880/706/0 | $0.155 | $0.171 |
| gpt5.4-mini | openai / unpublished | 3 | $0.020803 | 2880/1061/399 | $0.686 | $1.084 |
| mistral-medium3.5 | mistral / unpublished | 3 | $0.025011 | 2348/642/0 | $0.825 | $0.952 |
| mistral-large4 | mistral / unpublished | 3 | $0.009048 | 2336/683/0 | $0.299 | $0.333 |
| qwen3.5-397b | deepinfra/fp8 / fp8 | 3 | $0.008437 | 1336/737/0 | $0.278 | $0.349 |
| qwen3-vl-235b | deepinfra/fp8 / fp8 | 3 | $0.004177 | 3856/706/0 | $0.138 | $0.161 |

Dedicated Mistral OCR not collected: 3 attempt(s) at the first page, each answered only by HTTP 429 `rate_limited` (nothing processed, nothing billed; the replies are kept in the private cache). Add $0.396 for 99 single-page calls.

**Pilot accounted: $0.312211 / $0.75 combined ceiling; outstanding reservations $0.000000.**
Dedicated Mistral OCR did not complete (see above), so its row is at the published $4/1000 pages, not measured. Full 99-original panel (all twelve chat models measured, plus that dedicated OCR row), mean-cost extrapolation: **$10.70**; using each chat route’s dearest pilot page: **$13.57**. A further 50% planning buffer on the mean gives **$16.05**. These are sample estimates, not guaranteed prices or authorization. No retries, resolution ladder, batch discount, or corpus-wide extrapolation is included. Three deliberately varied pages are not a random cost sample.

Pilot collection complete: **no** (paid failed responses count as attempted, never as successful readings).

## Scores (diagnostic only)

| route | two adjudicated pages: completed | NES % | chrF2 % | words missed % | words added % | p086 agreement NES % |
|---|---:|---:|---:|---:|---:|---:|
| gemini3.1-pro | 2/2 | 99.32 | 99.56 | 0.18 | 0.09 | 91.34 |
| gemini3.5-flash | 2/2 | 98.11 | 98.32 | 2.82 | 1.41 | 87.95 |
| gemini3.8-flash | 2/2 | 99.30 | 99.51 | 0.09 | 0.09 | 90.94 |
| gemini3.5-flash-lite | 2/2 | 97.97 | 98.03 | 4.23 | 2.11 | 85.83 |
| claude-sonnet5.5 | 2/2 | 97.25 | 98.02 | 1.14 | 0.35 | 89.10 |
| gpt5.6-sol | 2/2 | 91.77 | 93.35 | 6.87 | 0.26 | 82.39 |
| gpt5.6-luna | 2/2 | 85.15 | 97.08 | 2.99 | 2.11 | 69.54 |
| gpt5.4-mini | 2/2 | 97.45 | 96.89 | 4.93 | 3.79 | 74.87 |
| mistral-medium3.5 | 2/2 | 65.22 | 90.02 | 12.94 | 7.48 | 79.80 |
| mistral-large4 | 2/2 | 97.72 | 97.82 | 3.35 | 2.38 | 85.60 |
| qwen3.5-397b | 2/2 | 97.94 | 98.87 | 0.62 | 1.32 | 82.96 |
| qwen3-vl-235b | 2/2 | 98.94 | 99.11 | 0.62 | 0.18 | 85.89 |

Scoring is exactly the [local panel’s normalization, NES, SacreBLEU chrF2, and multiset word rates](ocr-panel-local.md#scoring-and-limits). Failed readings score empty. All attribute and resolution comparisons wait for the approved full panel; the pilot cannot answer Question 2.

## Reproduction and spending controls

`ocr_cloud.py prepare`, `ocr_cloud.py pilot`, `ocr_cloud_mistral.py <compiled-driver>`, `ocr_cloud.py report`. Default private cache `/tmp/w41-ocr-panel-cloud/`; set `OCR_CLOUD_CACHE` to preserve it elsewhere. Frozen truth and local image cache are read only. The manifest permits exactly three originals; there is no full-run command. Requests are serial, provider-pinned, fallbacks disabled, max 8192 output tokens; failures are never repurchased. Unknown network/billing outcomes retain their full write-ahead reservations and block continuation.

Gemini 3.1 Pro/3.8 Flash and Claude Sonnet 5.5 request low reasoning (Claude’s endpoint refused reasoning off with a free HTTP 400, so it was re-run at low; its usage reports 0 reasoning tokens, so any thinking is inside the billed output count); Gemini 3.5 Flash/Flash-Lite and GPT-5.4 Mini request minimal; the other reasoning-capable routes request off; Qwen3-VL Instruct has none. Temperature is zero except Claude/OpenAI, whose catalog does not advertise it; it is omitted there. OpenAI detail is explicitly high. Actual reasoning tokens above show whether the providers still used internal tokens.

Input reservations for Google/Anthropic/OpenAI are 32768 tokens for one image plus the short prompt, far above documented visual tiers: [Gemini up to 2240 (approximate table)](https://ai.google.dev/gemini-api/docs/media-resolution), [Claude 4784](https://platform.claude.com/docs/en/build-with-claude/vision), [the three OpenAI models at high detail, 2500 patches ×1.2](https://developers.openai.com/api/docs/guides/images-vision). The runner stops if measured input exceeds that bound. Mistral and Qwen reserve their entire endpoint context; published applicable price tiers are included. The largest reservation runs first (Mistral Large, $0.730153), and settles before the next call. $0.012 is held separately for OCR.

Prices/providers frozen from the [OpenRouter endpoint catalog](https://openrouter.ai/api/v1/models) on 2026-10-15; full snapshots in the private cache. [Mistral OCR pricing](https://docs.mistral.ai/inference/pricing): $4/1000 pages standard; batch is not used.
