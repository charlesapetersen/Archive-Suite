# W41.mac-local-measure — Qwen3-VL 8B at 4-bit on our Mac

Reproduce: `ocr_mac_local.py collect` under the Vision OCR lab's `run-guarded.sh`, then `ocr_mac_local.py report`. Model `mlx-community/Qwen3-VL-8B-Instruct-4bit` (mlx-vlm), on an Apple M3 Pro with 18 GB. Same 2400 px JPEG inputs, prompt, max_tokens 8192 and temperature 0 as the [hosted panel](ocr-panel-local.md); the hosted reference is its `qwen3-vl-8b` row (Parasail, bf16). Scoring is the panel's own `score()`. No money. Raw text stays in the private cache.

## Accuracy, paired on the same pages

96 of the panel's 96 accuracy pages (the three agreement-only letters excluded, as there). Failed or cut-off readings score as empty, as in the panel.

| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |
|---|---:|---:|---:|---:|---:|---:|
| hosted bf16 (qwen3-vl-8b) | 94/96 | 91.81 | 93.33 | 3.65 | 2.62 | 75/94 |
| Mac MLX 4-bit (qwen3-vl-8b-mlx4) | 92/96 | 89.66 | 91.12 | 6.72 | 2.93 | 68/92 |

**4-bit penalty (local − hosted NES): -2.15 points** over 96 pages (paired SD 18.61, so the mean's standard error is about 1.90); median page +0.00. Pages where both routes completed: 91, mean -0.17. Local better on 11, within half a point on 64, worse on 21.

1 local reading(s) ended normally but broke the reply format (a KIND outside the four allowed, or no TEXT line), so the panel's parser scores them empty. Taking the text after `TEXT:` instead, as an app could, the penalty is **-1.31 points**: that is the reading penalty, the strict figure above adds the format slips.

Largest drops (NES points; page ids are private-cache keys, not corpus names):

- p071 (typewritten): hosted 99.3 → local 0.0 (local reading failed: length)
- p013 (typewritten): hosted 88.4 → local 0.0 (local reading failed: stop)
- p031 (mixed): hosted 85.8 → local 0.0 (local reading failed: length)
- p019 (typewritten): hosted 97.6 → local 83.8
- p100 (typewritten): hosted 85.9 → local 74.0

| kind | n | hosted NES % | local NES % | difference |
|---|---:|---:|---:|---:|
| handwritten | 16 | 84.83 | 89.16 | +4.33 |
| mixed | 2 | 62.08 | 16.84 | -45.24 |
| printed | 28 | 91.23 | 91.69 | +0.46 |
| typewritten | 50 | 95.56 | 91.59 | -3.97 |

## Speed and memory on the 18 GB M3 Pro

99 of the 99 originals read, one at a time, model loaded once (2 s to load).

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 40.8 | 61.5 | 445.3 |
| seconds to first token (image encoding + prefill) | 24.5 | 25.6 | 27.5 |
| generation tokens/s | 23.7 | – | – |
| input tokens (image + prompt) | 4556 | 4556 | 4781 |
| output tokens | 419 | 928 | 8192 |
| MLX peak memory, GB | 6.91 | 6.91 | 7.64 |

Total reading time 88 min for 99 pages; 4 failed (3 hit max_tokens). The hosted route saw a median 4556 input tokens on the same pages, so both read the image at the same visual resolution.

## What it means for the app route (W41.app-local-models)

- Where both routes finished a page, 4-bit reads as well as bf16 (-0.17 NES points over 91 pages). The strict penalty comes from whole-page failures, not from worse reading.
- 3 of 99 pages ran away to the 8192-token limit (a repetition loop), each costing 7.3 minutes. A local route needs a repetition stop or a much lower token cap scaled to the page, and a retry or fallback on such a page.
- Accept any KIND line and keep the text after `TEXT:`; a strict parser throws away readings like the one above.
- Speed is about 41 s a page, so 102k pages (the corpus’s PDF count, at one photograph each) would be about 48 days of continuous reading on this Mac. Roughly 25 s of each page is image encoding and prefill, fixed by the 2400 px input; generation runs at about 24 tokens a second.
- Memory: 7.6 GB at MLX's peak, about 8.4 GB of whole-process footprint, on an 18 GB Mac with the owner's usual apps open. It ran without the memory guard tripping, but with memory pressure at "warn"; 18 GB is enough for this model only with little else heavy running.
- The load time (2 s) is with the weights already in the file cache; a cold first load reads 5.5 GB from disk.

The memory guard's whole-process view of each collect run (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-10-15T15:11:47 · 0 · 80 · 1252 · 7665 · 661 · 2
- 2026-10-15T16:53:17 · 0 · 5209 · 1000 · 8367 · -517 · 2
