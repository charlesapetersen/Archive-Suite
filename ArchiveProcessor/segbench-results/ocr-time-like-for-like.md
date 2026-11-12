# Every Mac reader, the detectors and the cloud routes timed like for like (W46.ocr-time-like-for-like)

Apple M3 Pro, 18 GB, macOS 27.2, 2026-11-11. The same 16 of the owner's pages for every Mac arm, one arm after another under the heavy lock, at the session's own priority (QoS utility, which runs at full speed: a CPU loop takes 1.25 s at utility and at user-initiated alike, 3.88 s at background). Model load is kept apart, and a warm-up page (p004) goes first in every arm. Drawn by kind tag and seed 20261111: p019 typewritten, p028 typewritten, p036 typewritten, p064 typewritten, p066 typewritten, p065 printed-clipping, p080 printed-clipping, p018 printed, p034 printed, p015 handwritten, p022 handwritten, p045 handwritten, p048 handwritten, p055 handwritten, p009 mixed, p031 mixed.

## Mac, seconds a page

| route | median s a page | typewritten | printed | handwritten | mixed | 90th pct | load s | load average before, after | how |
|---|---|---|---|---|---|---|---|---|---|
| apple-vision | 0.19 | 0.17 | 0.17 | 0.21 | 0.17 | 0.22 | 43.4 | 2.69, 4.12 | median of 3 reads a page, one process |
| xiaomi-ocr-0-bf16 | 7.61 | 7.71 | 10.8 | 5.85 | 6.57 | 10.31 | 1.7 | 5.93, 2.87 | one read a page, greedy |
| paddleocr-vl1.6-bf16 | 3.73 | 3.88 | 5.68 | 2.85 | 3.29 | 5.98 | 1.0 | 2.87, 3.76 | one read a page, greedy |
| lightonocr-3-4b-mlx8 | 23.5 | 25.5 | 34.53 | 14.68 | 18.8 | 30.35 | 3.5 | 3.76, 3.43 | one read a page, greedy |
| qwen3.5-9b-mlx4 | 33.73 | 33.99 | 38.56 | 30.0 | 33.42 | 43.13 | 2.4 | - | earlier reading of these pages (2026-10-15), not re-timed here |
| qwen3-vl-8b-mlx4 | 35.09 | 34.88 | 49.21 | 31.58 | 229.95 | 66.74 | 3.0 | 6.72, 4.34 | one read a page, greedy |
| apple-fm-27 | 3.97 | 4.74 | 3.29 | 3.63 | 5.29 | 75.12 | 0.06 | 3.57, 3.82 | one read a page, greedy, 4,096 tokens |
| ppocrv6-kraken-blla | 13.28 | 13.34 | 19.54 | 13.21 | 12.16 | 16.46 | 3.86 | 4.0, 5.97 | blla 4.51 s (in one process, its model loaded once) + line reading 8.21 s (one page a call less a call on a blank page), medians |
| kraken-german-handwriting | 9.99 | 10.39 | 10.73 | 9.64 | 8.73 | 14.16 | 3.65 | 4.0, 5.97 | blla 4.51 s (in one process, its model loaded once) + line reading 5.12 s (one page a call less a call on a blank page), medians |
| kraken-tridis | 9.97 | 11.6 | 11.79 | 10.07 | 8.33 | 14.9 | 3.96 | 4.0, 5.97 | blla 4.51 s (in one process, its model loaded once) + line reading 5.5 s (one page a call less a call on a blank page), medians |
| kraken-catmus-medieval | 9.51 | 10.23 | 10.5 | 9.41 | 8.22 | 13.73 | 3.63 | 4.0, 5.97 | blla 4.51 s (in one process, its model loaded once) + line reading 4.92 s (one page a call less a call on a blank page), medians |
| kraken-greek-minuscule | 10.88 | 12.43 | 12.73 | 10.93 | 9.08 | 16.1 | 3.77 | 4.0, 5.97 | blla 4.51 s (in one process, its model loaded once) + line reading 6.38 s (one page a call less a call on a blank page), medians |
| kraken-biblia | 9.06 | 10.03 | 10.47 | 9.04 | 7.73 | 13.49 | 4.04 | 4.0, 5.97 | blla 4.51 s (in one process, its model loaded once) + line reading 4.55 s (one page a call less a call on a blank page), medians |
| pp-doclayoutv3 | 0.19 | 0.19 | 0.19 | 0.19 | 0.19 | 0.19 | 1.69 | 5.97, 5.44 | median of 3 detections a page, 1024 px draft |

"printed" includes the two clippings. kraken rows are blla segmentation plus the line reader on its lines, page by page; the load column is both models' load.

### The earlier Mac seconds stand

The readers timed again here took, page by page, this much of their earlier readings' wall on the same pages (where both generated the same tokens): xiaomi-ocr-0-bf16 1.008 (range 0.996 to 1.052, 16 pages); paddleocr-vl1.6-bf16 1.008 (range 0.988 to 1.037, 16 pages); lightonocr-3-4b-mlx8 1.012 (range 1.002 to 1.07, 16 pages); qwen3-vl-8b-mlx4 0.97 (range 0.919 to 1.029, 16 pages); apple-fm-27 0.95 (range 0.859 to 1.016, 16 pages). So the earlier ocr-mac-local and r1-foundation seconds were not slowed by the engine sessions they ran in, and a reader this run could not start is taken from its earlier reading of the same pages: qwen3.5-9b-mlx4 (read 2026-10-15).

