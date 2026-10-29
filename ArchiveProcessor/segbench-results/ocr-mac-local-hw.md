# W41.mac-local-hw — LightOnOCR-3-4B and Qwen3.5-9B on our Mac

The Vision OCR lab's handwriting pick (LightOnOCR-3-4B, 8-bit) and runner-up (Qwen3.5-9B, 4-bit), read on the same Apple M3 Pro with 18 GB over the OCR panel's 99 frozen originals and scored with the panel's own `score()`, so they sit on the same NES scale as every route in [the panel](ocr-panel-local.md). Reproduce: `ocr_mac_local.py collect --model KEY` under the Vision OCR lab's `run-guarded.sh`, one model at a time, then `ocr_mac_local.py report`. Weights from the lab's cache by local path (mlx-vlm), nothing downloaded. No money. Raw text stays in the private cache.

- **LightOnOCR-3-4B** (`prithivMLmods/LightOnOCR-3-4B-MLX`, 8bit): its card's settings, as the lab ran it: an empty prompt, the 2400 px panel JPEG shrunk to 2048 px on its longest side, 4096 tokens, temperature 0. It answers plain text with no KIND line, so its whole answer is scored and it has no kind figure. No hosted route serves it.
- **Qwen3.5-9B** (`mlx-community/Qwen3.5-9B-4bit`): the panel's prompt, inputs, max_tokens 8192 and temperature 0, thinking off (the hosted route's reasoning: off), so the gap against the hosted bf16 `qwen3.5-9b` row (DeepInfra) is the 4-bit-on-a-Mac penalty.

## LightOnOCR-3-4B 8-bit (`lightonocr-3-4b-mlx8`)

96 of the panel's 96 accuracy pages (the three agreement-only letters excluded, as there). Failed or cut-off readings score as empty, as in the panel.

| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |
|---|---:|---:|---:|---:|---:|---:|
| Mac MLX (lightonocr-3-4b-mlx8) | 96/96 | 89.13 | 91.32 | 5.80 | 5.04 | – |

| kind | n | Mac MLX NES % |
|---|---:|---:|
| handwritten | 16 | 89.67 |
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
| hosted bf16 (qwen3.5-9b) | 92/96 | 89.43 | 91.32 | 9.42 | 3.26 | 83/92 |
| Mac MLX (qwen3.5-9b-mlx4) | 95/96 | 91.91 | 93.64 | 2.79 | 3.03 | 85/95 |

**Mac 4-bit − hosted bf16 NES: +2.48 points** over 96 pages (standard error about 2.50; a negative figure is a 4-bit-on-a-Mac penalty); pages where both completed: 91, mean -0.66. Failed: hosted 4, Mac 1.

1 local reading(s) ended normally but broke the reply format, so the panel's parser scores them empty; taking the text after `TEXT:` instead, the difference is +3.14 points.

| kind | n | hosted bf16 NES % | Mac MLX NES % |
|---|---:|---:|---:|
| handwritten | 16 | 90.92 | 87.92 |
| mixed | 2 | 69.42 | 76.22 |
| printed | 28 | 89.65 | 92.78 |
| typewritten | 50 | 89.63 | 93.33 |

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
