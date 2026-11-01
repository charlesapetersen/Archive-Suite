# W41.mac-local-hw — LightOnOCR-3-4B, Qwen3.5-9B and the W46.ocr-new-open readers on our Mac

The Vision OCR lab's handwriting pick (LightOnOCR-3-4B, 8-bit) and runner-up (Qwen3.5-9B, 4-bit), read on the same Apple M3 Pro with 18 GB over the OCR panel's 99 frozen originals and scored with the panel's own `score()`, so they sit on the same NES scale as every route in [the panel](ocr-panel-local.md). Reproduce: `ocr_mac_local.py collect --model KEY` under the Vision OCR lab's `run-guarded.sh`, one model at a time, then `ocr_mac_local.py report`. Weights from the shared model cache by local path (mlx-vlm). No money. Raw text stays in the private cache.

- **LightOnOCR-3-4B** (`prithivMLmods/LightOnOCR-3-4B-MLX`, 8bit): its card's settings, as the lab ran it: an empty prompt, the 2400 px panel JPEG shrunk to 2048 px on its longest side, 4096 tokens, temperature 0. It answers plain text with no KIND line, so its whole answer is scored and it has no kind figure. No hosted route serves it.
- **Qwen3.5-9B** (`mlx-community/Qwen3.5-9B-4bit`): the panel's prompt, inputs, max_tokens 8192 and temperature 0, thinking off (the hosted route's reasoning: off), so the gap against the hosted bf16 `qwen3.5-9b` row (DeepInfra) is the 4-bit-on-a-Mac penalty.
- **Xiaomi-OCR-0** and **PaddleOCR-VL 1.6** (W46.ocr-new-open): the publisher's bf16 weights at the revisions Sherlock read, downloaded once into the shared model cache (`model_store`), with the Sherlock run's prompt (the card's Markdown prompt; `OCR:`), 8,192 tokens, temperature 0 and thinking off, scored whole. Their Sherlock truth96 runs are `farmshare/truth/xiaomi-ocr-0-49202334` and `paddleocr-vl1.6-49202331`.

## LightOnOCR-3-4B 8-bit (`lightonocr-3-4b-mlx8`)

96 of the panel's 96 accuracy pages (the three agreement-only letters excluded, as there). Failed or cut-off readings score as empty, as in the panel.

| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |
|---|---:|---:|---:|---:|---:|---:|
| Mac MLX (lightonocr-3-4b-mlx8) | 96/96 | 89.17 | 91.37 | 5.78 | 5.04 | – |

| kind | n | Mac MLX NES % |
|---|---:|---:|
| handwritten | 16 | 89.91 |
| mixed | 2 | 58.72 |
| printed | 28 | 87.98 |
| typewritten | 50 | 90.81 |

## Speed and memory: lightonocr-3-4b-mlx8

99 of the 99 originals read, one at a time, model loaded once (2 s to load).

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 23.8 | 40.5 | 59.1 |
| seconds to first token (image encoding + prefill) | 9.4 | 9.5 | 10.4 |
| generation tokens/s | 27.0 | – | – |
| input tokens (image + prompt) | 3086 | 3086 | 3278 |
| output tokens | 391 | 834 | 1297 |
| MLX peak memory, GB | 6.44 | 6.44 | 6.45 |

Total reading time 42 min for 99 pages; 0 failed (0 hit max_tokens).

The memory guard's whole-process view of each collect run (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-10-15T18:58:20 · 0 · 2491 · 1763 · 7889 · -24 · 1

## Qwen3.5-9B 4-bit (`qwen3.5-9b-mlx4`)

96 of the panel's 96 accuracy pages (the three agreement-only letters excluded, as there). Failed or cut-off readings score as empty, as in the panel.

| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |
|---|---:|---:|---:|---:|---:|---:|
| hosted bf16 (qwen3.5-9b) | 92/96 | 89.44 | 91.37 | 9.40 | 3.26 | 83/92 |
| Mac MLX (qwen3.5-9b-mlx4) | 95/96 | 91.93 | 93.65 | 2.78 | 3.03 | 85/95 |

**Mac 4-bit − hosted bf16 NES: +2.48 points** over 96 pages (standard error about 2.50; a negative figure is a 4-bit-on-a-Mac penalty); pages where both completed: 91, mean -0.66. Failed: hosted 4, Mac 1.

1 local reading(s) ended normally but broke the reply format, so the panel's parser scores them empty; taking the text after `TEXT:` instead, the difference is +3.14 points.

| kind | n | hosted bf16 NES % | Mac MLX NES % |
|---|---:|---:|---:|
| handwritten | 16 | 91.00 | 88.06 |
| mixed | 2 | 69.42 | 76.22 |
| printed | 28 | 89.65 | 92.78 |
| typewritten | 50 | 89.63 | 93.32 |

## Speed and memory: qwen3.5-9b-mlx4

99 of the 99 originals read, one at a time, model loaded once (2 s to load).

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 37.6 | 52.8 | 86.4 |
| seconds to first token (image encoding + prefill) | 23.6 | 23.8 | 25.8 |
| generation tokens/s | 26.1 | – | – |
| input tokens (image + prompt) | 4573 | 4573 | 4798 |
| output tokens | 425 | 828 | 1644 |
| MLX peak memory, GB | 7.48 | 7.48 | 7.48 |

Total reading time 64 min for 99 pages; 1 failed (0 hit max_tokens).

The memory guard's whole-process view of each collect run (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-10-15T20:03:12 · 0 · 3867 · 3304 · 9096 · -24 · 2

## Xiaomi-OCR-0 bf16 (`xiaomi-ocr-0-bf16`)

96 of the panel's 96 accuracy pages (the three agreement-only letters excluded, as there). Failed or cut-off readings score as empty, as in the panel.

| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |
|---|---:|---:|---:|---:|---:|---:|
| Mac MLX (xiaomi-ocr-0-bf16) | 96/96 | 88.70 | 90.10 | 6.76 | 3.12 | – |

| kind | n | Mac MLX NES % |
|---|---:|---:|
| handwritten | 16 | 86.04 |
| mixed | 2 | 64.83 |
| printed | 28 | 85.97 |
| typewritten | 50 | 92.03 |

## Speed and memory: xiaomi-ocr-0-bf16

99 of the 99 originals read, one at a time, model loaded once (1 s to load).

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 8.8 | 13.8 | 21.4 |
| seconds to first token (image encoding + prefill) | 4.0 | 4.1 | 5.4 |
| generation tokens/s | 74.3 | – | – |
| input tokens (image + prompt) | 4272 | 4272 | 4497 |
| output tokens | 366 | 769 | 1283 |
| MLX peak memory, GB | 2.92 | 2.92 | 2.93 |

Total reading time 15 min for 99 pages; 0 failed (0 hit max_tokens).

The memory guard's whole-process view of each collect run (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-10-31T04:19:54 · 0 · 917 · 3073 · 4456 · -8 · 1

## PaddleOCR-VL 1.6 bf16 (`paddleocr-vl1.6-bf16`)

96 of the panel's 96 accuracy pages (the three agreement-only letters excluded, as there). Failed or cut-off readings score as empty, as in the panel.

| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |
|---|---:|---:|---:|---:|---:|---:|
| Mac MLX (paddleocr-vl1.6-bf16) | 94/96 | 88.81 | 88.56 | 7.33 | 5.20 | – |

| kind | n | Mac MLX NES % |
|---|---:|---:|
| handwritten | 16 | 80.37 |
| mixed | 2 | 75.49 |
| printed | 28 | 85.89 |
| typewritten | 50 | 93.69 |

## Speed and memory: paddleocr-vl1.6-bf16

99 of the 99 originals read, one at a time, model loaded once (1 s to load).

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 4.8 | 8.4 | 72.8 |
| seconds to first token (image encoding + prefill) | 1.8 | 1.9 | 2.2 |
| generation tokens/s | 141.0 | – | – |
| input tokens (image + prompt) | 1243 | 1284 | 1289 |
| output tokens | 409 | 906 | 8192 |
| MLX peak memory, GB | 2.58 | 2.61 | 2.74 |

Total reading time 12 min for 99 pages; 3 failed (3 hit max_tokens).

The memory guard's whole-process view of each collect run (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-10-31T04:31:50 · 0 · 716 · 2133 · 3460 · -8 · 1

## granite-docling-258M bf16 (`granite-docling-258m-mlx`)

**Incomplete: 46 of 96 accuracy pages read.**

46 of the panel's 96 accuracy pages (the three agreement-only letters excluded, as there). Failed or cut-off readings score as empty, as in the panel.

| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |
|---|---:|---:|---:|---:|---:|---:|
| Mac MLX (granite-docling-258m-mlx) | 37/46 | 60.95 | 61.97 | 26.22 | 21.93 | – |

| kind | n | Mac MLX NES % |
|---|---:|---:|
| handwritten | 7 | 25.88 |
| mixed | 2 | 0.00 |
| printed | 11 | 67.93 |
| typewritten | 26 | 72.13 |

## Speed and memory: granite-docling-258m-mlx

46 of the 99 originals read, one at a time, model loaded once (0 s to load).

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 3.8 | 39.9 | 40.4 |
| seconds to first token (image encoding + prefill) | 0.8 | 1.0 | 1.3 |
| generation tokens/s | 246.6 | – | – |
| input tokens (image + prompt) | 878 | 1142 | 1142 |
| output tokens | 690 | 8192 | 8192 |
| MLX peak memory, GB | 1.44 | 1.50 | 1.50 |

Total reading time 11 min for 46 pages; 9 failed (9 hit max_tokens).

The memory guard's whole-process view of each collect run (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-10-31T12:08:00 · 0 · 11 · 1239 · 1313 · 0 · 1

## Measurement card

- **Truth.** The OCR panel's 96 accuracy pages, the adjudicated truth (`ocr_panel.TRUTH`).
- **Selection.** All 96 accuracy pages (the three agreement-only letters excluded), one reading each; none chosen by a route's reading.
- **Comparison.** Each Mac route at its own quantisation and prompt: LightOnOCR-3-4B 8-bit (96 pages, its own prompt); Qwen3.5-9B 4-bit (96 pages, the panel prompt); Xiaomi-OCR-0 bf16 (96 pages, its own prompt); PaddleOCR-VL 1.6 bf16 (96 pages, its own prompt); granite-docling-258M bf16 (46 pages, its own prompt). The hosted bf16 row is qwen3.5-9b for Qwen3.5-9B 4-bit only. Speed and memory are one Apple M3 Pro with 18 GB, one page at a time.
- **Noise.** Local greedy routes are deterministic on one machine (`ocr-rerun-noise.md`), so the paired interval alone tests a gap between them; the bf16 readers land Xiaomi-OCR-0 bf16 0.01 points from its Sherlock run and PaddleOCR-VL 1.6 bf16 0.08 points from its Sherlock run (`ocr-scorers.md`).
- **Scope.** The 96 only: these routes' 895 figures are Sherlock's, not read from the Mac.
