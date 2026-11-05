# W41.ocr-panel-local — results

Reproduce: `ocr_panel.py prepare`, `collect --probe`, `collect`, `vision` (under the heavy lock), then `ocr_panel_score.py`. Inputs, catalogs, raw responses, reservations and page scores: `~/Library/Caches/ArchiveSuiteRehearsal/ocr-panel-local/` (outside git).

**Apple Vision is its macOS 27.2 reading (regenerated 2026-11-04, W46.vision-27-swap; `vision-27-reread.md`).** The 26.6 reading of 2026-10-14 is kept as `vision-26.6/`. On the 96 Vision moved 81.37 to 83.07 NES, but its half-size copies fell (79.48 to 73.23) and its quarter-size ones too (52.69 to 50.39), so its downscale figures change most; no other route moved.

Conservative OpenRouter budget accounting, every attempt: **$1.533384 / $2.00 cap**. Each row pins one endpoint and precision; temperature 0, reasoning off (Flash-Lite minimal; the VL Instruct/Mistral endpoints have no reasoning control). No paid retries.

## Scoring and limits

99 settled originals, 96 in the accuracy table below. p038 excluded by the owner. The three Michael Young letters p086/p094/p096 are shown separately as **agreement with Claude/Gemini**, not measured accuracy. The truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash, then adjudicated; agreements the owner's later blind checks did not reach can still favor those models (measurement card).

