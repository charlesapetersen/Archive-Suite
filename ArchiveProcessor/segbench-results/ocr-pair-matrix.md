# Paired intervals for every reading route pair (W46.ocr-pair-matrix, W46.pair-matrix-cover)

Every pair of reading routes in the settings table (`settings-routes.json`, stage `reading`) that has per-page scores,
compared page by page: on the owner's 96 (p081 apart, so 95 pages) strict and answered, over all pages and within
each kind; and on the public 895 within each stratum, over the three handwritten strata pooled (`L1-L3`) and over the
pages both read. 35 routes on the 96 (595 pairs a group), 32 of them with hands16 (496 pairs), 17 on the 895 (890
stratum pairs). Each entry in `ocr-pair-matrix.json` is the mean NES difference a minus b in points, its 95% paired
bootstrap interval (10,000 rounds, seed 0 per pair, drawn as `ArchiveOCRBench/build.py`'s `bootstrap`) and whether it
is a tie. Built by `scripts/segbench/ocr_pair_matrix.py` from `ocr-pages.csv`, `ocr-hands-pages.csv` and
`ocr-scorers-pages.csv`; no model, no money. Checks: every pair with Qwen3.6 27B reproduces the bench headline's
`vs_baseline` (n, delta and both ends) to the hundredth; the rerun of 2026-11-11 reproduces all 1,200 entries of the
first build exactly; `settings_routes.py --check` fails when a reading row with per-page scores has no pair entries
in a group.

## The groups

- **The 96, `all`:** the 95 pages, strict and answered.
- **The 96, per kind:** `typewritten` (50 pages), `printed` (27, p081 apart) and `handwritten` (16), the kinds of
  `ocr-pages.csv`, strict and answered. The two mixed pages are in `all` only.
- **The 96, `hands16`:** the 16 hand pages on the truth after the owner's hand sheet, the figure the solver ranks
  handwritten pages on (04-reading §3). Per-page scores from `ocr-hands-pages.csv`, which `ocr_hands_rescore.py`
  writes beside `ocr-hands-rescore.json` (a rerun reproduces that file exactly). Strict only: the file scores an
  empty reading as 0 and keeps no answered flag. A row is in it when its hands16 figure comes from
  `ocr-hands-rescore.json`; the three cluster rows with no hands16 figure (Qwen3.6 27B and Qwen3.6 35B-A3B on
  FarmShare, Qwen3.5 9B on Sherlock) are paired on `handwritten` only. A row's hands16 reading can be a different run
  from its `handwritten` one (the cluster native runs), which is why the two groups differ slightly for some rows.
- **The 895:** each stratum (L1-L9, N1-N6), `L1-L3` pooled (240 pages, independent truth), and `all`.

## The tie per pair

**On the 96 a pair is a tie only when its gap is under the pair's floor** (the owner, walkthrough 2026-11-11,
W46.pairs-redecide-owner-ok: "floor only", as `12-settings-design.md` §3.3 reads). The floor is twice the larger
rerun range of the two routes (`ocr-rerun-noise.md`, "The tie rule"). Over all pages: 0.49 points when either route
is hosted (cloud or plan); 0.00 between two Mac routes (local greedy, byte-identical across reruns); a cluster route
has no rerun and is not one machine's greedy decoding, so it takes the hosted 0.49. Per kind the kind's own range
applies, twice Gemini 3.7 Flash's per-kind rerun range: typewritten 0.42 (0.21), printed 0.24 (0.12), handwritten and
hands16 0.60 (0.30); a pair of Mac routes stays 0.00 in every group. The paired interval is shown beside the figure
and makes no tie; each entry keeps it as `interval_holds_0`, and the floor test as `under_floor`. **On the 895 the
floor makes no tie and the interval alone decides** (R-3), so there `tie` is `interval_holds_0`. The settings solver reads
a tie on the 96 from the pair's entry here; on the 895 a pick takes the stratum's leader and the 895 `tie` decides only
whether a stratum route earns a row (W46.pairs-redecide, 04-reading §3); the table's `noise.reading` names this file.
The rerun floor is a route's own instability, which does not change with the page set, so the hosted 0.49 holds on
the 895 too (measurement review pass 14, P14-5). It changes no pick today: the strata the picks take (L4 forms, L9
newspapers, pooled L1-L3 handwritten) have no cluster runner-up within 0.49 of the leader. Among cluster routes the
groups where it would bite are L3 (Qwen3.6 27B over Qwen3.5 27B by 0.26 and Infinity-Parser2 Pro by 0.30) and N6
(Xiaomi OCR over Infinity-Parser2 Pro by 0.41); among all routes also L1-L3 (Infinity over Gemini 3.7 Flash, 0.17),
L2 (Gemini over Infinity, 0.21) and L3's Gemini (0.11). The first build (W46.ocr-pair-matrix)
also counted an interval that holds 0 as a tie on the 96; the figures are unchanged, only that flag.

