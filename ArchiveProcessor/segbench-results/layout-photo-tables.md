NES % strict (markup-stripped in brackets), pages answered / pages; a page with no region read scores 0. Δ is a paired mean difference in NES points with its 95% bootstrap interval.

## Bench pages

### L9

| arm | NES (stripped) | answered | Δ whole |
|---|---:|---:|---:|
| whole | 29.2 (29.2) | 6/15 | – |
| pp-doclayoutv3 | 86.2 (86.2) | 15/15 | +57.0 [+37.5, +74.8] |
| yolo_newsocr | 91.1 (91.1) | 15/15 | +61.9 [+41.8, +80.5] |
| yolo_appsort | 73.5 (73.5) | 15/15 | +44.3 [+19.0, +67.6] |
| heron | 65.0 (65.0) | 15/15 | +35.8 [+11.3, +58.7] |
| vision_doc | 16.8 (16.8) | 14/15 | -12.4 [-30.5, +2.5] |

### L4

| arm | NES (stripped) | answered | Δ whole |
|---|---:|---:|---:|
| whole | 59.7 (59.7) | 79/80 | – |
| pp-doclayoutv3 | 48.9 (48.9) | 79/80 | -10.8 [-14.8, -6.8] |
| yolo_newsocr | 1.1 (1.1) | 44/80 | -58.6 [-62.0, -55.1] |
| yolo_appsort | 1.6 (1.6) | 30/80 | -58.1 [-61.9, -54.1] |
| heron | 51.5 (51.5) | 80/80 | -8.2 [-11.9, -4.4] |
| vision_doc | 40.9 (40.9) | 79/80 | -18.8 [-22.6, -15.0] |

### the 96

| arm | NES (stripped) | answered | Δ whole |
|---|---:|---:|---:|
| whole | 90.9 (91.0) | 95/96 | – |
| pp-doclayoutv3 | 84.9 (85.0) | 95/96 | -6.0 [-9.7, -2.6] |
| yolo_newsocr | 70.9 (70.9) | 88/96 | -20.0 [-27.3, -13.3] |
| yolo_appsort | 74.1 (74.2) | 84/96 | -16.8 [-23.6, -10.3] |
| heron | 87.1 (87.2) | 96/96 | -3.9 [-7.7, -0.3] |
| vision_doc | 79.8 (79.9) | 96/96 | -11.1 [-14.9, -7.5] |

### handwritten

| arm | NES (stripped) | answered | Δ whole |
|---|---:|---:|---:|
| whole | 85.8 (85.9) | 16/16 | – |
| pp-doclayoutv3 | 70.5 (70.4) | 15/16 | -15.3 [-28.2, -4.4] |
| yolo_newsocr | 11.0 (11.0) | 11/16 | -74.8 [-84.5, -62.0] |
| yolo_appsort | 14.2 (14.2) | 6/16 | -71.5 [-84.2, -55.8] |
| heron | 72.6 (72.7) | 16/16 | -13.2 [-28.6, -1.2] |
| vision_doc | 63.5 (63.6) | 16/16 | -22.3 [-32.5, -12.9] |

### typed, no table or clipping

| arm | NES (stripped) | answered | Δ whole |
|---|---:|---:|---:|
| whole | 94.0 (94.0) | 40/41 | – |
| pp-doclayoutv3 | 94.7 (94.7) | 41/41 | +0.6 [-2.7, +4.4] |
| yolo_newsocr | 92.9 (92.9) | 41/41 | -1.2 [-4.5, +2.6] |
| yolo_appsort | 95.8 (95.8) | 41/41 | +1.7 [-0.9, +5.1] |
| heron | 96.3 (96.3) | 41/41 | +2.2 [-0.2, +5.5] |
| vision_doc | 86.5 (86.5) | 41/41 | -7.6 [-12.3, -2.7] |

### clippings