NES is 1 − character Levenshtein/max(lengths), as [socOCRbench](https://noahdasanaike.github.io/posts/sococrbench.html) defines it. chrF uses [SacreBLEU 2.5.1](https://github.com/mjpost/sacrebleu/tree/v2.5.1), character orders 1–6, beta 2, no word n-grams or whitespace, case preserved, effective orders. The benchmark does not publish its exact chrF/normalization settings; these explicit settings are our reproduction choice. NES/chrF are per-page means; word rates pool counts, as Vision OCR does.

Normalization: NFKC, straight quotes/dashes, whitespace collapsed, table bars removed; spelling and case retained. “•”, “*” and a leading standalone “-” count as a bullet. Other dashes remain. `[illegible]` is literal in NES/chrF (agreement on the marker, not proof of reading the hidden word). For word rates it is removed from both sides. Words use Vision OCR’s lowercase/alphanumeric whitespace tokenizer and multiset intersection: missed=(truth−matched)/truth, added=(reading−matched)/truth. These rates ignore order and punctuation; unlike NES they do not detect column reordering. A real reading at an unknown truth span can count as added, so additions there are an upper bound. All substantive handwriting is included here; Vision OCR’s lab excludes its separately annotated hand/figure/contested spans, which this truth set does not label. Direct cross-corpus score comparisons would be invalid.

Failed responses score as empty (NES/chrF 0, all words missed); missing inputs also score empty and are counted as not attempted. A panel with missing inputs is incomplete, not a finished model comparison. Kind labels do not choose the scoring groups: the owner’s truth-table labels do.

Every source is converted to JPEG quality 90 and capped at 2400 pixels on its long side for every route, Vision included. Ladder half/quarter images are fractions of the **native source**, independently capped at 2400; they are not always half/quarter of the capped original. Actual input dimensions are in private `scores.csv`. Only 20 matched pages have ladder variants; compare them to their own originals, not to the other 79 pages. This measures photo downsampling plus each provider’s own visual token budget. No local quantization or throughput was measured.

## Original pages (96, excluding the agreement-only letters)

| model | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | cost/original |
|---|---:|---:|---:|---:|---:|---:|
| qwen3.5-9b | 92/96/96 | 89.44 | 91.37 | 9.40 | 3.26 | $0.000250 |
| qwen3.5-27b | 82/96/96 | 81.83 | 82.68 | 15.37 | 1.72 | $0.001796 |
| qwen3.5-35b-a3b | 94/96/96 | 90.85 | 93.65 | 3.89 | 3.30 | $0.000829 |
| qwen3.6-27b | 95/96/96 | 94.35 | 95.68 | 3.32 | 2.72 | $0.001940 |
| qwen3.6-35b-a3b | 96/96/96 | 93.02 | 95.68 | 2.04 | 3.82 | $0.000599 |
| gemma4-26b-a4b | 86/96/96 | 82.75 | 84.45 | 19.63 | 3.74 | $0.000412 |
| gemma4-31b | 93/96/96 | 90.57 | 91.54 | 7.71 | 4.62 | $0.000379 |
| qwen3-vl-8b | 94/96/96 | 91.83 | 93.37 | 3.63 | 2.63 | $0.001492 |
| qwen3-vl-30b-a3b | 94/96/96 | 89.84 | 92.70 | 5.76 | 3.41 | $0.000984 |
| mistral-small-24b | 94/96/96 | 89.36 | 90.86 | 6.14 | 4.00 | $0.000316 |
| gemini3.1-flash-lite | 93/96/96 | 91.59 | 93.65 | 4.70 | 2.56 | $0.001168 |
| apple-vision | 96/96/96 | 83.07 | 83.87 | 9.82 | 6.30 | $0.000000 |

## Completed original responses only (coverage differs)

These conditional scores diagnose transcription quality apart from response failures. Compare the coverage above; a small or selective successful subset can flatter a route.

| model | completed / 96 | NES % | chrF2 % | missed % | added % |
|---|---:|---:|---:|---:|---:|
| qwen3.5-9b | 92/96 | 93.33 | 95.34 | 3.07 | 3.49 |
| qwen3.5-27b | 82/96 | 95.80 | 96.79 | 2.43 | 1.98 |
| qwen3.5-35b-a3b | 94/96 | 92.78 | 95.65 | 2.31 | 3.35 |
| qwen3.6-27b | 95/96 | 95.34 | 96.68 | 2.86 | 2.73 |
| qwen3.6-35b-a3b | 96/96 | 93.02 | 95.68 | 2.04 | 3.82 |
| gemma4-26b-a4b | 86/96 | 92.38 | 94.26 | 3.91 | 4.48 |
| gemma4-31b | 93/96 | 93.49 | 94.49 | 4.32 | 4.79 |
| qwen3-vl-8b | 94/96 | 93.79 | 95.36 | 2.28 | 2.66 |
| qwen3-vl-30b-a3b | 94/96 | 91.75 | 94.67 | 3.14 | 3.51 |
| mistral-small-24b | 94/96 | 91.26 | 92.79 | 5.01 | 4.05 |
| gemini3.1-flash-lite | 93/96 | 94.54 | 96.67 | 1.66 | 2.64 |
| apple-vision | 96/96 | 83.07 | 83.87 | 9.82 | 6.30 |

## All 99 pages, agreement-only letters, and the matched ladder

| model | subset | completed / n | NES % | chrF2 % | missed % | added % |
|---|---|---:|---:|---:|---:|---:|
| qwen3.5-9b | all-99 | 95/99 | 88.85 | 90.37 | 9.65 | 3.84 |
| qwen3.5-9b | agreement-only | 3/3 | 69.85 | 58.65 | 21.31 | 31.10 |
| qwen3.5-9b | ladder-original | 19/20 | 89.24 | 90.74 | 7.66 | 3.46 |
| qwen3.5-9b | ladder-half | 19/20 | 89.78 | 90.91 | 10.02 | 3.34 |
| qwen3.5-9b | ladder-quarter | 15/20 | 69.13 | 69.43 | 45.15 | 2.09 |
| qwen3.5-27b | all-99 | 85/99 | 81.65 | 82.18 | 15.35 | 2.26 |
| qwen3.5-27b | agreement-only | 3/3 | 75.79 | 66.14 | 14.62 | 27.22 |
| qwen3.5-27b | ladder-original | 18/20 | 85.45 | 87.37 | 8.86 | 2.46 |
| qwen3.5-27b | ladder-half | 19/20 | 93.51 | 93.35 | 5.32 | 2.94 |
| qwen3.5-27b | ladder-quarter | 13/20 | 58.27 | 58.35 | 46.69 | 7.16 |
| qwen3.5-35b-a3b | all-99 | 97/99 | 90.25 | 92.66 | 4.16 | 3.85 |
| qwen3.5-35b-a3b | agreement-only | 3/3 | 71.25 | 61.01 | 16.95 | 29.55 |
| qwen3.5-35b-a3b | ladder-original | 20/20 | 95.02 | 96.98 | 2.26 | 2.88 |
| qwen3.5-35b-a3b | ladder-half | 20/20 | 94.84 | 96.50 | 3.06 | 3.48 |
| qwen3.5-35b-a3b | ladder-quarter | 16/20 | 72.32 | 72.96 | 38.16 | 4.75 |
| qwen3.6-27b | all-99 | 98/99 | 93.65 | 94.69 | 3.61 | 3.21 |
| qwen3.6-27b | agreement-only | 3/3 | 71.28 | 62.96 | 16.80 | 26.28 |
| qwen3.6-27b | ladder-original | 20/20 | 96.05 | 97.37 | 2.12 | 2.64 |
| qwen3.6-27b | ladder-half | 20/20 | 95.32 | 96.55 | 3.16 | 3.56 |
| qwen3.6-27b | ladder-quarter | 17/20 | 71.70 | 73.86 | 36.56 | 7.73 |
| qwen3.6-35b-a3b | all-99 | 99/99 | 92.40 | 94.65 | 2.37 | 4.34 |
| qwen3.6-35b-a3b | agreement-only | 3/3 | 72.27 | 61.80 | 17.57 | 28.77 |
| qwen3.6-35b-a3b | ladder-original | 20/20 | 94.77 | 96.96 | 1.77 | 2.98 |
| qwen3.6-35b-a3b | ladder-half | 20/20 | 94.88 | 96.59 | 2.32 | 2.96 |
| qwen3.6-35b-a3b | ladder-quarter | 15/20 | 68.97 | 69.44 | 45.27 | 2.71 |
| gemma4-26b-a4b | all-99 | 88/99 | 81.63 | 83.15 | 20.35 | 4.00 |
| gemma4-26b-a4b | agreement-only | 2/3 | 45.80 | 41.67 | 53.97 | 16.17 |
| gemma4-26b-a4b | ladder-original | 16/20 | 77.83 | 77.85 | 29.82 | 2.16 |
| gemma4-26b-a4b | ladder-half | 18/20 | 84.85 | 86.39 | 21.27 | 3.63 |
| gemma4-26b-a4b | ladder-quarter | 17/20 | 81.89 | 81.94 | 24.41 | 3.56 |
| gemma4-31b | all-99 | 96/99 | 89.92 | 90.50 | 8.09 | 5.29 |
| gemma4-31b | agreement-only | 3/3 | 69.10 | 57.33 | 25.82 | 36.55 |
| gemma4-31b | ladder-original | 19/20 | 90.27 | 90.84 | 15.42 | 4.28 |
| gemma4-31b | ladder-half | 20/20 | 92.59 | 94.14 | 7.44 | 7.06 |
| gemma4-31b | ladder-quarter | 19/20 | 86.02 | 88.59 | 12.74 | 8.81 |
| qwen3-vl-8b | all-99 | 97/99 | 91.28 | 92.43 | 3.89 | 3.17 |
| qwen3-vl-8b | agreement-only | 3/3 | 73.70 | 62.32 | 16.02 | 28.30 |
| qwen3-vl-8b | ladder-original | 20/20 | 95.14 | 97.23 | 1.72 | 2.44 |
| qwen3-vl-8b | ladder-half | 20/20 | 93.36 | 95.90 | 2.73 | 3.38 |
| qwen3-vl-8b | ladder-quarter | 14/20 | 66.74 | 66.44 | 47.42 | 1.69 |
| qwen3-vl-30b-a3b | all-99 | 97/99 | 88.98 | 91.48 | 6.16 | 3.90 |
| qwen3-vl-30b-a3b | agreement-only | 3/3 | 61.34 | 52.59 | 24.88 | 26.75 |
| qwen3-vl-30b-a3b | ladder-original | 19/20 | 89.61 | 91.65 | 13.55 | 2.42 |
| qwen3-vl-30b-a3b | ladder-half | 20/20 | 93.07 | 95.37 | 3.90 | 3.11 |
| qwen3-vl-30b-a3b | ladder-quarter | 14/20 | 64.46 | 64.58 | 41.27 | 3.88 |
| mistral-small-24b | all-99 | 96/99 | 87.92 | 89.14 | 7.16 | 4.34 |
| mistral-small-24b | agreement-only | 2/3 | 41.92 | 34.05 | 55.05 | 20.06 |
| mistral-small-24b | ladder-original | 20/20 | 91.68 | 94.33 | 6.92 | 4.25 |
| mistral-small-24b | ladder-half | 20/20 | 90.54 | 93.56 | 7.96 | 6.24 |
| mistral-small-24b | ladder-quarter | 16/20 | 62.96 | 67.09 | 46.45 | 11.12 |
| gemini3.1-flash-lite | all-99 | 96/99 | 91.23 | 92.97 | 4.78 | 2.93 |
| gemini3.1-flash-lite | agreement-only | 3/3 | 79.70 | 71.06 | 8.55 | 20.37 |
| gemini3.1-flash-lite | ladder-original | 20/20 | 95.69 | 97.06 | 1.09 | 2.26 |
| gemini3.1-flash-lite | ladder-half | 19/20 | 90.70 | 91.99 | 7.79 | 2.84 |
| gemini3.1-flash-lite | ladder-quarter | 19/20 | 89.74 | 91.51 | 8.08 | 3.80 |
| apple-vision | all-99 | 99/99 | 81.54 | 81.85 | 11.29 | 7.12 |
| apple-vision | agreement-only | 3/3 | 32.39 | 17.33 | 79.78 | 45.10 |
| apple-vision | ladder-original | 20/20 | 79.61 | 86.20 | 11.61 | 5.94 |
| apple-vision | ladder-half | 20/20 | 73.23 | 80.01 | 20.37 | 7.58 |
| apple-vision | ladder-quarter | 20/20 | 50.39 | 51.85 | 58.63 | 7.06 |

The [attribute table](ocr-panel-local-groups.csv) includes collection, source, historical period, owner-confirmed kind, tag strata, table/form flag, camera, capture year, pixel/sharpness/year tertiles, ladder membership and every tag (overlapping groups). Small groups are descriptive, not reliable rankings. Page/folder/file identity fields are private; the per-page table allows any further grouping.

## Pinned routes and measured costs


5 explicit empty provider errors are accounted at $0 under [OpenRouter’s zero-completion insurance](https://openrouter.ai/blog/announcements/never-pay-for-empty-ai-responses-again/). These are policy-covered failures, not successful free readings; raw error bodies are saved.

**Billing uncertainty:** 11 provider errors or interrupted calls had no usable billing record. 2 generation lookups returned 404; other failures had no retained generation ID. Reported charges are $1.516543; an additional $0.016841 (11 bounded by the API key’s own billing for the UTC day, which exceeded the measured charges by at most $0.001531; each such call carries that whole difference) is counted as a conservative ceiling against the cap. Cost columns include these ceilings and are not all measured charges. These failed calls are cached and never retried. Raw errors and lookup evidence remain in the private cache.

| model | endpoint | precision | accounted calls | failures | $/call (charges + uncertain ceilings) | mean input/output tokens |
|---|---|---|---:|---:|---:|---:|
| qwen3.5-9b | deepinfra/bf16 | bf16 | 139 | 10 | $0.000264 | 1228/979 |
| qwen3.5-27b | siliconflow/fp8 | fp8 | 139 | 22 | $0.001954 | 2983/560 |
| qwen3.5-35b-a3b | deepinfra/fp8 | fp8 | 139 | 6 | $0.000973 | 1229/801 |
| qwen3.6-27b | chutes/fp8 | fp8 | 139 | 4 | $0.002055 | 3265/614 |
| qwen3.6-35b-a3b | deepinfra/fp8 | fp8 | 139 | 5 | $0.000836 | 1228/751 |
| gemma4-26b-a4b | dekallm/bf16 | bf16 | 139 | 16 | $0.000432 | 649/1168 |
| gemma4-31b | crusoe/bf16 | bf16 | 139 | 4 | $0.000357 | 632/643 |
| qwen3-vl-8b | parasail/bf16 | bf16 | 139 | 8 | $0.001496 | 3281/901 |
| qwen3-vl-30b-a3b | deepinfra/fp8 | fp8 | 139 | 8 | $0.001030 | 3281/897 |
| mistral-small-24b | deepinfra/fp8 | fp8 | 139 | 7 | $0.000334 | 2256/826 |
| gemini3.1-flash-lite | google-ai-studio | unpublished | 139 | 5 | $0.001301 | 1413/631 |

Routes/prices were frozen from [OpenRouter’s endpoint catalog](https://openrouter.ai/api/v1/models); [provider routing](https://openrouter.ai/docs/guides/routing/provider-selection) disables fallbacks and filters precision. Provider-reported precision is not an audit of its weights. Hosted latency is not Mac inference speed.

## Local memory: estimates, not tested fits

Weight floors use the makers’ total safetensors counts (vision/MTP included where published), not MoE active counts: parameters × bits / 8 / 2³⁰. Planning totals below = weight floor ×1.15 + 4 GiB runtime +4 GiB OS. This is a stated heuristic for one short page at a time; quantization scales, full-precision layers, images and KV/context can exceed it. “Fits” below means only that heuristic clears the installed memory; validate the actual build before recommending it.

| model | Q4/Q8 weight GiB | Q4/Q8 planning GiB | estimated Q4 Macs | estimated Q8 Macs |
|---|---:|---:|---|---|
| [qwen3.5-9b](https://huggingface.co/Qwen/Qwen3.5-9B) | 4.50/8.99 | 13.17/18.34 | 18, 32, 48, 64 | 32, 48, 64 |
| [qwen3.5-27b](https://huggingface.co/Qwen/Qwen3.5-27B) | 12.94/25.87 | 22.88/37.75 | 32, 48, 64 | 48, 64 |
| [qwen3.5-35b-a3b](https://huggingface.co/Qwen/Qwen3.5-35B-A3B) | 16.74/33.48 | 27.25/46.51 | 32, 48, 64 | 48, 64 |
| [qwen3.6-27b](https://huggingface.co/Qwen/Qwen3.6-27B) | 12.94/25.87 | 22.88/37.75 | 32, 48, 64 | 48, 64 |
| [qwen3.6-35b-a3b](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) | 16.74/33.48 | 27.25/46.51 | 32, 48, 64 | 48, 64 |
| [gemma4-26b-a4b](https://huggingface.co/google/gemma-4-26B-A4B-it) | 12.02/24.03 | 21.82/35.64 | 32, 48, 64 | 48, 64 |
| [gemma4-31b](https://huggingface.co/google/gemma-4-31B-it) | 14.56/29.13 | 24.75/41.49 | 32, 48, 64 | 48, 64 |
| [qwen3-vl-8b](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct) | 4.08/8.17 | 12.69/17.39 | 18, 32, 48, 64 | 18, 32, 48, 64 |
| [qwen3-vl-30b-a3b](https://huggingface.co/Qwen/Qwen3-VL-30B-A3B-Instruct) | 14.47/28.94 | 24.64/41.28 | 32, 48, 64 | 48, 64 |
| [mistral-small-24b](https://huggingface.co/mistralai/Mistral-Small-3.2-24B-Instruct-2506) | 11.18/22.36 | 20.86/33.72 | 32, 48, 64 | 48, 64 |

18 GiB: 8–9B Q4 is the conservative candidate; VL-8B Q8 is marginal by this estimate and Qwen9B Q8 exceeds it. 32 GiB: every listed model is a Q4 candidate; larger Q8 builds need 48 GiB. 48/64 GiB: all listed Q8 builds clear this estimate. No precision-specific accuracy claim follows: OpenRouter’s bf16/fp8 quality is **not measured Mac Q4 quality**.

Vision OCR’s separate lab has Qwen3-VL-8B MLX4 results (65 newspaper pages; whole-page peak about 9.7 GB) and an abandoned Qwen3.5-9B run (8 whole/6 crop readings). They use different images and scoring masks, so they provide no matched hosted-vs-Q4 comparison and cannot quantify a quantization penalty. Source: read-only `vision-ocr/OCR-BAKEOFF-2026-10-07.tsv` and `ops/ocrlab/score-bakeoff.py`.

## Cloud-panel estimate for the owner (no cloud-panel calls made)

Completed original-page routes average 636–4104 input and 443–485 output tokens/page. The range below applies these measured extremes to the current listed prices, **not** a measurement of the cloud models’ tokenizers. Image token budgets and reasoning can change it. The high figure adds a 50% retry/tokenization buffer. Pin actual providers and re-estimate from a three-page pilot before committing the rest. Twelve chat models, 99 originals each; no ladder variants in this estimate.

| cloud model | listed $/M input/output | 99 pages, low proxy | 99 pages, high proxy +50% |
|---|---:|---:|---:|
| google/gemini-3.1-pro-preview | 2/12 | $0.65 | $2.08 |
| google/gemini-3.5-flash | 1.5/9 | $0.49 | $1.56 |
| google/gemini-3.8-flash | 0.75/3.75 | $0.21 | $0.73 |
| google/gemini-3.5-flash-lite | 0.3/2.5 | $0.13 | $0.36 |
| anthropic/claude-sonnet-5.5 | 2/10 | $0.56 | $1.94 |
| openai/gpt-5.6-sol | 4/20 | $1.13 | $3.88 |
| openai/gpt-5.6-luna | 0.2/1.2 | $0.07 | $0.21 |
| openai/gpt-5.4-mini | 0.75/4.5 | $0.24 | $0.78 |
| mistralai/mistral-medium-3-5 | 1.5/7.5 | $0.42 | $1.45 |
| mistralai/mistral-large-4-0 | 0.68/2.09 | $0.13 | $0.56 |
| qwen/qwen3.5-397b-a17b | 0.5/3.6 | $0.19 | $0.56 |
| qwen/qwen3-vl-235b-a22b-instruct | 0.21/1.9 | $0.10 | $0.26 |

**Total chat-panel proxy: $4.33–$14.39.** Mistral’s dedicated OCR endpoint is additional and needs its own key and current per-page price check. Its 99 pages and any ladder extension must be added before approval. The existing `W41.ocr-panel-cloud-owner-ok` gate remains open; this is an estimate, not authorization to spend. Prices: [OpenRouter model catalog](https://openrouter.ai/api/v1/models), snapshot 2026-10-14. The snapshot is committed beside this scorer; listed minimum prices may differ from the pinned provider.


## Measurement card

- **Truth.** The owner's 96 pages (99 less the three agreement-only letters), truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner where they differed (`ocr-truth.md`), corrected on 2026-10-29 (W46.truth-edits). Words the two drafters wrote alike were not adjudicated; since then the owner has checked samples of them blind: 59 places on 20 pages where Qwen3.6-27B differs (answered 2026-10-21, `ocr-truth-bias-score.md`: 4 truth errors, the bias not material) and every place where Qwen3.6-27B or LightOnOCR-3 4B differs on the 16 hand pages, with 19 typed controls (answered 2026-10-31, `ocr-hands-rescore.md`: 12 corrections, 10 places unresolved). Agreed words that no third-family reader disputes stay unchecked, so a drafter-family route can still gain where the truth shares its mistake. The figures here are rescored on that truth as it now stands.
- **Selection.** All 99 settled originals for every route (96 in the accuracy table, the three agreement-only letters apart, p038 excluded by the owner), and 20 matched pages for the ladder; none chosen by a tested route or by ABBYY text. The routes are the local-sized models planned in W41, read hosted through OpenRouter, not on a Mac.
- **Comparison.** The same JPEG images (quality 90, 2,400 px cap), prompt, temperature 0 and reasoning setting for every route, one pinned endpoint and precision each, Apple Vision included. One scorer; a failed reading scores empty.
- **Noise.** n = 96 pages, one reading per route. The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired interval across 0, is a tie. The tables carry no paired intervals, so close rows are not an order; the 20-page ladder and the attribute groups are descriptive.
- **Scope.** Hosted precision, not Mac quantization or speed (`ocr-mac-local.md` measures that); the owner's 96, not the public 895. Memory figures are estimates, not tested fits.
