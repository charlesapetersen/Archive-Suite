# W41.ocr-panel-cloud — the cloud panel on the truth set

Question 2 of the W41 bake-off: how the paid and subscription leaders read the 99 frozen truth pages, with the [local panel](ocr-panel-local.md)’s images, prompt and scoring unchanged. Owner approval, second walkthrough 2026-10-15: the full panel, with Claude and OpenAI on the subscriptions, a $9 paid cap on top of the $0.312 pilot ([pilot report](ocr-panel-cloud-pilot.md)).

**Item spend: $5.798787** of the $9.31 item cap: the pilot’s $0.312211, $5.090576 of OpenRouter calls in the full run, and $0.396 of Mistral OCR (99 pages at the published $4/1000). Outstanding reservations $0.000000. The owner’s own interactive Mistral check (one synthetic page, about $0.004) is outside this ledger.

## Findings

- Highest on the 96 accuracy pages: **claude-sonnet5.5** (96.47 NES, subscription route).
- Best paid route: **gemini3.1-pro**, 94.85 NES at $0.02192 a page. Cheapest paid route within 1.5 points of it: **qwen3-vl-235b**, 93.95 at $0.00122.
- Best open-weight route (the FarmShare-scale ceiling): **qwen3.5-397b**, 93.98 NES at $0.00202 a page, against the local panel’s best, qwen3.6-27b, at 94.28.
- The spread among the paid leaders is about two points on one corpus of 96 pages; the truth leans toward Gemini 3.8 Flash and Claude (its drafters), so read the order of close rows as provisional.

## Routes

- **OpenRouter** (paid): one pinned endpoint and precision per row, fallbacks off, the pilot’s settings (reasoning off or the lowest the endpoint accepts, temperature 0 where advertised, OpenAI image detail high). The pilot’s three pages are reused, not bought again.
- **Claude Sonnet 5.5 through `claude -p`** (Claude subscription, no money): Claude Code’s own harness and system prompt; the image is a file the model opens with the Read tool, which may resize it; no temperature or effort setting. One reading per page; a harness error with no answer is tried once more.
- **GPT-5.6 Sol and Luna through `codex exec`** were the plan (Codex offers both, at lowest effort low; it does not offer GPT-5.4 Mini, which stayed on OpenRouter). On the first full-run call Codex answered “Your workspace is out of credits”. As the owner ruled, **Luna fell back to OpenRouter** with the pilot’s route, and **Sol, which runs only by subscription, is dropped**.
- **Mistral OCR 4.1** through the app’s own `MistralClient`, `ImageEncoding` and `NetworkSession`, compiled into a headless driver: no panel prompt, the app’s 2048 px / JPEG 0.85 encoding, and its reply as the app receives it, which is Markdown (`#` headings, `|` tables); the scoring removes table bars but not other Markdown. It returns no kind label.

## Scoring and limits