On the 96 the leaders separate. On answered NES the four (Gemini 3.1 Pro 96.85, Gemini 3.7 Flash 96.76, Claude
Sonnet 5.5 96.48, Gemini 3.8 Flash 96.47) tie only with each other; the next band, Gemini 3.5 Flash to Qwen3.8 Flash
(95.48 to 95.11), holds both Qwen3.6 27B and Qwen3.5 27B. Apple Vision ties with nothing on answered NES and on strict
only with Gemma 4 26B-A4B, whose failures pull it down to Vision's figure. Of the 595 pairs a group, on strict NES 70
tie over all pages, 60 on typewritten, 18 on printed, 55 on handwritten and 46 of 496 on hands16; an interval holds 0
in 308, 332, 439, 266 and 208 of them.

Per kind, each table gives every route against the group's leader on strict NES, the tie under the floor and whether
the interval holds 0. On the 27 printed pages LightOnOCR-3 4B (MLX) minus Qwen3.5 9B (MLX) is −5.00 [−10.88, +0.20]:
a Mac pair, floor 0.00, so not a tie. On the pooled L1-L3 Infinity-Parser2-Pro leads every other cluster route
(+3.09 to +13.37, n 240) and ties Gemini 3.7 Flash by the interval (+0.17 [−1.18, +1.38]).

### The 96, answered

| route | NES answered | ties with |
|---|---|---|
| gemini3.1-pro | 96.85 | gemini3.7-flash-gw, claude-sonnet5.5, gemini3.8-flash |
| gemini3.7-flash-gw | 96.76 | gemini3.1-pro, claude-sonnet5.5, gemini3.8-flash |
| claude-sonnet5.5 | 96.48 | gemini3.1-pro, gemini3.7-flash-gw, gemini3.8-flash |
| gemini3.8-flash | 96.47 | gemini3.1-pro, gemini3.7-flash-gw, claude-sonnet5.5 |
| gemini3.5-flash | 95.48 | qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash |
| qwen3.6-27b | 95.38 | gemini3.5-flash, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash |
| qwen3.5-27b-farmshare | 95.38 | gemini3.5-flash, qwen3.6-27b, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash |
| qwen3.6-27b-farmshare | 95.31 | gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash, gpt5.4-mini |
| gemini3.5-flash-lite | 95.17 | gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, qwen3.5-9b-sherlock, qwen3.8-flash, gpt5.4-mini |
| qwen3.5-9b-sherlock | 95.13 | gemini3.5-flash-lite, qwen3.8-flash, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b |
| qwen3.8-flash | 95.11 | gemini3.5-flash, qwen3.6-27b, qwen3.5-27b-farmshare, qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.5-9b-sherlock, gpt5.4-mini |
| gpt5.4-mini | 94.81 | qwen3.6-27b-farmshare, gemini3.5-flash-lite, qwen3.8-flash, gemini3.1-flash-lite, qwen3.6-35b-a3b-farmshare |
| gemini3.1-flash-lite | 94.59 | qwen3.5-9b-sherlock, gpt5.4-mini, qwen3.6-35b-a3b-farmshare, qwen3.5-397b, qwen3-vl-235b |
| qwen3.6-35b-a3b-farmshare | 94.56 | qwen3.5-9b-sherlock, gpt5.4-mini, gemini3.1-flash-lite |
| qwen3.5-397b | 94.06 | qwen3.5-9b-sherlock, gemini3.1-flash-lite, qwen3-vl-235b, gpt5.6-luna |
| qwen3-vl-235b | 94.01 | qwen3.5-9b-sherlock, gemini3.1-flash-lite, qwen3.5-397b, gpt5.6-luna, qwen3.5-9b |
| gemma4-31b | 93.76 | qwen3-vl-8b-mlx4, qwen3.5-9b, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| qwen3-vl-8b-mlx4 | 93.62 | gemma4-31b, gpt5.6-luna, qwen3.5-9b, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| gpt5.6-luna | 93.56 | qwen3.5-397b, qwen3-vl-235b, qwen3-vl-8b-mlx4, qwen3.5-9b, infinity-parser2-pro-sherlock, mistral-large4 |
| qwen3.5-9b | 93.38 | qwen3-vl-235b, gemma4-31b, qwen3-vl-8b-mlx4, gpt5.6-luna, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b |
| infinity-parser2-pro-sherlock | 93.27 | gemma4-31b, qwen3-vl-8b-mlx4, gpt5.6-luna, qwen3.5-9b, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| mistral-large4 | 93.25 | gemma4-31b, qwen3-vl-8b-mlx4, gpt5.6-luna, qwen3.5-9b, infinity-parser2-pro-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| qwen3.6-35b-a3b | 93.06 | gemma4-31b, qwen3-vl-8b-mlx4, qwen3.5-9b, infinity-parser2-pro-sherlock, mistral-large4, mistral-ocr-4-1, qwen3.5-9b-mlx4 |
| mistral-ocr-4-1 | 93.01 | gemma4-31b, qwen3-vl-8b-mlx4, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, qwen3.5-9b-mlx4 |
| qwen3.5-9b-mlx4 | 92.93 | gemma4-31b, infinity-parser2-pro-sherlock, mistral-large4, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| gemma4-26b-a4b | 92.38 | churro-3b-farmshare |
| mistral-small-24b | 91.45 | churro-3b-farmshare |
| churro-3b-farmshare | 91.07 | gemma4-26b-a4b, mistral-small-24b, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16 |
| paddleocr-vl1.6-sherlock | 90.89 | churro-3b-farmshare, paddleocr-vl1.6-bf16 |
| paddleocr-vl1.6-bf16 | 90.84 | churro-3b-farmshare, paddleocr-vl1.6-sherlock |
| lightonocr3-4b-farmshare | 89.38 | lightonocr-3-4b-mlx8 |
| lightonocr-3-4b-mlx8 | 89.15 | lightonocr3-4b-farmshare, xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-bf16 | 88.82 | xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-sherlock | 88.78 | lightonocr-3-4b-mlx8, xiaomi-ocr-0-bf16 |
| apple-vision | 83.61 | none |

