# Gemini 3.7 Flash on the whole page, PP-DocLayoutV3 regions and overlapping tiles (W46.ocr-regions-paid)

Stanford AI API gateway, temperature 0, low reasoning, 8,192 output tokens, the panel prompt, the same frozen 2,400 px images and crop geometry as W46.ocr-regions (`corpus/regions_gateway.py`). NES is the panel scorer; a page or crop that returned nothing counts as empty. Whole-page readings of the 96 are the earlier gateway item's, reused after exact request-hash checks. Prices are estimates at $0.75/$3.75 per million tokens; the gateway publishes no price. This item's settled new calls: 1445, about $3.67; the gateway reported no cost of its own for these calls.

## The 96 owner pages

| group | arm | NES % | answered | Δ whole (points, 95% CI) | failed / crops | cost / 1,000 pages |
|---|---|---:|---:|---:|---:|---:|
| the 96 (96) | whole page | 96.7 | 96/96 | — | — | $3.89 |
| the 96 (96) | PP-DocLayoutV3 regions | 84.8 | 95/96 | -11.9 (-15.6 to -8.5) | 0/826 | $17.44 |
| the 96 (96) | overlapping tiles | 91.0 | 96/96 | -5.7 (-8.3 to -3.3) | 0/292 | $9.27 |
| kind:typewritten (50) | whole page | 98.8 | 50/50 | — | — | $3.99 |
| kind:typewritten (50) | PP-DocLayoutV3 regions | 92.2 | 50/50 | -6.6 (-10.5 to -3.3) | 0/367 | $14.14 |
| kind:typewritten (50) | overlapping tiles | 98.5 | 50/50 | -0.3 (-1.0 to +0.3) | 0/149 | $9.31 |
| kind:printed (28) | whole page | 94.9 | 28/28 | — | — | $3.87 |
| kind:printed (28) | PP-DocLayoutV3 regions | 81.1 | 28/28 | -13.8 (-19.8 to -8.8) | 0/360 | $26.52 |
| kind:printed (28) | overlapping tiles | 79.3 | 28/28 | -15.6 (-22.7 to -8.9) | 0/89 | $9.10 |
| kind:handwritten (16) | whole page | 95.0 | 16/16 | — | — | $3.84 |
| kind:handwritten (16) | PP-DocLayoutV3 regions | 70.3 | 15/16 | -24.8 (-39.1 to -12.4) | 0/74 | $11.06 |
| kind:handwritten (16) | overlapping tiles | 90.5 | 16/16 | -4.5 (-9.2 to -1.1) | 0/48 | $9.29 |
| clippings (13) | whole page | 95.6 | 13/13 | — | — | $3.90 |
| clippings (13) | PP-DocLayoutV3 regions | 79.7 | 13/13 | -16.0 (-26.9 to -7.9) | 0/167 | $27.78 |
| clippings (13) | overlapping tiles | 76.9 | 13/13 | -18.7 (-30.6 to -7.4) | 0/44 | $10.47 |
| tables (12) | whole page | 99.0 | 12/12 | — | — | $3.21 |
| tables (12) | PP-DocLayoutV3 regions | 83.4 | 12/12 | -15.5 (-28.4 to -4.7) | 0/111 | $17.32 |
| tables (12) | overlapping tiles | 97.7 | 12/12 | -1.2 (-3.7 to +0.6) | 0/35 | $7.74 |
| handwritten (16) | whole page | 95.0 | 16/16 | — | — | $3.84 |
| handwritten (16) | PP-DocLayoutV3 regions | 70.3 | 15/16 | -24.8 (-39.1 to -12.4) | 0/74 | $11.06 |
| handwritten (16) | overlapping tiles | 90.5 | 16/16 | -4.5 (-9.2 to -1.1) | 0/48 | $9.29 |
| typed, no table or clipping (41) | whole page | 98.8 | 41/41 | — | — | $4.16 |
| typed, no table or clipping (41) | PP-DocLayoutV3 regions | 95.4 | 41/41 | -3.4 (-5.7 to -1.6) | 0/292 | $14.09 |
| typed, no table or clipping (41) | overlapping tiles | 98.4 | 41/41 | -0.4 (-1.2 to +0.3) | 0/123 | $9.52 |

