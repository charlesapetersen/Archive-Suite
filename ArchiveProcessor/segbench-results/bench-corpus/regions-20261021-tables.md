NES % (pages answered / pages); a failed page scores 0. Δ is the arm against whole page on the same pages, in points.
Order: mean reading-order edit (matched-page count) over pages with two or more matched truth blocks;
lower is better, but each arm has its own matched-page subset, so these means are not paired.
not scorable on the 96, whose truth is kept as one line with no paragraph breaks.

### L9

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 29.2 (6/15) | 91.1 (15/15) | 86.2 (15/15) | 29.6 (10/15) | +61.9 | +57.0 | +0.4 | 0.07 (6) / 0.07 (15) / 0.04 (15) / 0.21 (10) |
| paddleocr-vl1.5 | 0.0 (0/15) | 92.3 (15/15) | 89.7 (15/15) | 8.1 (4/15) | +92.3 | +89.7 | +8.1 | – / 0.06 (15) / 0.04 (15) / 0.17 (2) |
| lightonocr3-4b | 92.5 (15/15) | 88.4 (15/15) | 83.6 (15/15) | 34.7 (10/15) | -4.1 | -8.9 | -57.8 | 0.05 (15) / 0.05 (15) / 0.04 (15) / 0.50 (10) |
| qwen3.6-27b | 93.5 (15/15) | 88.9 (15/15) | 83.0 (15/15) | 25.7 (8/15) | -4.6 | -10.6 | -67.9 | 0.06 (15) / 0.05 (15) / 0.04 (15) / 0.58 (8) |

### L4

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 59.7 (79/80) | 1.2 (45/80) | 48.9 (79/80) | 57.9 (80/80) | -58.5 | -10.8 | -1.7 | 0.18 (79) / 0.25 (2) / 0.21 (75) / 0.21 (80) |
| paddleocr-vl1.5 | 28.2 (47/80) | 1.2 (47/80) | 37.2 (72/80) | 35.8 (72/80) | -27.0 | +9.0 | +7.6 | 0.23 (45) / 0.60 (3) / 0.27 (64) / 0.28 (57) |
| lightonocr3-4b | 55.0 (80/80) | 5.7 (45/80) | 37.7 (78/80) | 52.9 (80/80) | -49.3 | -17.3 | -2.1 | 0.17 (80) / 0.27 (3) / 0.21 (74) / 0.25 (80) |
| qwen3.6-27b | 69.3 (73/80) | 1.3 (45/80) | 53.4 (79/80) | 72.6 (80/80) | -68.0 | -15.9 | +3.3 | 0.13 (73) / 0.17 (3) / 0.22 (76) / 0.12 (80) |

### L3

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 92.0 (80/80) | 71.9 (75/80) | 87.7 (78/80) | 88.3 (80/80) | -20.1 | -4.3 | -3.7 | 0.01 (57) / 0.21 (55) / 0.04 (56) / 0.00 (57) |
| paddleocr-vl1.5 | 92.4 (80/80) | 71.4 (75/80) | 86.9 (79/80) | 91.3 (80/80) | -21.0 | -5.5 | -1.1 | 0.01 (62) / 0.20 (54) / 0.03 (56) / 0.00 (62) |
| lightonocr3-4b | 93.5 (80/80) | 62.8 (74/80) | 79.0 (79/80) | 93.5 (80/80) | -30.7 | -14.5 | +0.1 | 0.02 (62) / 0.23 (55) / 0.03 (55) / 0.01 (61) |
| qwen3.6-27b | 96.0 (80/80) | 72.5 (73/80) | 88.6 (79/80) | 94.8 (80/80) | -23.6 | -7.5 | -1.2 | 0.01 (63) / 0.21 (55) / 0.03 (56) / 0.02 (63) |

### L1

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 78.6 (79/80) | 3.8 (13/80) | 73.6 (75/80) | 76.1 (80/80) | -74.8 | -5.0 | -2.5 | 0.00 (62) / 0.02 (5) / 0.02 (62) / 0.00 (63) |
| paddleocr-vl1.5 | 69.5 (73/80) | 3.5 (13/80) | 68.3 (75/80) | 66.9 (78/80) | -66.1 | -1.2 | -2.7 | 0.02 (53) / 0.02 (5) / 0.03 (58) / 0.04 (58) |
| lightonocr3-4b | 87.8 (78/80) | 4.2 (13/80) | 78.1 (75/80) | 84.7 (79/80) | -83.6 | -9.7 | -3.1 | 0.00 (70) / 0.09 (5) / 0.01 (63) / 0.00 (69) |
| qwen3.6-27b | 88.4 (80/80) | 4.0 (13/80) | 77.1 (75/80) | 81.1 (80/80) | -84.4 | -11.2 | -7.3 | 0.00 (71) / 0.02 (5) / 0.01 (63) / 0.00 (69) |