## The mixed switch

On the 9 typed and printed pages, Apple Vision 0.17 s a page and LightOnOCR-3 4B 25.5 s a page, medians; page by page the reader takes 139.7 times as long (median of the per-page ratios).

## Cloud, wall seconds a call, from the panels' logs

Not a new run: the calls that made the scored readings of the 96 (the last ok call a page, the three agreement pages apart), as each panel ran them. The figure the settings table takes is the median on the 16 pages the Mac arms read, so the page mix matches; the 96 columns are every scored page. A call's wall includes the queue at the provider and the calls the panel had in flight; "in flight" is the median count of calls already running when each began, itself included.

| route | median s, the 16 | n | median s, the 96 | mean s, the 96 | 90th pct, the 96 | n | in flight | provider | log |
|---|---|---|---|---|---|---|---|---|---|
| gemini3.1-pro | 14.15 | 15 | 13.88 | 13.99 | 21.52 | 92 | 4 | google-ai-studio | ocr-panel-cloud/calls.jsonl |
| gemini3.5-flash | 2.95 | 15 | 3.53 | 4.25 | 7.21 | 92 | 3 | google-ai-studio | ocr-panel-cloud/calls.jsonl |
| gemini3.5-flash-lite | 2.1 | 15 | 2.36 | 3.19 | 6.11 | 92 | 4 | google-ai-studio | ocr-panel-cloud/calls.jsonl |
| gemini3.8-flash | 3.53 | 15 | 4.78 | 5.72 | 9.1 | 92 | 3 | google-ai-studio | ocr-panel-cloud/calls.jsonl |
| gpt5.4-mini | 4.8 | 16 | 6.01 | 6.41 | 8.72 | 93 | 3 | openai | ocr-panel-cloud/calls.jsonl |
| gpt5.6-luna | 5.87 | 16 | 5.49 | 5.85 | 8.03 | 93 | 3 | openai | ocr-panel-cloud/calls.jsonl |
| mistral-large4 | 5.2 | 16 | 6.83 | 7.52 | 12.17 | 94 | 4.5 | mistral | ocr-panel-cloud/calls.jsonl |
| qwen3-vl-235b | 19.52 | 16 | 27.54 | 30.61 | 49.64 | 94 | 4 | deepinfra/fp8 | ocr-panel-cloud/calls.jsonl |
| qwen3.5-397b | 4.54 | 16 | 6.54 | 7.33 | 11.62 | 94 | 5 | deepinfra/fp8 | ocr-panel-cloud/calls.jsonl |
| qwen3.8-flash | 10.15 | 16 | 11.29 | 11.53 | 16.36 | 93 | 4 | alibaba | ocr-panel-cloud/calls.jsonl |
| gemini3.1-flash-lite | 2.39 | 15 | 2.71 | 3.44 | 6.49 | 93 | 3 | google-ai-studio | ocr-panel-local/calls.jsonl |
| qwen3.6-27b | 21.88 | 16 | 25.27 | 31.28 | 56.77 | 95 | 2 | chutes/fp8 | ocr-panel-local/calls.jsonl |
| qwen3.6-35b-a3b | 11.76 | 16 | 15.64 | 33.32 | 98.29 | 96 | 6 | deepinfra/fp8 | ocr-panel-local/calls.jsonl |

Gemini 3.7 Flash on the gateway keeps its own figure (`gemini37-vs-38.md`, 9.43 s median on the 96) and Claude Sonnet 5.5 its mean through `claude -p` (`ocr-panel-cloud.md`, 10 s, three at once). Mistral OCR 4.1 logged no time and stays unmeasured.

## Measurement card

- **Truth.** None: time, not accuracy. Nothing here is scored.
- **Selection.** By the pages' kind tags (`ocr-truth/pages.tsv`) and a fixed seed; no route's output chose a page.
- **Comparison.** One machine, one session, the same pages and images for every Mac arm, back to back, each reader at the settings it was scored with; load apart, a warm-up page first. Cloud figures are the scoring runs' calls and are not like for like with each other in concurrency or time of day.
- **Page mix.** The 16 hold more handwritten and mixed pages than the 96 and fewer long ones, so a median here is not the 96's (the on-device model: 4.0 s here, 9.5 s on the 96, on the same per-page times). Compare routes within this file, not against a 96-page median elsewhere.
- **Noise.** n 16 pages a Mac arm. Vision and PP-DocLayoutV3 read each page 3 times (the per-page runs are in the JSON); the MLX readers are greedy and read once. The Mac was shared with other sessions' light work: the load average before and after each arm is in the table.
- **Scope.** One M3 Pro 18 GB laptop. Seconds on a 16, 32 or 64 GB Mac, on photographed newspapers, and with other work running at once are not measured. Mixed pages are 2 of the 16.
