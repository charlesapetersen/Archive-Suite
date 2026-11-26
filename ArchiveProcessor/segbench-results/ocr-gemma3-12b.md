# W46.ocr-gemma3-12b — Gemma 3 12B 4-bit for whole pages on our Mac

The Processor's box and folder label reader (`mlx-community/gemma-3-12b-it-4bit` at revision `86cc6a8d`, the build `ManagedGemmaWorker.py` pins, through mlx-vlm), asked to transcribe whole pages with the OCR panel's prompt, 8,192 output tokens and temperature 0: the same request Qwen3-VL 8B and Qwen3.5-9B answered on this Mac. The inputs are the bench's frozen 2,400 px JPEGs on both sets. Every score is the bench's own (`ocr-scorers-pages.csv`, `ocr_rescore.py`), so the figures sit beside every other route. No money.

Reproduce: `ocr_mac_local.py collect --model gemma3-12b-mlx4` (the 96) and `ocr_gemma3_public.py prepare` then `collect` (the 895), each under `heavy-run.py run -- run-guarded.sh`; then `ocr_rescore.py --merge gemma3-12b-mlx4` with and without `--merge-set public895`, and `ocr_gemma3_report.py`. Raw text stays in the private cache.

## Accuracy and completion

| set | pages | read | completed | failed: loop stop | failed: token cap | failed: reply format | NES strict % | NES answered % | NES lenient % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| the owner's 96 | 96 | 96 | 73 | 23 | 0 | 0 | 52.5 | 69.0 | 62.7 |
| the 895 public pages | 895 | 280 | 147 | 129 | 4 | 0 | 30.3 | 57.8 | 35.6 |

