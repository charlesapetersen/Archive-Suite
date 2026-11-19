# Gemma 3 12B for a label's titles, through the app's route (W47.ct-capture-gemma)

The Processor asks Gemma 3 12B on a server on this Mac for a box or folder label's repository, collection title, collection number and date when the gateway is off or local (`ContainerLabelGemma`). `ct-read.md` scored Gemma in-process (`mlx_vlm` `stream_generate` on the photo file); this times and checks the app's request through mlx_vlm.server (mlx-vlm 0.7.4): `ct_read.py`'s prompt, temperature 0, 640 tokens, reasoning off, the upright photo as a JPEG at 1600 px, quality 0.9. Built by `scripts/segbench/ct_gemma_route.py --report`.

## Time a label on this Mac

- 60 label photos, one at a time, on the 18 GB M3 Pro: median **13.04 s** a photo (mean 13.6, slowest 41.8), the first call apart (14.43 s). The server answered 6.6 s after starting with the model preloaded. In-process, `ct-read.md` measured a median 14.93 s and an 8.04 GB peak; the server's memory was not measured here (MLX's is Metal memory, not the process's resident size).
- 59 of 60 replies parsed (an unparsed one gives no Gemma values; the parser's stand).
- The app picked the measured id because the server was started with it: mlx-vlm 0.7.4's cache listing skips this build, whose `model.safetensors.index.json` names five shards where the repo has two, so a server that has not loaded it does not list it, and the app does not use it.

## Right against the truth, on the same cells

The cells `ct_read.py` scores on these photos (236: the owner's, rule-settled and unanimous cells, less carried ones). Each reading against the truth; gaps are the server route less each other, with a 95% bootstrap interval over photos.

| field | cells | through the server | in-process (ct-read) | Vision + parser |
|---|---|---|---|---|
| repository | 58 | 50 of 58 (86.2%) | 49 of 58 (84.5%) | 45 of 58 (77.6%) |
| collection title | 58 | 39 of 58 (67.2%) | 43 of 58 (74.1%) | 34 of 58 (58.6%) |
| collection number | 60 | 44 of 60 (73.3%) | 49 of 60 (81.7%) | 44 of 60 (73.3%) |
| date | 60 | 46 of 60 (76.7%) | 45 of 60 (75.0%) | 46 of 60 (76.7%) |
| **all four** | 236 | 179 of 236 (75.8%) | 186 of 236 (78.8%) | 169 of 236 (71.6%) |

- Server less in-process: -3.0 (-7.7 to +1.7) points, a tie within this sample's noise, though the point estimate is lower (collection number and title most); the two readings differ on some photos (a resized JPEG through the server's chat template, against the photo file).
- Server less Vision + parser: +4.2 (-0.4 to +9.0) points, on these 60 photos a lead whose interval touches zero; `ct-read.md`'s 195 photos are the figure for choosing the route.

## Measurement card

- **Truth:** W47.ct-truth-final's (as `ct-read.md`): the owner's answers and notes, his rules, and for the rest the three drafters unanimous. Gemma drafted none of it.
- **Selection:** 60 photos drawn with seed 4702 from the truth photos the in-process run read; not by any tested route.
- **Comparison:** the same photos and cells for all three readings; the same prompt and temperature for both Gemma readings, which differ in the image path (the app's 1600 px JPEG through the server's template against `mlx_vlm`'s own load of the photo) and in run date.
- **Noise:** one pass each at temperature 0; paired bootstrap over photos; no rerun floor measured, so a gap inside its interval is a tie.
- **Scope:** mlx-vlm only (LM Studio and Ollama serve other builds, unmeasured); labels alone on an idle Mac, not interleaved with a local OCR model on the same server; this researcher's photos.