### The 96, strict

| route | NES strict | ties with |
|---|---|---|
| gemini3.7-flash-gw | 96.76 | claude-sonnet5.5 |
| claude-sonnet5.5 | 96.48 | gemini3.7-flash-gw |
| qwen3.5-27b-farmshare | 95.38 | qwen3.6-27b-farmshare |
| qwen3.6-27b-farmshare | 95.31 | qwen3.5-27b-farmshare |
| gemini3.1-pro | 94.81 | qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.6-27b |
| qwen3.6-35b-a3b-farmshare | 94.56 | gemini3.1-pro, gemini3.8-flash, qwen3.6-27b |
| gemini3.8-flash | 94.44 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, qwen3.6-27b, qwen3.5-397b, qwen3-vl-235b |
| qwen3.6-27b | 94.38 | gemini3.1-pro, qwen3.6-35b-a3b-farmshare, gemini3.8-flash, qwen3.5-397b, qwen3-vl-235b |
| qwen3.5-397b | 94.06 | gemini3.8-flash, qwen3.6-27b, qwen3-vl-235b, gpt5.4-mini |
| qwen3-vl-235b | 94.01 | gemini3.8-flash, qwen3.6-27b, qwen3.5-397b, gpt5.4-mini |
| gpt5.4-mini | 93.81 | qwen3.5-397b, qwen3-vl-235b, gemini3.5-flash |
| gemini3.5-flash | 93.47 | gpt5.4-mini, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| infinity-parser2-pro-sherlock | 93.27 | gemini3.5-flash, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| mistral-large4 | 93.25 | gemini3.5-flash, infinity-parser2-pro-sherlock, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| gemini3.5-flash-lite | 93.17 | gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| qwen3.5-9b-sherlock | 93.13 | gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.6-35b-a3b, mistral-ocr-4-1 |
| qwen3.6-35b-a3b | 93.06 | gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, mistral-ocr-4-1, gpt5.6-luna |
| mistral-ocr-4-1 | 93.01 | gemini3.5-flash, infinity-parser2-pro-sherlock, mistral-large4, gemini3.5-flash-lite, qwen3.5-9b-sherlock, qwen3.6-35b-a3b, gpt5.6-luna |
| gpt5.6-luna | 92.57 | qwen3.6-35b-a3b, mistral-ocr-4-1, qwen3.8-flash |
| qwen3.8-flash | 92.11 | gpt5.6-luna, qwen3.5-9b-mlx4 |
| qwen3.5-9b-mlx4 | 91.95 | qwen3.8-flash, gemini3.1-flash-lite |
| gemini3.1-flash-lite | 91.60 | qwen3.5-9b-mlx4 |
| gemma4-31b | 90.80 | none |
| qwen3-vl-8b-mlx4 | 89.68 | mistral-small-24b, qwen3.5-9b, lightonocr3-4b-farmshare |
| mistral-small-24b | 89.53 | qwen3-vl-8b-mlx4, qwen3.5-9b, lightonocr3-4b-farmshare, churro-3b-farmshare, lightonocr-3-4b-mlx8 |
| qwen3.5-9b | 89.45 | qwen3-vl-8b-mlx4, mistral-small-24b, lightonocr3-4b-farmshare, churro-3b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock |
| lightonocr3-4b-farmshare | 89.38 | qwen3-vl-8b-mlx4, mistral-small-24b, qwen3.5-9b, churro-3b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16 |
| churro-3b-farmshare | 89.16 | mistral-small-24b, qwen3.5-9b, lightonocr3-4b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| lightonocr-3-4b-mlx8 | 89.15 | mistral-small-24b, qwen3.5-9b, lightonocr3-4b-farmshare, churro-3b-farmshare, paddleocr-vl1.6-sherlock, xiaomi-ocr-0-sherlock |
| paddleocr-vl1.6-sherlock | 88.98 | qwen3.5-9b, lightonocr3-4b-farmshare, churro-3b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16, xiaomi-ocr-0-sherlock |
| paddleocr-vl1.6-bf16 | 88.93 | lightonocr3-4b-farmshare, churro-3b-farmshare, paddleocr-vl1.6-sherlock, xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-bf16 | 88.82 | churro-3b-farmshare, paddleocr-vl1.6-sherlock, xiaomi-ocr-0-sherlock |
| xiaomi-ocr-0-sherlock | 88.78 | churro-3b-farmshare, lightonocr-3-4b-mlx8, paddleocr-vl1.6-sherlock, paddleocr-vl1.6-bf16, xiaomi-ocr-0-bf16 |
| gemma4-26b-a4b | 83.62 | apple-vision |
| apple-vision | 83.61 | gemma4-26b-a4b |