### the 96

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 90.9 (95/96) | 70.9 (88/96) | 84.9 (95/96) | 87.8 (96/96) | -20.0 | -6.0 | -3.1 | – / – / – / – |
| paddleocr-vl1.5 | 83.8 (86/96) | 70.2 (88/96) | 83.0 (95/96) | 84.2 (96/96) | -13.5 | -0.7 | +0.4 | – / – / – / – |
| lightonocr3-4b | 89.4 (96/96) | 67.5 (88/96) | 80.5 (95/96) | 84.0 (96/96) | -21.8 | -8.9 | -5.4 | – / – / – / – |
| qwen3.6-27b | 95.0 (96/96) | 71.7 (88/96) | 85.7 (95/96) | 89.8 (96/96) | -23.3 | -9.3 | -5.2 | – / – / – / – |

### clippings

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 86.9 (13/13) | 86.6 (13/13) | 81.8 (13/13) | 71.8 (13/13) | -0.3 | -5.1 | -15.1 | – / – / – / – |
| paddleocr-vl1.5 | 79.8 (11/13) | 82.7 (13/13) | 81.1 (13/13) | 69.6 (13/13) | +2.8 | +1.3 | -10.2 | – / – / – / – |
| lightonocr3-4b | 90.3 (13/13) | 85.2 (13/13) | 78.6 (13/13) | 74.0 (13/13) | -5.1 | -11.7 | -16.4 | – / – / – / – |
| qwen3.6-27b | 93.6 (13/13) | 88.1 (13/13) | 82.0 (13/13) | 76.4 (13/13) | -5.5 | -11.6 | -17.2 | – / – / – / – |

### tables

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 91.9 (12/12) | 76.3 (12/12) | 82.8 (12/12) | 88.9 (12/12) | -15.6 | -9.1 | -3.0 | – / – / – / – |
| paddleocr-vl1.5 | 82.1 (11/12) | 75.4 (12/12) | 81.7 (12/12) | 84.0 (12/12) | -6.7 | -0.4 | +1.9 | – / – / – / – |
| lightonocr3-4b | 68.2 (12/12) | 62.3 (12/12) | 73.3 (12/12) | 65.2 (12/12) | -5.9 | +5.1 | -2.9 | – / – / – / – |
| qwen3.6-27b | 94.8 (12/12) | 78.4 (12/12) | 85.3 (12/12) | 91.0 (12/12) | -16.4 | -9.5 | -3.8 | – / – / – / – |

### handwritten

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 85.6 (16/16) | 11.0 (11/16) | 70.2 (15/16) | 86.9 (16/16) | -74.6 | -15.5 | +1.3 | – / – / – / – |
| paddleocr-vl1.5 | 70.8 (13/16) | 11.1 (11/16) | 66.4 (15/16) | 73.1 (16/16) | -59.7 | -4.4 | +2.3 | – / – / – / – |
| lightonocr3-4b | 88.8 (16/16) | 11.2 (11/16) | 67.7 (15/16) | 87.5 (16/16) | -77.6 | -21.1 | -1.4 | – / – / – / – |
| qwen3.6-27b | 90.9 (16/16) | 11.2 (11/16) | 72.0 (15/16) | 87.6 (16/16) | -79.7 | -18.9 | -3.3 | – / – / – / – |

### typed, no table or clipping

| reader | whole | doclayout_yolo | pp-doclayoutv3 | tiles | Δ doclayout_yolo | Δ pp-doclayoutv3 | Δ tiles | order: whole / doclayout_yolo / pp-doclayoutv3 / tiles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 94.0 (40/41) | 92.8 (41/41) | 94.7 (41/41) | 96.2 (41/41) | -1.2 | +0.6 | +2.1 | – / – / – / – |
| paddleocr-vl1.5 | 90.2 (38/41) | 92.5 (41/41) | 93.5 (41/41) | 96.1 (41/41) | +2.3 | +3.4 | +5.9 | – / – / – / – |
| lightonocr3-4b | 96.8 (41/41) | 88.8 (41/41) | 91.6 (41/41) | 96.3 (41/41) | -8.0 | -5.2 | -0.5 | – / – / – / – |
| qwen3.6-27b | 98.0 (41/41) | 93.7 (41/41) | 95.3 (41/41) | 97.9 (41/41) | -4.3 | -2.7 | -0.2 | – / – / – / – |

GPU-hours spent reading crops (all three arms, the 354 pages): glm-ocr 0.09, lightonocr3-4b 0.12, paddleocr-vl1.5 0.07, qwen3.6-27b 0.59