| arm | NES (stripped) | answered | Δ whole |
|---|---:|---:|---:|
| whole | 86.9 (86.9) | 13/13 | – |
| pp-doclayoutv3 | 81.8 (81.8) | 13/13 | -5.1 [-15.0, +3.1] |
| yolo_newsocr | 86.6 (86.5) | 13/13 | -0.3 [-11.1, +8.8] |
| yolo_appsort | 77.1 (77.1) | 13/13 | -9.8 [-23.7, +2.8] |
| heron | 81.9 (81.9) | 13/13 | -5.0 [-16.8, +5.1] |
| vision_doc | 71.0 (71.0) | 13/13 | -15.9 [-29.8, -3.7] |

### tables

| arm | NES (stripped) | answered | Δ whole |
|---|---:|---:|---:|
| whole | 91.9 (92.0) | 12/12 | – |
| pp-doclayoutv3 | 82.8 (83.6) | 12/12 | -9.1 [-18.3, -2.3] |
| yolo_newsocr | 76.4 (76.5) | 12/12 | -15.5 [-28.8, -4.5] |
| yolo_appsort | 83.5 (84.3) | 12/12 | -8.4 [-17.5, -1.4] |
| heron | 87.8 (88.5) | 12/12 | -4.2 [-14.4, +4.6] |
| vision_doc | 88.6 (89.5) | 12/12 | -3.3 [-10.2, +5.7] |

## Real5-OmniDocBench (155 English plain-text pages a condition)

| condition | arm | NES (stripped) | answered | Δ whole | Δ Scanning |
|---|---|---:|---:|---:|---:|
| scan | whole | 92.1 (92.0) | 154/155 | – | – |
| scan | yolo_appsort | 81.2 (81.2) | 153/155 | -10.8 [-14.7, -7.0] | – |
| scan | pp-doclayoutv3 | 91.7 (91.7) | 154/155 | -0.4 [-3.4, +2.5] | – |
| scan | heron | 82.2 (82.2) | 155/155 | -9.8 [-13.5, -6.2] | – |
| scan | vision_doc | 83.7 (83.7) | 154/155 | -8.4 [-11.8, -5.3] | – |
| illum | whole | 93.0 (93.0) | 153/155 | – | +0.9 [-0.6, +2.5] |
| illum | yolo_appsort | 79.6 (79.6) | 152/155 | -13.4 [-17.6, -9.1] | -1.6 [-3.7, +0.4] |
| illum | pp-doclayoutv3 | 89.9 (89.9) | 155/155 | -3.1 [-5.9, -0.3] | -1.8 [-4.1, +0.6] |
| illum | heron | 79.3 (79.2) | 155/155 | -13.8 [-17.8, -9.6] | -3.0 [-5.4, -0.7] |
| illum | vision_doc | 70.2 (70.2) | 154/155 | -22.8 [-27.5, -18.2] | -13.4 [-17.1, -9.9] |
| warp | whole | 88.0 (88.0) | 147/155 | – | -4.1 [-7.7, -0.9] |
| warp | yolo_appsort | 69.6 (69.6) | 141/155 | -18.4 [-24.2, -12.7] | -11.7 [-17.0, -6.7] |
| warp | pp-doclayoutv3 | 85.1 (85.1) | 154/155 | -2.9 [-7.0, +1.3] | -6.6 [-9.8, -3.5] |
| warp | heron | 75.8 (75.8) | 155/155 | -12.2 [-16.5, -7.9] | -6.4 [-9.2, -3.9] |
| warp | vision_doc | 61.3 (61.3) | 152/155 | -26.7 [-31.6, -21.8] | -22.3 [-26.4, -18.3] |
| skew | whole | 91.3 (91.3) | 152/155 | – | -0.8 [-3.3, +1.5] |
| skew | yolo_appsort | 41.1 (41.1) | 97/155 | -50.2 [-57.2, -43.0] | -40.1 [-47.2, -33.1] |
| skew | pp-doclayoutv3 | 81.8 (81.7) | 154/155 | -9.5 [-13.3, -5.8] | -10.0 [-13.0, -6.8] |
| skew | heron | 70.3 (70.3) | 154/155 | -20.9 [-25.5, -16.4] | -11.9 [-15.7, -8.2] |
| skew | vision_doc | 67.5 (67.5) | 154/155 | -23.7 [-28.0, -19.5] | -16.1 [-19.7, -12.6] |