### The 96, typewritten, strict (floor 0.42 hosted, 0.00 Mac pairs)

| route | NES strict | leader minus route [95%] | tie | interval holds 0 |
|---|---|---|---|---|
| gemini3.7-flash-gw | 98.80 | leader | |  |
| gemini3.1-pro | 98.74 | +0.06 [-1.17, +1.03] (n 50) | tie | yes |
| gemini3.8-flash | 98.73 | +0.06 [-0.18, +0.30] (n 50) | tie | yes |
| claude-sonnet5.5 | 98.57 | +0.23 [-0.20, +0.74] (n 50) | tie | yes |
| qwen3.5-27b-farmshare | 97.61 | +1.19 [-0.73, +3.76] (n 50) | trails | yes |
| gemini3.5-flash-lite | 97.56 | +1.24 [+0.56, +2.02] (n 50) | trails | no |
| gemini3.5-flash | 97.34 | +1.46 [-1.00, +5.23] (n 50) | trails | yes |
| qwen3.6-27b-farmshare | 97.22 | +1.58 [+0.08, +3.98] (n 50) | trails | no |
| qwen3.6-35b-a3b-farmshare | 96.45 | +2.35 [+0.30, +5.67] (n 50) | trails | no |
| gemini3.1-flash-lite | 96.36 | +2.43 [+0.37, +5.82] (n 50) | trails | no |
| qwen3.5-397b | 96.18 | +2.62 [+0.66, +5.83] (n 50) | trails | no |
| qwen3-vl-235b | 96.09 | +2.71 [+0.59, +6.05] (n 50) | trails | no |
| infinity-parser2-pro-sherlock | 95.84 | +2.96 [+0.50, +6.12] (n 50) | trails | no |
| qwen3.6-35b-a3b | 95.69 | +3.10 [+0.65, +6.65] (n 50) | trails | no |
| mistral-ocr-4-1 | 95.68 | +3.11 [+0.73, +6.30] (n 50) | trails | no |
| qwen3.5-9b-sherlock | 95.64 | +3.16 [+0.62, +7.52] (n 50) | trails | no |
| qwen3.6-27b | 95.54 | +3.26 [+0.19, +7.96] (n 50) | trails | no |
| gpt5.4-mini | 95.49 | +3.30 [+0.38, +8.03] (n 50) | trails | no |
| mistral-large4 | 95.46 | +3.33 [+0.58, +7.10] (n 50) | trails | no |
| gpt5.6-luna | 94.98 | +3.82 [+0.67, +8.68] (n 50) | trails | no |
| gemma4-31b | 94.74 | +4.06 [+1.33, +8.49] (n 50) | trails | no |
| paddleocr-vl1.6-bf16 | 93.69 | +5.11 [+1.07, +10.26] (n 50) | trails | no |
| paddleocr-vl1.6-sherlock | 93.67 | +5.13 [+1.08, +10.30] (n 50) | trails | no |
| mistral-small-24b | 93.53 | +5.26 [+1.39, +10.55] (n 50) | trails | no |
| qwen3.8-flash | 93.42 | +5.38 [+0.54, +11.71] (n 50) | trails | no |
| qwen3.5-9b-mlx4 | 93.32 | +5.48 [+1.27, +11.01] (n 50) | trails | no |
| apple-vision | 92.18 | +6.62 [+3.12, +10.88] (n 50) | trails | no |
| xiaomi-ocr-0-sherlock | 92.04 | +6.75 [+2.74, +11.39] (n 50) | trails | no |
| xiaomi-ocr-0-bf16 | 92.03 | +6.77 [+2.73, +11.42] (n 50) | trails | no |
| qwen3-vl-8b-mlx4 | 91.59 | +7.20 [+2.35, +12.97] (n 50) | trails | no |
| lightonocr3-4b-farmshare | 91.18 | +7.62 [+3.01, +12.85] (n 50) | trails | no |
| churro-3b-farmshare | 90.99 | +7.80 [+3.45, +13.29] (n 50) | trails | no |
| lightonocr-3-4b-mlx8 | 90.81 | +7.98 [+3.23, +13.37] (n 50) | trails | no |
| gemma4-26b-a4b | 89.70 | +9.10 [+3.31, +16.16] (n 50) | trails | no |
| qwen3.5-9b | 89.63 | +9.17 [+3.18, +16.75] (n 50) | trails | no |

