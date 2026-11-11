# Paired intervals for every reading route pair (W46.ocr-pair-matrix)

Every pair of reading routes in the settings table (`settings-routes.json`, stage `reading`) that has per-page scores,
compared page by page: on the owner's 96 (p081 apart, so 95 pages) strict and answered, and on the public 895 within
each stratum and over the pages both read. 30 routes on the 96 (435 pairs), 16 on the 895 (765 stratum pairs).
Each entry in `ocr-pair-matrix.json` is the mean NES difference a minus b in points, its 95% paired bootstrap
interval (10,000 rounds, seed 0 per pair, drawn as `ArchiveOCRBench/build.py`'s `bootstrap`) and whether it is a tie.
Built by `scripts/segbench/ocr_pair_matrix.py` from `ocr-pages.csv` and `ocr-scorers-pages.csv`; no model, no
money. Check: every pair with Qwen3.6 27B reproduces the bench headline's `vs_baseline` (n, delta and both ends) to
the hundredth.

## The tie per pair

A pair is a tie when its interval holds 0, or on the 96 when the gap is under the pair's floor, twice the larger
rerun range of the two routes (`ocr-rerun-noise.md`, "The tie rule"): 0.49 points when either route is hosted (cloud
or plan); 0.00 between two Mac routes (local greedy, byte-identical across reruns); a cluster route has no rerun and
is not one machine's greedy decoding, so it takes the hosted 0.49. On the 895 there is no floor and the interval
alone decides (R-3). The settings solver reads a tie from the pair's entry here, not from a floor alone; the
table's `noise.reading` names this file.

On the 96 the routes split into few separable bands. On answered NES the four leaders (Gemini 3.1 Pro 96.85,
Gemini 3.7 Flash 96.76, Claude Sonnet 5.5 96.48, Gemini 3.8 Flash 96.47) tie with each other; Gemini 3.7 Flash and
Claude Sonnet 5.5 also tie with Qwen3.6 27B, local or FarmShare. Apple Vision ties with nothing. Strict NES moves
routes with failures down (Gemini 3.1 Pro to 94.81) and widens their tie sets.

### The 96, answered

| route | NES answered | ties with |
|---|---|---|
| gemini3.1-pro | 96.85 | gemini3.7-flash-gw, claude-sonnet5.5, gemini3.8-flash, gemini3.5-flash |
| gemini3.7-flash-gw | 96.76 | gemini3.1-pro, claude-sonnet5.5, gemini3.8-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, qwen3.8-flash |
| claude-sonnet5.5 | 96.48 | gemini3.1-pro, gemini3.7-flash-gw, gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, qwen3.8-flash, gpt5.4-mini |
| gemini3.8-flash | 96.47 | gemini3.1-pro, gemini3.7-flash-gw, claude-sonnet5.5, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b |
| gemini3.5-flash | 95.48 | gemini3.1-pro, claude-sonnet5.5, gemini3.8-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, gpt5.6-luna, mistral-large4 |
| qwen3.6-27b | 95.38 | gemini3.7-flash-gw, claude-sonnet5.5, gemini3.8-flash, gemini3.5-flash, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare |
| qwen3.5-27b-farmshare | 95.38 | gemini3.7-flash-gw, claude-sonnet5.5, gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare |
| qwen3.6-27b-farmshare | 95.31 | gemini3.7-flash-gw, claude-sonnet5.5, gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare |
| gemini3.5-flash-lite | 95.17 | gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4 |
| qwen3.5-9b-sherlock | 95.13 | qwen3.6-27b, gemini3.5-flash-lite, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.5-9b-mlx4 |
| qwen3.8-flash | 95.11 | gemini3.7-flash-gw, claude-sonnet5.5, gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.5-9b-sherlock, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, gpt5.6-luna |
| gpt5.4-mini | 94.81 | claude-sonnet5.5, gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.8-flash, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| gemini3.1-flash-lite | 94.59 | gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.5-9b-mlx4 |
| qwen3.6-35b-a3b-farmshare | 94.56 | gemini3.8-flash, gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4 |
| qwen3.5-397b | 94.06 | gemini3.8-flash, gemini3.5-flash, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| qwen3-vl-235b | 94.01 | gemini3.8-flash, gemini3.5-flash, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| qwen3-vl-8b-mlx4 | 93.62 | qwen3.5-9b-sherlock, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| gpt5.6-luna | 93.56 | gemini3.5-flash, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| infinity-parser2-pro-sherlock | 93.27 | gemini3.5-flash-lite, qwen3.5-9b-sherlock, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4, paddleocr-vl1.6-sherlock |
| mistral-large4 | 93.25 | gemini3.5-flash, gemini3.5-flash-lite, qwen3.5-9b-sherlock, gpt5.4-mini, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16 |
| qwen3.6-35b-a3b | 93.06 | gpt5.4-mini, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, mistral-ocr-4-1, qwen3.5-9b-mlx4, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16 |
| mistral-ocr-4-1 | 93.01 | gpt5.4-mini, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, qwen3.5-9b-mlx4 |
| qwen3.5-9b-mlx4 | 92.93 | qwen3.5-9b-sherlock, gemini3.1-flash-lite, qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16 |
| paddleocr-vl1.6-sherlock | 90.89 | infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, qwen3.5-9b-mlx4, paddleocr-vl1.6-bf16, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| paddleocr-vl1.6-bf16 | 90.84 | mistral-large4, qwen3.6-35b-a3b, qwen3.5-9b-mlx4, paddleocr-vl1.6-sherlock, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| lightonocr3-4b-farmshare | 89.38 | paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, lightonocr-3-4b-mlx8, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| lightonocr-3-4b-mlx8 | 89.15 | paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, lightonocr3-4b-farmshare, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-bf16 | 88.82 | paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-sherlock | 88.78 | paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, xiaomi-ocr-0-bf16 |
| apple-vision | 83.61 | none |

### The 96, strict

| route | NES strict | ties with |
|---|---|---|
| gemini3.7-flash-gw | 96.76 | claude-sonnet5.5, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, qwen3.6-27b |
| claude-sonnet5.5 | 96.48 | gemini3.7-flash-gw, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, gemini3.8-flash |
| qwen3.5-27b-farmshare | 95.38 | gemini3.7-flash-gw, claude-sonnet5.5, qwen3.6-27b-farmshare, gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, gpt5.4-mini, gemini3.5-flash, gemini3.5-flash-lite, qwen3.8-flash |
| qwen3.6-27b-farmshare | 95.31 | gemini3.7-flash-gw, claude-sonnet5.5, qwen3.5-27b-farmshare, gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, gpt5.4-mini, gemini3.5-flash, gemini3.5-flash-lite, qwen3.8-flash |
| gemini3.1-pro | 94.81 | gemini3.7-flash-gw, claude-sonnet5.5, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4 |
| qwen3.6-35b-a3b-farmshare | 94.56 | qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, gpt5.6-luna, qwen3.8-flash, gemini3.1-flash-lite |
| gemini3.8-flash | 94.44 | claude-sonnet5.5, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, qwen3.6-35b-a3b-farmshare, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite |
| qwen3.6-27b | 94.38 | gemini3.7-flash-gw, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite |
| qwen3.5-397b | 94.06 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite |
| qwen3-vl-235b | 94.01 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite |
| gpt5.4-mini | 93.81 | qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4 |
| gemini3.5-flash | 93.47 | qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4 |
| infinity-parser2-pro-sherlock | 93.27 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4 |
| mistral-large4 | 93.25 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite |
| gemini3.5-flash-lite | 93.17 | qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8 |
| qwen3.5-9b-sherlock | 93.13 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4 |
| qwen3.6-35b-a3b | 93.06 | gemini3.1-pro, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4 |
| mistral-ocr-4-1 | 93.01 | gemini3.1-pro, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4 |
| gpt5.6-luna | 92.57 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16 |
| qwen3.8-flash | 92.11 | qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| qwen3.5-9b-mlx4 | 91.95 | gemini3.1-pro, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| gemini3.1-flash-lite | 91.60 | qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b, gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| qwen3-vl-8b-mlx4 | 89.68 | gpt5.4-mini, gemini3.5-flash, infinity-parser2-pro-sherlock, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| lightonocr3-4b-farmshare | 89.38 | gemini3.5-flash-lite, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| lightonocr-3-4b-mlx8 | 89.15 | gemini3.5-flash-lite, gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| paddleocr-vl1.6-sherlock | 88.98 | gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| paddleocr-vl1.6-bf16 | 88.93 | gpt5.6-luna, qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-bf16 | 88.82 | qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-sherlock | 88.78 | qwen3.8-flash, qwen3.5-9b-mlx4, gemini3.1-flash-lite, qwen3-vl-8b-mlx4, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16 |
| apple-vision | 83.61 | none |

### The 895, per stratum

| group | pairs (strict) | ties strict | ties answered |
|---|---|---|---|
| L1 | 28 | 10 | 9 |
| L2 | 28 | 12 | 11 |
| L3 | 28 | 16 | 13 |
| L4 | 28 | 6 | 2 |
| L5 | 78 | 14 | 18 |
| L6 | 66 | 10 | 6 |
| L7 | 78 | 15 | 15 |
| L8 | 55 | 24 | 18 |
| L9 | 28 | 19 | 19 |
| N1 | 45 | 15 | 10 |
| N2 | 28 | 7 | 8 |
| N3 | 55 | 15 | 7 |
| N4 | 55 | 13 | 15 |
| N5 | 28 | 15 | 24 |
| N6 | 28 | 7 | 7 |
| all | 109 | 24 | 26 |

## Measurement card

- **Truth:** the 96's adjudicated truth, drafted by Gemini 3.8 Flash and Claude Opus 5.5, so every Gemini and Claude
  route is a relative of a drafter and its pairs with other routes lean its way (OCR-1); a tie between two relatives
  is unaffected in direction but not in size. The 895's truth is the public sets' own, independent of every route.
- **Selection:** all 95 scored pages of the 96 (p081 apart, its truth uncorrectable) and every public page a route
  read; no page chosen by a route's result or ABBYY text. The 96 were drawn through a 20-word Vision filter (19 pages
  replaced), so Vision's pairs are on pages it could read (W46.ocr-vision-unfiltered).
- **Comparison:** each pair on the same pages with each route's committed reading and settings; strict scores a
  failure as 0, answered keeps the pages both answered (its n is in each entry). On the 895 a route that read only
  some strata is paired only where both read; `all` is the pages both read, so its n differs between pairs.
- **Noise:** n per entry; the interval is a page bootstrap; the rerun floors as above (Gemini 3.7 Flash's 0.24
  range doubled; Qwen3-VL 8B 4-bit 0.00). The cluster floor of 0.49 is a borrowed figure, not a measured range.
- **Scope:** pairs, not ranks: a route that ties with both of two routes that do not tie with each other is not
  ordered by this file. No per-kind pairs on the 96 (the handwritten floor of 0.60 applies there; groups of 16 to 50
  pages); strata under 20 pages (L9, 15) are descriptive. Not here, for want of per-page scores in these files: Apple
  FM 27, the PP-OCRv6 kraken blla route, the kraken specialists on the 96, the cascade rows, and Qwen3.5 9B
  Sherlock on the 895 (its 895 scores are in `ocr-logprob-pages.csv`, and the table gives it no public figure).
