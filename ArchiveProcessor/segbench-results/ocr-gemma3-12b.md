# W46.ocr-gemma3-12b — Gemma 3 12B 4-bit for whole pages on our Mac

The Processor's box and folder label reader (`mlx-community/gemma-3-12b-it-4bit` at revision `86cc6a8d`, the build `ManagedGemmaWorker.py` pins, through mlx-vlm), asked to transcribe whole pages with the OCR panel's prompt, 8,192 output tokens and temperature 0: the same request Qwen3-VL 8B and Qwen3.5-9B answered on this Mac. The inputs are the bench's frozen 2,400 px JPEGs on both sets. Every score is the bench's own (`ocr-scorers-pages.csv`, `ocr_rescore.py`), so the figures sit beside every other route. No money.

Reproduce: `ocr_mac_local.py collect --model gemma3-12b-mlx4` (the 96) and `ocr_gemma3_public.py prepare` then `collect` (the 895), each under `heavy-run.py run -- run-guarded.sh`; then `ocr_rescore.py --merge gemma3-12b-mlx4` with and without `--merge-set public895`, and `ocr_gemma3_report.py`. Raw text stays in the private cache.

## Accuracy and completion

| set | pages | read | completed | failed: loop stop | failed: token cap | failed: reply format | NES strict % | NES answered % | NES lenient % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| the owner's 96 | 96 | 96 | 73 | 23 | 0 | 0 | 52.5 | 69.0 | 62.7 |
| the 895 public pages | 895 | 8 | 0 | 4 | 0 | 0 | – | – | – |