### The 96, printed, strict (floor 0.24 hosted, 0.00 Mac pairs)

| route | NES strict | leader minus route [95%] | tie | interval holds 0 |
|---|---|---|---|---|
| claude-sonnet5.5 | 96.32 | leader | |  |
| qwen3.6-35b-a3b-farmshare | 95.43 | +0.89 [-0.38, +2.68] (n 27) | trails | yes |
| qwen3.5-27b-farmshare | 95.13 | +1.18 [-0.10, +3.01] (n 27) | trails | yes |
| qwen3.6-27b-farmshare | 95.13 | +1.18 [+0.03, +2.93] (n 27) | trails | no |
| gemini3.7-flash-gw | 94.97 | +1.35 [-1.98, +6.28] (n 27) | trails | yes |
| qwen3.6-27b | 94.94 | +1.37 [-0.20, +3.52] (n 27) | trails | yes |
| gpt5.4-mini | 94.47 | +1.85 [-3.18, +7.87] (n 27) | trails | yes |
| gpt5.6-luna | 94.33 | +1.99 [-2.19, +5.64] (n 27) | trails | yes |
| qwen3.5-397b | 93.84 | +2.48 [+0.54, +4.93] (n 27) | trails | no |
| qwen3-vl-235b | 93.33 | +2.99 [+0.77, +5.88] (n 27) | trails | no |
| qwen3.5-9b-mlx4 | 92.88 | +3.44 [+0.23, +8.52] (n 27) | trails | no |
| mistral-large4 | 92.70 | +3.62 [+0.60, +8.24] (n 27) | trails | no |
| qwen3.6-35b-a3b | 92.43 | +3.89 [+0.61, +8.18] (n 27) | trails | no |
| qwen3.8-flash | 91.94 | +4.37 [-0.92, +12.73] (n 27) | trails | yes |
| qwen3-vl-8b-mlx4 | 91.79 | +4.53 [+0.30, +11.33] (n 27) | trails | no |
| mistral-ocr-4-1 | 91.74 | +4.58 [+1.48, +8.79] (n 27) | trails | no |
| qwen3.5-9b-sherlock | 91.18 | +5.13 [+0.50, +13.07] (n 27) | trails | no |
| infinity-parser2-pro-sherlock | 90.29 | +6.02 [+1.99, +11.84] (n 27) | trails | no |
| mistral-small-24b | 89.93 | +6.38 [+1.97, +11.53] (n 27) | trails | no |
| qwen3.5-9b | 89.68 | +6.63 [+0.17, +15.56] (n 27) | trails | no |
| gemini3.1-pro | 88.97 | +7.35 [+0.14, +17.78] (n 27) | trails | no |
| churro-3b-farmshare | 88.60 | +7.71 [+2.07, +15.13] (n 27) | trails | no |
| lightonocr3-4b-farmshare | 88.51 | +7.81 [+1.53, +15.19] (n 27) | trails | no |
| gemini3.5-flash | 88.05 | +8.26 [-0.43, +19.20] (n 27) | trails | yes |
| gemini3.5-flash-lite | 87.89 | +8.43 [+1.03, +18.90] (n 27) | trails | no |
| lightonocr-3-4b-mlx8 | 87.88 | +8.43 [+1.98, +15.96] (n 27) | trails | no |
| gemini3.8-flash | 86.96 | +9.35 [-0.09, +20.49] (n 27) | trails | yes |
| gemini3.1-flash-lite | 86.72 | +9.59 [+1.56, +20.07] (n 27) | trails | no |
| paddleocr-vl1.6-sherlock | 86.61 | +9.71 [+3.66, +17.48] (n 27) | trails | no |
| xiaomi-ocr-0-bf16 | 86.30 | +10.01 [+4.84, +16.26] (n 27) | trails | no |
| paddleocr-vl1.6-bf16 | 86.18 | +10.14 [+3.86, +17.94] (n 27) | trails | no |
| xiaomi-ocr-0-sherlock | 86.17 | +10.15 [+4.88, +16.49] (n 27) | trails | no |
| gemma4-31b | 83.82 | +12.50 [+3.99, +22.97] (n 27) | trails | no |
| apple-vision | 82.34 | +13.98 [+5.45, +23.96] (n 27) | trails | no |
| gemma4-26b-a4b | 74.24 | +22.08 [+9.75, +36.58] (n 27) | trails | no |

