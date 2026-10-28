# Gemini 3.7 Flash on the whole page, PP-DocLayoutV3 regions and overlapping tiles (W46.ocr-regions-paid)

Stanford AI API gateway, temperature 0, low reasoning, 8,192 output tokens, the panel prompt, the same frozen 2,400 px images and crop geometry as W46.ocr-regions (`corpus/regions_gateway.py`). NES is the panel scorer; a page or crop that returned nothing counts as empty. Whole-page readings of the 96 are the earlier gateway item's, reused after exact request-hash checks. Prices are estimates at $0.75/$3.75 per million tokens; the gateway returns no bill. This item's settled new calls: 434, about $1.31.

## The 96 owner pages

| group | arm | NES % | answered | Δ whole (points, 95% CI) | failed / crops | cost / 1,000 pages |
|---|---|---:|---:|---:|---:|---:|
| the 96 (96) | whole page | 96.7 | 96/96 | — | — | $3.89 |
| the 96 (96) | overlapping tiles | 91.0 | 96/96 | -5.7 (-8.3 to -3.3) | 0/292 | $9.27 |
| kind:typewritten (50) | whole page | 98.8 | 50/50 | — | — | $3.99 |
| kind:typewritten (50) | overlapping tiles | 98.5 | 50/50 | -0.3 (-1.0 to +0.3) | 0/149 | $9.31 |
| kind:printed (28) | whole page | 94.9 | 28/28 | — | — | $3.87 |
| kind:printed (28) | overlapping tiles | 79.3 | 28/28 | -15.6 (-22.7 to -8.9) | 0/89 | $9.10 |
| kind:handwritten (16) | whole page | 95.1 | 16/16 | — | — | $3.84 |
| kind:handwritten (16) | overlapping tiles | 90.6 | 16/16 | -4.5 (-9.1 to -1.1) | 0/48 | $9.29 |
| clippings (13) | whole page | 95.6 | 13/13 | — | — | $3.90 |
| clippings (13) | overlapping tiles | 76.9 | 13/13 | -18.7 (-30.6 to -7.4) | 0/44 | $10.47 |
| tables (12) | whole page | 99.0 | 12/12 | — | — | $3.21 |
| tables (12) | overlapping tiles | 97.8 | 12/12 | -1.2 (-3.7 to +0.6) | 0/35 | $7.74 |
| handwritten (16) | whole page | 95.1 | 16/16 | — | — | $3.84 |
| handwritten (16) | overlapping tiles | 90.6 | 16/16 | -4.5 (-9.1 to -1.1) | 0/48 | $9.29 |
| typed, no table or clipping (41) | whole page | 98.8 | 41/41 | — | — | $4.16 |
| typed, no table or clipping (41) | overlapping tiles | 98.4 | 41/41 | -0.4 (-1.2 to +0.3) | 0/123 | $9.52 |

Not read on the 96: PP-DocLayoutV3 regions — the item's $3 cap did not fit it (residual W46.ocr-regions-paid-pp).

## Owner pilot pages (4, one an annotation group — every arm, a labelled sample)

| arm | NES % | Δ whole (points) | failed / crops |
|---|---:|---:|---:|
| whole page | 97.2 | — | — |
| PP-DocLayoutV3 regions | 91.5 | -5.8 | 0/38 |
| overlapping tiles | 97.9 | +0.7 | 0/15 |

## Public pilot pages (4, one a stratum — a labelled sample, not a set result)

The other eight frozen public pages were not read: the full scope projected above the $3 item cap.

| stratum | arm | NES % | failed / crops | order edit |
|---|---|---:|---:|---:|
| L9 | whole page | 98.0 | — | 0.0 |
| L9 | PP-DocLayoutV3 regions | 87.1 | 0/71 | 0.0597 |
| L9 | overlapping tiles | 45.0 | 0/2 | 0.6667 |
| L4 | whole page | 68.3 | — | 0.1429 |
| L4 | PP-DocLayoutV3 regions | 67.3 | 0/8 | 0.0 |
| L4 | overlapping tiles | 67.5 | 0/2 | 0.0 |
| L3 | whole page | 98.6 | — | 0.0 |
| L3 | PP-DocLayoutV3 regions | 98.0 | 0/9 | 0.0 |
| L3 | overlapping tiles | 94.8 | 0/2 | 0.0 |
| L1 | whole page | 98.6 | — | 0.0 |
| L1 | PP-DocLayoutV3 regions | 99.0 | 0/4 | 0.0 |
| L1 | overlapping tiles | 94.9 | 0/2 | 0.0 |

## Table pages: strict NES against NES with markup stripped (diagnostic)

| arm | pages | strict | markup stripped | pages with markup |
|---|---:|---:|---:|---:|
| whole page | 12 | 99.0 | 99.2 | 1 |
| overlapping tiles | 12 | 97.8 | 97.9 | 1 |