**Loop stop.** A greedy reading that falls into a loop runs to the 8,192-token cap, about nine minutes a page here, which made the full run impractical (the pilot's third page did exactly that). So a reading stops once its last 1,024 tokens repeat, token for token, a cycle of at most 256 tokens (`ocr_mac_local.loop_period`), and counts as failed, as it would at the cap. Over the 907 finished readings of the other Mac-local readers (granite-docling apart) the rule never fires, so it does not end a reading that would have finished. **Lenient** scores a looped page on what it read before the loop and a format-broken reply on its text after `TEXT:`, which is what an app with this stop would keep; **strict** counts both as 0, as every other route on the bench is counted.

**Incomplete on the 895 public pages: 8 of 895 pages read.** Figures cover those only.

## Paired with other routes on the owner's 96

Gemma less the other route, NES points on the pages both have; failures count 0 on both sides.

| route | pages | completed (other) | other NES % | Gemma NES % | Gemma − other | 95% interval | p |
|---|---:|---:|---:|---:|---:|---:|---:|
| Apple Vision (Mac) | 96 | 96 | 83.1 | 52.5 | -30.58 | -37.78 to -23.76 | 0.000 |
| Qwen3-VL 8B 4-bit (Mac) | 96 | 92 | 89.7 | 52.5 | -37.18 | -44.48 to -29.86 | 0.000 |
| Qwen3.5-9B 4-bit (Mac) | 96 | 95 | 91.9 | 52.5 | -39.43 | -46.69 to -32.37 | 0.000 |
| LightOnOCR-3 4B 8-bit (Mac) | 96 | 96 | 89.2 | 52.5 | -36.67 | -44.02 to -29.51 | 0.000 |
| PaddleOCR-VL 1.6 bf16 (Mac) | 96 | 94 | 88.8 | 52.5 | -36.32 | -43.76 to -28.94 | 0.000 |
| Xiaomi-OCR-0 bf16 (Mac) | 96 | 96 | 88.7 | 52.5 | -36.20 | -43.29 to -29.36 | 0.000 |
| Gemini 3.7 Flash (gateway, cloud) | 96 | 96 | 96.7 | 52.5 | -44.23 | -51.10 to -37.68 | 0.000 |

By page kind (NES %, strict; a route shown only where it has every page of the group):

| group | n | Gemma completed | Gemma | Apple Vision | Qwen3-VL 8B 4-bit | Qwen3.5-9B 4-bit | LightOnOCR-3 4B 8-bit | PaddleOCR-VL 1.6 bf16 | Xiaomi-OCR-0 bf16 | Gemini 3.7 Flash |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| handwritten | 16 | 15 | 59.5 | 60.6 | 89.2 | 88.1 | 89.9 | 80.4 | 86.0 | 95.1 |
| mixed | 2 | 2 | 57.9 | 70.8 | 16.8 | 76.2 | 58.7 | 75.5 | 64.8 | 83.8 |
| printed | 28 | 17 | 37.9 | 80.5 | 91.7 | 92.8 | 88.0 | 85.9 | 86.0 | 94.9 |
| typewritten | 50 | 39 | 58.2 | 92.2 | 91.6 | 93.3 | 90.8 | 93.7 | 92.0 | 98.8 |

## Paired with other routes on the 895 public pages

Gemma less the other route, NES points on the pages both have; failures count 0 on both sides.

| route | pages | completed (other) | other NES % | Gemma NES % | Gemma − other | 95% interval | p |
|---|---:|---:|---:|---:|---:|---:|---:|

By stratum (NES %, strict; a route shown only where it has every page of the group):

| group | n | Gemma completed | Gemma |  |
|---|---:|---:|---:|

## Speed and memory on the owner's 96

96 pages, one at a time, on an Apple M3 Pro with 18 GB (mlx-vlm 0.7.4; 4 s median model load). Total reading time 1.1 h.

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 24.0 | 97.5 | 203.4 |
| seconds to first token (image encoding + prefill) | 3.9 | – | – |
| generation tokens/s | 17.9 | – | – |
| input tokens (image + prompt) | 626 | – | – |
| output tokens | 359 | 1648 | – |
| MLX peak memory, GB | 7.86 | – | 7.86 |

Memory guard whole-process rows for these runs (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-11-24T19:35:11 · 0 · 584 · 2009 · 9036 · 870 · 2
- 2026-11-24T20:18:42 · 137 · 15 · 629 · 7937 · 2272 · 2
- 2026-11-25T02:40:23 · 0 · 4178 · 1344 · 9242 · 211 · 2


## Speed and memory on the 895 public pages

8 pages, one at a time, on an Apple M3 Pro with 18 GB (mlx-vlm 0.7.4; 4 s median model load). Total reading time 0.1 h.

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 44.4 | 63.3 | 65.4 |
| seconds to first token (image encoding + prefill) | 3.9 | – | – |
| generation tokens/s | 17.9 | – | – |
| input tokens (image + prompt) | 626 | – | – |
| output tokens | 720 | 1056 | – |
| MLX peak memory, GB | 7.86 | – | 7.86 |


## Is it a candidate for the app's on-computer page OCR?

- Against Apple Vision on the owner's 96 (96 pages): Gemma 52.5 against 83.1, -30.58 points (worse).
- Against the best Mac-local reader on the 96, Qwen3.5-9B 4-bit (Mac): Gemma 52.5 against 91.9, -39.43 points.
- Speed: a median 24 s a page on the 96, so 102k pages would be about 28 days of continuous reading; Apple Vision reads a page in about a second.

## Measurement card

- **Truth.** The owner's 96 pages (99 less the three agreement-only letters), truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner where they differed (`ocr-truth.md`), corrected on 2026-10-29 (W46.truth-edits). Words the two drafters wrote alike were not adjudicated; since then the owner has checked samples of them blind: 59 places on 20 pages where Qwen3.6-27B differs (answered 2026-10-21, `ocr-truth-bias-score.md`: 4 truth errors, the bias not material) and every place where Qwen3.6-27B or LightOnOCR-3 4B differs on the 16 hand pages, with 19 typed controls (answered 2026-10-31, `ocr-hands-rescore.md`: 12 corrections, 10 places unresolved). Agreed words that no third-family reader disputes stay unchecked, so a drafter-family route can still gain where the truth shares its mistake. The 895: each public dataset's own ground truth, frozen with the set (W43.corpus-build); not drafted by any scored route, not checked by the owner.
- **Selection.** All 96 accuracy pages and all 895 frozen public pages, one reading each; none chosen by a route's reading or by ABBYY text. Every page where Apple Vision (26.6) read fewer than 20 words was replaced at the draw (19 of them, 4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as empty, and every comparison with Vision on them is on pages Vision could read. By the owner's answers, 15 of the 19 replaced pages were few-word pages, and 19 of 200 drawn owner pages (about 10%) hold only a few words (`ocr-vision-unfiltered.md`).
- **Comparison.** The same request on both sets: the pinned build, the panel prompt, 8,192 tokens, temperature 0, the loop stop above and the same 2,400 px JPEGs every route on the bench read (the 455 public images remade by the same encoder). Every route is scored by the one scorer; failures count 0 on both sides of a pair. Apple Vision has 320 of the 895 (its Latin strata), so its pairs there are on those. Speed and memory are one M3 Pro with 18 GB, one page at a time, with the owner's usual apps open.
- **Noise.** n = 96 and 895, paired per page with a bootstrap interval. Greedy local decoding is deterministic on one machine (`ocr-rerun-noise.md`). The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired interval across 0, is a tie. Speed and memory are one run of each page.
- **Scope.** One model at one quantisation and one prompt, on this Mac. Gemma 3's vision encoder sees each page at its fixed 896 px square, whatever the input size, so this measures that build as the Processor ships it, not Gemma 3 with tiled input. It does not settle a route for labels, which `ct-gemma-route-fields.md` measured.