### The 96, handwritten, strict (floor 0.60 hosted, 0.00 Mac pairs)

| route | NES strict | leader minus route [95%] | tie | interval holds 0 |
|---|---|---|---|---|
| gemini3.8-flash | 95.81 | leader | |  |
| gemini3.7-flash-gw | 95.05 | +0.76 [-0.59, +2.87] (n 16) | trails | yes |
| gemini3.1-pro | 93.98 | +1.84 [+0.04, +4.25] (n 16) | trails | no |
| qwen3.6-27b-farmshare | 92.80 | +3.01 [+1.23, +4.79] (n 16) | trails | no |
| gemini3.5-flash | 92.69 | +3.12 [+0.88, +5.87] (n 16) | trails | no |
| qwen3.6-27b | 92.61 | +3.20 [+1.30, +5.20] (n 16) | trails | no |
| claude-sonnet5.5 | 92.50 | +3.31 [+0.21, +7.33] (n 16) | trails | no |
| mistral-large4 | 92.20 | +3.62 [+1.77, +5.48] (n 16) | trails | no |
| qwen3.5-27b-farmshare | 92.10 | +3.71 [+1.65, +6.17] (n 16) | trails | no |
| gemini3.5-flash-lite | 91.96 | +3.85 [+1.61, +6.64] (n 16) | trails | no |
| infinity-parser2-pro-sherlock | 91.76 | +4.05 [+1.81, +6.72] (n 16) | trails | no |
| qwen3-vl-235b | 91.59 | +4.22 [+2.16, +6.96] (n 16) | trails | no |
| qwen3.8-flash | 91.25 | +4.56 [+2.14, +7.52] (n 16) | trails | no |
| qwen3.5-9b | 91.00 | +4.81 [+2.55, +7.78] (n 16) | trails | no |
| gemma4-31b | 90.98 | +4.83 [+2.67, +7.38] (n 16) | trails | no |
| qwen3.5-397b | 90.84 | +4.97 [+2.51, +7.95] (n 16) | trails | no |
| qwen3.5-9b-sherlock | 90.70 | +5.11 [+2.34, +8.62] (n 16) | trails | no |
| lightonocr-3-4b-mlx8 | 89.91 | +5.90 [+3.32, +8.66] (n 16) | trails | no |
| qwen3.6-35b-a3b-farmshare | 89.84 | +5.97 [+2.06, +11.44] (n 16) | trails | no |
| qwen3-vl-8b-mlx4 | 89.24 | +6.57 [+4.15, +9.36] (n 16) | trails | no |
| gpt5.4-mini | 89.13 | +6.69 [+3.93, +9.54] (n 16) | trails | no |
| mistral-ocr-4-1 | 89.10 | +6.71 [+3.35, +10.90] (n 16) | trails | no |
| lightonocr3-4b-farmshare | 88.85 | +6.97 [+3.56, +10.81] (n 16) | trails | no |
| qwen3.6-35b-a3b | 88.83 | +6.99 [+2.89, +12.97] (n 16) | trails | no |
| qwen3.5-9b-mlx4 | 88.06 | +7.75 [+4.34, +11.54] (n 16) | trails | no |
| churro-3b-farmshare | 87.48 | +8.33 [+4.94, +12.15] (n 16) | trails | no |
| gemma4-26b-a4b | 86.75 | +9.06 [+5.08, +14.19] (n 16) | trails | no |
| gemini3.1-flash-lite | 86.55 | +9.26 [+1.66, +22.21] (n 16) | trails | no |
| xiaomi-ocr-0-bf16 | 86.04 | +9.77 [+6.74, +13.00] (n 16) | trails | no |
| xiaomi-ocr-0-sherlock | 85.99 | +9.82 [+6.76, +13.16] (n 16) | trails | no |
| gpt5.6-luna | 85.20 | +10.61 [+7.10, +14.34] (n 16) | trails | no |
| paddleocr-vl1.6-bf16 | 80.37 | +15.44 [+8.53, +25.45] (n 16) | trails | no |
| paddleocr-vl1.6-sherlock | 80.06 | +15.75 [+8.77, +25.84] (n 16) | trails | no |
| mistral-small-24b | 79.90 | +15.91 [+5.55, +29.92] (n 16) | trails | no |
| apple-vision | 60.58 | +35.23 [+26.41, +44.22] (n 16) | trails | no |

