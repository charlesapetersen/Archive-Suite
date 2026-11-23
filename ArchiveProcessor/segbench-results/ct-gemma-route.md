# Gemma 3 12B for a label's titles, through the app's route (W47.ct-capture-gemma)

The Processor asks Gemma 3 12B on a server on this Mac for a box or folder label's repository, collection title, collection number and date when the gateway is off or local (`ContainerLabelGemma`). `ct-read.md` scored Gemma in-process (`mlx_vlm` `stream_generate` on the photo file). This pilot used the app's request through mlx_vlm.server (mlx-vlm 0.7.4): `ct_read.py`'s prompt, temperature 0, 640 tokens and reasoning off. Pillow approximated the app's 1,600 px JPEG at quality 0.9. The [held-out follow-up](ct-gemma-route-fields.md) uses the app's Swift encoder and reports per-field intervals. Built by `scripts/segbench/ct_gemma_route.py --report`.

## Time a label on this Mac

- 60 label photos, one at a time, on the 18 GB M3 Pro: median **13.04 s** a photo (mean 13.6, slowest 41.8), the first call apart (14.43 s). The server answered 6.6 s after starting with the model preloaded. In-process, `ct-read.md` measured a median 14.93 s and an 8.04 GB peak; the server's memory was not measured here (MLX's is Metal memory, not the process's resident size).
- 59 of 60 replies parsed (an unparsed one gives no Gemma values; the parser's stand).
- The app picked the measured id because the server was started with it: mlx-vlm 0.7.4's cache listing skips this build, whose `model.safetensors.index.json` names five shards where the repo has two, so a server that has not loaded it does not list it, and the app does not use it.

## Right against the truth, on the same cells

The cells `ct_read.py` scores on these photos (236: the owner's, rule-settled and unanimous cells, less carried ones). Each reading against the truth.

| field | cells | through the server | in-process (ct-read) | Vision + parser |
|---|---|---|---|---|
| repository | 58 | 50 of 58 (86.2%) | 49 of 58 (84.5%) | 45 of 58 (77.6%) |
| collection title | 58 | 39 of 58 (67.2%) | 43 of 58 (74.1%) | 34 of 58 (58.6%) |
| collection number | 60 | 44 of 60 (73.3%) | 49 of 60 (81.7%) | 44 of 60 (73.3%) |
| date | 60 | 46 of 60 (76.7%) | 45 of 60 (75.0%) | 46 of 60 (76.7%) |

## Measurement card

- **Truth:** W47.ct-truth-final's (as `ct-read.md`): the owner's answers and notes, his rules, and for the rest the three drafters unanimous, including Gemini 3.7 Flash from Google, like Gemma. Gemma itself drafted none.
- **Selection:** 60 photos drawn with seed 4702 from the truth photos the in-process run read; not by any tested route.
- **Comparison:** the same photos and cells for all three readings; the same prompt and temperature for both Gemma readings, which differ in the image path (the Pillow approximation of the app's 1600 px JPEG through the server's template against `mlx_vlm`'s own load of the photo) and in run date.
- **Noise:** one pass each at temperature 0. Per-field paired intervals for this pilot are in the [held-out follow-up](ct-gemma-route-fields.md).
- **Scope:** mlx-vlm only (LM Studio and Ollama serve other builds, unmeasured); labels alone on an idle Mac, not interleaved with a local OCR model on the same server; this researcher's photos.