The local panel’s [normalization, NES, chrF2 and word rates](ocr-panel-local.md#scoring-and-limits), unchanged. 96 pages in the accuracy table; the three Michael Young letters are agreement with the drafters, not accuracy. **The truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash, then adjudicated**, so it can lean toward those models’ families, Gemini 3.8 Flash itself most of all. Failed readings score empty. One corpus, about 100 pages: differences of a point or two are not a ranking.

## Original pages (96, excluding the agreement-only letters)

| route | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | kind right % | cost / page |
|---|---:|---:|---:|---:|---:|---:|---:|
| claude-sonnet5.5 · `claude -p`, subscription | 96/96/96 | 96.47 | 97.93 | 0.72 | 1.02 | 96 | subscription |
| gemini3.1-pro · OpenRouter google-ai-studio | 94/96/96 | 94.85 | 95.85 | 3.02 | 0.95 | 95 | $0.02192 |
| gemini3.8-flash · OpenRouter google-ai-studio | 94/96/96 | 94.47 | 95.96 | 2.99 | 1.12 | 93 | $0.00322 |
| qwen3.5-397b · OpenRouter deepinfra/fp8 | 96/96/96 | 93.98 | 95.82 | 2.10 | 2.68 | 89 | $0.00202 |
| qwen3-vl-235b · OpenRouter deepinfra/fp8 | 96/96/96 | 93.95 | 96.08 | 2.40 | 2.43 | 98 | $0.00122 |
| gpt5.4-mini · OpenRouter openai | 95/96/96 | 93.55 | 93.96 | 3.56 | 1.93 | 85 | $0.00555 |
| gemini3.5-flash · OpenRouter google-ai-studio | 94/96/96 | 93.48 | 94.52 | 4.08 | 2.98 | 95 | $0.00623 |
| mistral-large4 · OpenRouter mistral | 96/96/96 | 93.15 | 95.83 | 3.16 | 3.57 | 91 | $0.00269 |
| gemini3.5-flash-lite · OpenRouter google-ai-studio | 94/96/96 | 93.13 | 94.85 | 4.38 | 2.09 | 82 | $0.00157 |
| mistral-ocr-4-1 · Mistral OCR API, app client | 96/96/96 | 92.91 | 94.50 | 4.07 | 4.09 | — | $0.00400 |
| gpt5.6-luna · OpenRouter openai | 95/96/96 | 92.13 | 93.21 | 4.80 | 2.73 | 73 | $0.00141 |
| mistral-medium3.5 · OpenRouter mistral | 96/96/96 | 90.65 | 92.56 | 5.60 | 5.13 | 94 | $0.00729 |

The local panel on the same 96 pages, for comparison (its own report has the detail):

| local-panel route | completed / 96 | NES % | chrF2 % | words missed % | words added % |
|---|---:|---:|---:|---:|---:|
| qwen3.6-27b | 95/96 | 94.28 | 95.55 | 3.36 | 2.73 |
| qwen3.6-35b-a3b | 96/96 | 93.02 | 95.65 | 2.07 | 3.82 |
| qwen3-vl-8b | 94/96 | 91.81 | 93.33 | 3.65 | 2.62 |
| gemini3.1-flash-lite | 93/96 | 91.61 | 93.68 | 4.70 | 2.54 |
| qwen3.5-35b-a3b | 94/96 | 90.83 | 93.61 | 3.91 | 3.30 |
| gemma4-31b | 93/96 | 90.55 | 91.51 | 7.72 | 4.61 |
| qwen3-vl-30b-a3b | 94/96 | 89.82 | 92.68 | 5.78 | 3.40 |
| qwen3.5-9b | 92/96 | 89.43 | 91.32 | 9.42 | 3.26 |
| mistral-small-24b | 94/96 | 89.34 | 90.86 | 6.16 | 4.00 |
| gemma4-26b-a4b | 86/96 | 82.73 | 84.41 | 19.64 | 3.74 |
| qwen3.5-27b | 82/96 | 81.80 | 82.61 | 15.39 | 1.72 |
| apple-vision | 96/96 | 81.34 | 82.50 | 11.20 | 7.79 |

## Completed readings only, and the agreement-only letters

| route | completed / 96 | NES % (completed) | agreement letters NES % (completed / 3) |
|---|---:|---:|---:|
| claude-sonnet5.5 | 96/96 | 96.47 | 77.80 (3/3) |
| gemini3.1-pro | 94/96 | 96.86 | 83.04 (3/3) |
| gemini3.8-flash | 94/96 | 96.48 | 83.03 (3/3) |
| qwen3.5-397b | 96/96 | 93.98 | 73.61 (3/3) |
| qwen3-vl-235b | 96/96 | 93.95 | 75.60 (3/3) |
| gpt5.4-mini | 95/96 | 94.53 | 54.90 (3/3) |
| gemini3.5-flash | 94/96 | 95.47 | 78.70 (3/3) |
| mistral-large4 | 96/96 | 93.15 | 65.28 (3/3) |
| gemini3.5-flash-lite | 94/96 | 95.11 | 78.18 (3/3) |
| mistral-ocr-4-1 | 96/96 | 92.91 | 72.39 (3/3) |
| gpt5.6-luna | 95/96 | 93.10 | 31.85 (2/3) |
| mistral-medium3.5 | 96/96 | 90.65 | 46.51 (3/3) |

## Measured paid calls (full run, pilot pages reused)

| route | calls bought in the full run | failures | full-run cost | mean input / output / reasoning tokens |
|---|---:|---:|---:|---:|
| gemini3.1-pro | 96 | 2 | $2.1147 | 1404/1602/1145 |
| gemini3.5-flash | 96 | 2 | $0.5923 | 1404/452/0 |
| gemini3.8-flash | 96 | 2 | $0.3076 | 1404/574/117 |
| gemini3.5-flash-lite | 96 | 2 | $0.1491 | 1404/453/0 |
| gpt5.4-mini | 96 | 1 | $0.5291 | 3072/713/265 |
| mistral-medium3.5 | 96 | 0 | $0.6967 | 2624/443/0 |
| mistral-large4 | 96 | 0 | $0.2577 | 2612/435/0 |
| qwen3.5-397b | 96 | 0 | $0.1918 | 1337/466/0 |
| qwen3-vl-235b | 96 | 0 | $0.1168 | 4099/451/0 |
| gpt5.6-luna | 96 | 2 | $0.1347 | 3072/530/0 |

claude-sonnet5.5 through `claude -p`: 99 pages, 0 harness retries, mean 47907 input tokens (Claude Code’s system prompt and tools included, mostly cached) and 816 output tokens a page, mean 10 s a page at three at once. Subscription usage, not money.

Mistral OCR: 99/99 pages returned text.

Per-attribute scores (collection, period, kind, table/form, camera, tertiles, every tag; overlapping, small groups descriptive only): [ocr-panel-cloud-groups.csv](ocr-panel-cloud-groups.csv).

## Reproduction

`ocr_cloud_full.py prepare`, `ocr_cloud_mistral.py --full <driver>`, `ocr_cloud_full.py paid`, `ocr_cloud_full.py sub <route>`, `ocr_cloud_full.py report`. Private cache `~/Library/Caches/ArchiveSuiteRehearsal/ocr-panel-cloud/` (images, ledger, replies, page scores). The pilot’s spending controls hold: write-ahead reservations, pinned providers, no paid retries, the OCR reserve held apart, an uncertain outcome blocks continuation.