### The 96, hands16, strict (floor 0.60 hosted, 0.00 Mac pairs)

| route | NES strict | leader minus route [95%] | tie | interval holds 0 |
|---|---|---|---|---|
| gemini3.8-flash | 95.81 | leader | |  |
| gemini3.7-flash-gw | 95.05 | +0.76 [-0.59, +2.87] (n 16) | trails | yes |
| gemini3.1-pro | 93.98 | +1.84 [+0.04, +4.25] (n 16) | trails | no |
| gemini3.5-flash | 92.69 | +3.12 [+0.88, +5.87] (n 16) | trails | no |
| qwen3.6-27b | 92.61 | +3.20 [+1.30, +5.20] (n 16) | trails | no |
| claude-sonnet5.5 | 92.50 | +3.31 [+0.21, +7.33] (n 16) | trails | no |
| qwen3.5-27b-farmshare | 92.23 | +3.58 [+1.52, +6.01] (n 16) | trails | no |
| mistral-large4 | 92.20 | +3.62 [+1.77, +5.48] (n 16) | trails | no |
| gemini3.5-flash-lite | 91.96 | +3.85 [+1.61, +6.64] (n 16) | trails | no |
| infinity-parser2-pro-sherlock | 91.76 | +4.05 [+1.81, +6.72] (n 16) | trails | no |
| qwen3-vl-235b | 91.59 | +4.22 [+2.16, +6.96] (n 16) | trails | no |
| qwen3.8-flash | 91.25 | +4.56 [+2.14, +7.52] (n 16) | trails | no |
| qwen3.5-9b | 91.00 | +4.81 [+2.55, +7.78] (n 16) | trails | no |
| gemma4-31b | 90.98 | +4.83 [+2.67, +7.38] (n 16) | trails | no |
| qwen3.5-397b | 90.84 | +4.97 [+2.51, +7.95] (n 16) | trails | no |
| lightonocr-3-4b-mlx8 | 89.91 | +5.90 [+3.32, +8.66] (n 16) | trails | no |
| qwen3-vl-8b-mlx4 | 89.24 | +6.57 [+4.15, +9.36] (n 16) | trails | no |
| lightonocr3-4b-farmshare | 89.21 | +6.60 [+3.41, +10.13] (n 16) | trails | no |
| gpt5.4-mini | 89.13 | +6.69 [+3.93, +9.54] (n 16) | trails | no |
| mistral-ocr-4-1 | 89.10 | +6.71 [+3.35, +10.90] (n 16) | trails | no |
| qwen3.6-35b-a3b | 88.83 | +6.99 [+2.89, +12.97] (n 16) | trails | no |
| qwen3.5-9b-mlx4 | 88.06 | +7.75 [+4.34, +11.54] (n 16) | trails | no |
| churro-3b-farmshare | 87.60 | +8.21 [+4.97, +11.83] (n 16) | trails | no |
| gemma4-26b-a4b | 86.75 | +9.06 [+5.08, +14.19] (n 16) | trails | no |
| gemini3.1-flash-lite | 86.55 | +9.26 [+1.66, +22.21] (n 16) | trails | no |
| xiaomi-ocr-0-sherlock | 86.18 | +9.63 [+6.59, +12.97] (n 16) | trails | no |
| xiaomi-ocr-0-bf16 | 86.04 | +9.77 [+6.74, +13.00] (n 16) | trails | no |
| gpt5.6-luna | 85.20 | +10.61 [+7.10, +14.34] (n 16) | trails | no |
| paddleocr-vl1.6-bf16 | 80.37 | +15.44 [+8.53, +25.45] (n 16) | trails | no |
| paddleocr-vl1.6-sherlock | 80.22 | +15.59 [+8.62, +25.70] (n 16) | trails | no |
| mistral-small-24b | 79.90 | +15.91 [+5.55, +29.92] (n 16) | trails | no |
| apple-vision | 60.58 | +35.23 [+26.41, +44.22] (n 16) | trails | no |