**Loop stop.** A greedy reading that falls into a loop runs to the 8,192-token cap, about nine minutes a page here, which made the full run impractical (the pilot's third page did exactly that). So a reading stops once its last 1,024 tokens repeat, token for token, a cycle of at most 256 tokens (`ocr_mac_local.loop_period`), and counts as failed, as it would at the cap. Over the 907 finished readings of the other Mac-local readers (granite-docling apart) the rule never fires, so it does not end a reading that would have finished. **Lenient** scores a looped page on what it read before the loop and a format-broken reply on its text after `TEXT:`, which is what an app with this stop would keep; **strict** counts both as 0, as every other route on the bench is counted.

**Partial sample on the 895 public pages: 280 of 895 pages read.** Figures cover those only. The run read in the corpus's run order, which interleaves the strata, so the pages read cover every stratum and all 18 sources; collection stopped there by the owner's call (2026-11-26) after the memory guard refused or killed seven resumes while the 9 GB model loaded. The pairs below are on those pages.

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
| Apple Vision (Mac) | 91 | 86 | 46.1 | 20.1 | -25.97 | -31.18 to -21.06 | 0.000 |
| Qwen3-VL 8B bf16 (FarmShare) | 280 | 213 | 57.7 | 30.3 | -27.34 | -31.17 to -23.53 | 0.000 |
| LightOnOCR-3 4B bf16 (FarmShare) | 280 | 255 | 65.2 | 30.3 | -34.85 | -38.39 to -31.31 | 0.000 |
| PaddleOCR-VL 1.6 (Sherlock) | 280 | 217 | 48.9 | 30.3 | -18.51 | -21.64 to -15.48 | 0.000 |
| Xiaomi-OCR-0 (Sherlock) | 280 | 280 | 65.2 | 30.3 | -34.83 | -38.09 to -31.62 | 0.000 |
| Gemini 3.7 Flash (gateway, cloud) | 280 | 274 | 78.5 | 30.3 | -48.18 | -52.06 to -44.35 | 0.000 |

By stratum (NES %, strict; a route shown only where it has every page of the group):

| group | n | Gemma completed | Gemma | Apple Vision | Qwen3-VL 8B bf16 | LightOnOCR-3 4B bf16 | PaddleOCR-VL 1.6 | Xiaomi-OCR-0 | Gemini 3.7 Flash |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| L1 (btp, Latn) | 24 | 21 | 49.9 | – | 82.2 | 84.0 | 70.7 | 81.7 | 88.6 |
| L2 (bentham, Latn; btp, Latn) | 21 | 14 | 37.5 | – | 62.7 | 77.2 | 60.1 | 78.1 | 80.0 |
| L3 (btp, Latn; tapus, Latn) | 34 | 34 | 85.0 | – | 94.6 | 93.0 | 94.5 | 92.0 | 96.4 |
| L4 (si, Latn) | 26 | 18 | 27.8 | – | 57.4 | 57.1 | 43.1 | 54.2 | 82.0 |
| L5 (castilian, Latn; iforal, Latn; voc, Latn) | 21 | 0 | 0.0 | 42.5 | 55.3 | 60.6 | 32.2 | 59.9 | 65.1 |
| L6 (kurrent, Latn; read2017, Latn) | 16 | 4 | 7.5 | 27.9 | 23.5 | 55.6 | 29.9 | 47.7 | 88.3 |
| L7 (koenigsfelden, Latn) | 20 | 1 | 0.7 | 11.9 | 28.1 | 40.3 | 14.2 | 37.2 | 55.1 |
| L8 (ocrd, Latn) | 34 | 25 | 50.0 | 77.1 | 87.6 | 89.7 | 80.7 | 89.0 | 89.7 |
| L9 (newsbench, Latn) | 4 | 1 | 7.5 | – | 92.4 | 95.0 | 0.0 | 93.4 | 97.4 |
| N1 (muharaf, Arab) | 10 | 1 | 0.7 | – | 15.1 | 45.9 | 17.9 | 26.0 | 78.1 |
| N2 (peter, Cyrl) | 19 | 6 | 4.5 | – | 14.1 | 7.4 | 6.6 | 28.6 | 23.7 |
| N3 (eparchos, Grek) | 16 | 5 | 6.8 | – | 2.8 | 46.2 | 13.1 | 40.7 | 92.6 |
| N4 (biblia, Hebr) | 5 | 0 | 0.0 | – | 11.1 | 22.5 | 0.0 | 12.8 | 72.3 |
| N5 (omnidoc, Hans; omnidoc, Hant) | 16 | 4 | 15.5 | – | 77.6 | 73.0 | 57.7 | 81.0 | 85.5 |
| N6 (devanagari, Deva) | 14 | 13 | 41.8 | – | 67.4 | 68.0 | 54.6 | 80.8 | 72.0 |

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

280 pages, one at a time, on an Apple M3 Pro with 18 GB (mlx-vlm 0.7.4; 4 s median model load). Total reading time 6.0 h.

| measure | median | 90th percentile | max |
|---|---:|---:|---:|
| seconds a page (prompt + generation) | 54.9 | 82.6 | 2114.6 |
| seconds to first token (image encoding + prefill) | 3.9 | – | – |
| generation tokens/s | 17.7 | – | – |
| input tokens (image + prompt) | 626 | – | – |
| output tokens | 710 | 1280 | – |
| MLX peak memory, GB | 7.86 | – | 8.03 |

Memory guard whole-process rows for these runs (date, exit, seconds, peak RSS MB, peak physical footprint MB, swap growth MB, worst pressure level):

- 2026-11-25T06:33:54 · 0 · 13979 · 1072 · 9388 · 456 · 2
- 2026-11-25T06:41:22 · 137 · 13 · 1485 · 7586 · 1929 · 4
- 2026-11-25T09:59:02 · 137 · 13 · 848 · 7825 · 1798 · 4
- 2026-11-26T03:13:57 · 137 · 14 · 3072 · 7717 · 1504 · 4
- 2026-11-26T07:06:49 · 137 · 12 · 815 · 7945 · 2166 · 2


## Is it a candidate for the app's on-computer page OCR?

- Against Apple Vision on the owner's 96 (96 pages): Gemma 52.5 against 83.1, -30.58 points (worse).
- Against Apple Vision on the 895 public pages (91 pages): Gemma 20.1 against 46.1, -25.97 points (worse).
- Against the best Mac-local reader on the 96, Qwen3.5-9B 4-bit (Mac): Gemma 52.5 against 91.9, -39.43 points.
- Speed: a median 24 s a page on the 96, so 102k pages would be about 28 days of continuous reading; Apple Vision reads a page in about a second.
- Verdict: not a candidate. It loses to Apple Vision by a wide margin on both sets, fails 23 of the 96 and 133 of 280 public pages (mostly loops), and is slower; the public figures are a partial sample, but a gap this size would not close on the rest.

## Measurement card

- **Truth.** The owner's 96 pages (99 less the three agreement-only letters), truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner where they differed (`ocr-truth.md`), corrected on 2026-10-29 (W46.truth-edits). Words the two drafters wrote alike were not adjudicated; since then the owner has checked samples of them blind: 59 places on 20 pages where Qwen3.6-27B differs (answered 2026-10-21, `ocr-truth-bias-score.md`: 4 truth errors, the bias not material) and every place where Qwen3.6-27B or LightOnOCR-3 4B differs on the 16 hand pages, with 19 typed controls (answered 2026-10-31, `ocr-hands-rescore.md`: 12 corrections, 10 places unresolved). Agreed words that no third-family reader disputes stay unchecked, so a drafter-family route can still gain where the truth shares its mistake. The 895: each public dataset's own ground truth, frozen with the set (W43.corpus-build); not drafted by any scored route, not checked by the owner.
- **Selection.** All 96 accuracy pages and 280 of the 895 frozen public pages, one reading each; none chosen by a route's reading or by ABBYY text. The public pages are the first read in the corpus's run order, which interleaves the strata, so every stratum and source is present but at uneven shares of its full count; the rest were not read (owner, 2026-11-26), so the public figures are a partial sample, not the 895. Every page where Apple Vision (26.6) read fewer than 20 words was replaced at the draw (19 of them, 4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as empty, and every comparison with Vision on them is on pages Vision could read. By the owner's answers, 15 of the 19 replaced pages were few-word pages, and 19 of 200 drawn owner pages (about 10%) hold only a few words (`ocr-vision-unfiltered.md`).
- **Comparison.** The same request on both sets: the pinned build, the panel prompt, 8,192 tokens, temperature 0, the loop stop above and the same 2,400 px JPEGs every route on the bench read (the 455 public images remade by the same encoder). Every route is scored by the one scorer; failures count 0 on both sides of a pair. Apple Vision has 320 of the 895 (its Latin strata), so its pairs there are on those. Speed and memory are one M3 Pro with 18 GB, one page at a time, with the owner's usual apps open.
- **Noise.** n = 96 and 280 (of 895), paired per page with a bootstrap interval. Greedy local decoding is deterministic on one machine (`ocr-rerun-noise.md`). The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired interval across 0, is a tie. Speed and memory are one run of each page.
- **Scope.** One model at one quantisation and one prompt, on this Mac. Gemma 3's vision encoder sees each page at its fixed 896 px square, whatever the input size, so this measures that build as the Processor ships it, not Gemma 3 with tiled input. It does not settle a route for labels, which `ct-gemma-route-fields.md` measured.