## The staged pre-step on Warping and Skew

Quad found on 310 of 310 Warping and Skew photographs. Δ raw is against the same arm on the raw photograph.

| copy | arm | NES (stripped) | answered | Δ raw |
|---|---|---:|---:|---:|
| warp-quad | whole | 86.8 (86.8) | 144/155 | -1.2 [-4.1, +1.5] |
| warp-quad | yolo_appsort | 78.7 (78.7) | 152/155 | +9.1 [+3.9, +14.4] |
| warp-quad | pp-doclayoutv3 | 85.9 (85.9) | 153/155 | +0.8 [-1.3, +2.9] |
| warp-uvdoc | whole | 91.1 (91.2) | 153/155 | +3.2 [-0.4, +7.0] |
| warp-uvdoc | yolo_appsort | 82.9 (82.9) | 152/155 | +13.3 [+8.0, +18.9] |
| warp-uvdoc | pp-doclayoutv3 | 88.3 (88.3) | 154/155 | +3.2 [+0.2, +6.3] |
| skew-quad | whole | 93.0 (93.0) | 154/155 | +1.7 [-0.3, +4.2] |
| skew-quad | yolo_appsort | 78.2 (78.2) | 152/155 | +37.1 [+30.4, +44.0] |
| skew-quad | pp-doclayoutv3 | 89.1 (89.1) | 154/155 | +7.4 [+4.9, +10.0] |
| skew-uvdoc | whole | 91.6 (91.7) | 154/155 | +0.3 [-2.1, +3.0] |
| skew-uvdoc | yolo_appsort | 78.0 (77.9) | 150/155 | +36.9 [+29.7, +44.0] |
| skew-uvdoc | pp-doclayoutv3 | 88.8 (88.8) | 154/155 | +7.1 [+4.1, +10.0] |

## Measurement card

- **Truth.**
  - Real5: OmniDocBench v1.5's human-annotated text for each page, the same truth in every folder (Real5
    photographs the same pages again). No scored route drafted it.
  - The 96: the owner's truth (`ocr-truth.md`), drafted by Claude Opus 5.5 and Gemini 3.8 Flash and
    adjudicated by the owner where they differed, corrected on 2026-10-29. Neither drafter is scored here.
  - L9 and L4: the public sets' published transcriptions.
  - The owner checked nothing specific to this item.
- **Selection.** Real5 pages were chosen by src_omnidoc's plain-text rule over all English pages, not by any
  route's reading. The bench pages are the 96, L9 and L4 that W46.ocr-regions read. No ABBYY text was used.
- **Comparison.**
  - Inputs: one reader and one request in every arm, on the same 2,400 px copies; the detectors see the frozen
    copies at their own input sizes.
  - The bench's whole-page readings come from the open sweep and the truth-96 run (the same model and prompt
    W46.ocr-regions compared against). Real5's whole-page readings come from this pack.
  - Both OCR sets: the owner's 96, and L9 and L4 of the 895.
- **Noise.**
  - n: 155 a Real5 cell; 96, 16 handwritten, 15 L9 and 80 L4 on the bench.
  - One reading at temperature 0. The 95 crops that hit the token cap count as failed.
  - The rerun floor on the 96 is `ocr-rerun-noise.md`'s 0.49 NES points; none was measured on Real5.
  - A paired interval that crosses 0 is a tie. Per-kind groups under 20 pages are descriptive.
- **Scope.**
  - One reader. W46.ocr-regions found that the region gain depends on the reader and matters most for small
    readers, so a larger reader may need regions less.
  - Real5 is modern print photographed in a lab, not archival pages. Our own photographs of skewed or warped
    pages are not here.
  - The detectors' thresholds are the shipped or maker defaults, not tuned.
  - Heron and Vision were not tried after the pre-step.
  - The figures do not say which ordering suits each detector; that is W46.layout-order.