### The 895, per stratum

| group | pairs (strict) | ties strict | ties answered |
|---|---|---|---|
| L1 | 28 | 10 | 9 |
| L2 | 28 | 12 | 11 |
| L3 | 28 | 16 | 13 |
| L4 | 28 | 6 | 2 |
| L5 | 91 | 17 | 19 |
| L6 | 78 | 12 | 7 |
| L7 | 91 | 16 | 17 |
| L8 | 66 | 26 | 18 |
| L9 | 28 | 19 | 19 |
| N1 | 55 | 16 | 12 |
| N2 | 28 | 7 | 8 |
| N3 | 66 | 17 | 7 |
| N4 | 66 | 17 | 19 |
| N5 | 28 | 15 | 24 |
| N6 | 28 | 7 | 7 |
| L1-L3 | 28 | 11 | 8 |
| all | 125 | 27 | 29 |

### The 895, L1-L3 pooled, strict (no floor)

| route | NES strict | leader minus route [95%] | tie | interval holds 0 |
|---|---|---|---|---|
| infinity-parser2-pro-sherlock | 89.30 | leader | |  |
| gemini3.7-flash-gw | 89.13 | +0.17 [-1.18, +1.38] (n 240) | tie | yes |
| lightonocr3-4b-farmshare | 86.21 | +3.09 [+1.57, +4.64] (n 240) | trails | no |
| qwen3.6-35b-a3b-farmshare | 86.15 | +3.16 [+1.48, +4.98] (n 240) | trails | no |
| qwen3.6-27b-farmshare | 85.99 | +3.32 [+1.99, +4.83] (n 240) | trails | no |
| qwen3.5-27b-farmshare | 85.01 | +4.30 [+2.53, +6.25] (n 240) | trails | no |
| xiaomi-ocr-0-sherlock | 84.85 | +4.46 [+2.98, +5.82] (n 240) | trails | no |
| paddleocr-vl1.6-sherlock | 75.94 | +13.37 [+10.84, +15.95] (n 240) | trails | no |

## Measurement card

- **Truth:** the 96's adjudicated truth, drafted by Gemini 3.8 Flash and Claude Opus 5.5, so every Gemini and Claude
  route is a relative of a drafter and its pairs with other routes lean its way (OCR-1); a tie between two relatives
  is unaffected in direction but not in size. hands16 is on the hand pages' truth after the owner's blind hand sheet
  (2026-10-31), still drafter-biased where the sheet did not reach. The 895's truth is the public sets' own,
  independent of every route.
- **Selection:** all 95 scored pages of the 96 (p081 apart, its truth uncorrectable) and every public page a route
  read; no page chosen by a route's result or ABBYY text. The 96 were drawn through a 20-word Vision filter (19 pages
  replaced), so Vision's pairs are on pages it could read (W46.ocr-vision-unfiltered).
- **Comparison:** each pair on the same pages with each route's committed reading and settings; strict scores a
  failure as 0, answered keeps the pages both answered (its n is in each entry). On the 895 a route that read only
  some strata is paired only where both read; `all` is the pages both read, so its n differs between pairs.
- **Noise:** n per entry; the interval is a page bootstrap; the rerun floors as above (Gemini 3.7 Flash's 0.24
  range doubled, its per-kind ranges doubled; Qwen3-VL 8B 4-bit 0.00). The cluster floor is a borrowed figure, not a
  measured range, and the per-kind ranges rest on three runs of 16 to 50 pages.
- **Scope:** pairs, not ranks: a route that ties with both of two routes that do not tie with each other is not
  ordered by this file. Per-kind groups on the 96 are 16 to 50 pages, so their intervals are wide: a gap above
  the floor whose interval holds 0 is no tie under the owner's rule, but nor is it shown to be real; hands16 is strict only; the two mixed pages are no group;
  strata under 20 pages (L9, 15) are descriptive. Not here, for want of per-page scores in these files: Apple
  FM 27, the PP-OCRv6 kraken blla route, the kraken specialists on the 96, the cascade rows, and Qwen3.5 9B
  Sherlock on the 895 (its 895 scores are in `ocr-logprob-pages.csv`, and the table gives it no public figure).