## Public pages (12, 3 a stratum — a labelled sample, not a set result)

Three pages a stratum drawn by stable id hash (W46.ocr-regions-paid-pp read the eight beyond the pilot).

| stratum | arm | NES % | failed / crops | order edit |
|---|---|---:|---:|---:|
| L9 | whole page | 97.8 | — | 0.0 |
| L9 | PP-DocLayoutV3 regions | 82.4 | 0/240 | 0.03 |
| L9 | overlapping tiles | 43.8 | 0/7 | 0.6851 |
| L4 | whole page | 75.8 | — | 0.0476 |
| L4 | PP-DocLayoutV3 regions | 63.4 | 0/17 | 0.0 |
| L4 | overlapping tiles | 76.4 | 0/8 | 0.0 |
| L3 | whole page | 98.2 | — | 0.0 |
| L3 | PP-DocLayoutV3 regions | 92.1 | 0/20 | 0.0 |
| L3 | overlapping tiles | 96.4 | 0/7 | 0.0 |
| L1 | whole page | 90.2 | — | 0.0 |
| L1 | PP-DocLayoutV3 regions | 86.4 | 0/9 | 0.0 |
| L1 | overlapping tiles | 80.7 | 0/7 | 0.0 |

## Table pages: strict NES against NES with markup stripped (diagnostic)

| arm | pages | strict | markup stripped | pages with markup |
|---|---:|---:|---:|---:|
| whole page | 12 | 99.0 | 99.1 | 1 |
| PP-DocLayoutV3 regions | 12 | 83.4 | 83.5 | 3 |
| overlapping tiles | 12 | 97.7 | 97.9 | 1 |

## Measurement card

- **Truth.** The owner's 96 pages (99 less the three agreement-only letters), truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner where they differed (`ocr-truth.md`), corrected on 2026-10-29 (W46.truth-edits). Words the two drafters wrote alike were not adjudicated; since then the owner has checked samples of them blind: 59 places on 20 pages where Qwen3.6-27B differs (answered 2026-10-21, `ocr-truth-bias-score.md`: 4 truth errors, the bias not material) and every place where Qwen3.6-27B or LightOnOCR-3 4B differs on the 16 hand pages, with 19 typed controls (answered 2026-10-31, `ocr-hands-rescore.md`: 12 corrections, 10 places unresolved). Agreed words that no third-family reader disputes stay unchecked, so a drafter-family route can still gain where the truth shares its mistake. The figures here are rescored on that truth as it now stands. The public pages are scored on their own published transcriptions as the bench corpus normalises them (`bench-corpus/README.md`), a truth no route drafted.
- **Selection.** All 96 owner accuracy pages for every arm; on the public set three pages a stratum in four strata, drawn by stable id hash. None is chosen by a route's reading or by ABBYY text.
- **Comparison.** One model and setting (Gemini 3.7 Flash through the gateway, temperature 0, low reasoning, 8,192 tokens, the panel prompt) on the same frozen 2,400 px images; the arms differ only in what is sent: the whole page, PP-DocLayoutV3 regions or overlapping tiles, each arm's crop readings joined into one page reading for the one scorer. A failed page or crop is empty.
- **Noise.** n = 96 pages; the Δ intervals are 95% paired page bootstraps against the whole page. The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired interval across 0, is a tie. That floor is Gemini 3.7 Flash's whole-page rerun spread; the crop arms were read once. The public rows are 3 pages a stratum, anecdote, not a set result.
- **Scope.** One model, one layout detector and one tile geometry; it does not rank region-first reading for other models. Prices are estimates at the stated rates, the gateway publishing none.

