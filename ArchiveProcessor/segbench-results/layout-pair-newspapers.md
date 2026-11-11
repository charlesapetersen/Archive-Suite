# W46.layout-pair-newspapers — PP-DocLayoutV3 against DocLayout-YOLO, paired, on L9

Δ is PP-DocLayoutV3 minus DocLayout-YOLO (the newspaper-ocr route), the paired mean over the 15 L9
pages in points, with its 95% bootstrap interval and a two-sided paired permutation p. Wins count the
pages on which each detector scored higher. $0: no model, network or cluster; the readings are
W46.ocr-regions' (regions-20261021).

## What this says

- **On scanned newspapers DocLayout-YOLO leads PP-DocLayoutV3: a direction on 15 pages (at most 12 items, one collection), descriptive.** Over the four readers PP-DocLayoutV3
  is -4.6 [-8.0, -1.1] strict NES behind (85.6 against 90.2), beyond the interval for 3 of 4
  readers (GLM-OCR, LightOnOCR-3 4B, Qwen3.6-27B); PaddleOCR-VL 1.5 is a tie. The unpaired 86.2 against 91.1 of
  layout-photo-tables.md (GLM-OCR) holds once paired. Fourteen of the 15 pages carry the `mss34132` prefix and four
  share one item, so the page bootstrap is optimistic.
- **The gap is content, not only order.** Order-free it narrows to -2.0 [-2.9, -1.0] and stays below 0 for every
  reader: PP-DocLayoutV3 regions miss or garble words that DocLayout-YOLO's regions keep.
- **This does not by itself change the app's detector.** The stage rule (03-layout.md section 6) switches
  only if the other detector also clears PP-DocLayoutV3 on photographed newspapers after the quad; no
  photographed newspaper set with truth exists. On photographed modern print (Real5, quad first, GLM-OCR,
  unpaired, the same detector with the app sort) DocLayout-YOLO trails PP-DocLayoutV3 on Skew and Warping
  (78.2 against 89.1, 78.7 against 85.9), and on the owner's 96 photographs, none of them a newspaper, it is
  70.9 against 84.9 (layout-photo-tables.md). The owner's pages are photographs, so PP-DocLayoutV3 stays the newspaper
  detector; the scan-only loss of about 5 points is stated with it, and W46.layout-photo-newspapers
  (behind W46.nice-to-have) is what would test the photographed half.

## Results

### strict NES, in order

| reader | PP-DocLayoutV3 | DocLayout-YOLO | Δ PP − YOLO | p | wins PP / YOLO | verdict |
|---|---:|---:|---:|---:|---:|---|
| GLM-OCR | 86.2 | 91.1 | -4.9 [-8.4, -1.3] | 0.021 | 4 / 11 | DocLayout-YOLO |
| PaddleOCR-VL 1.5 | 89.7 | 92.3 | -2.6 [-5.8, +0.7] | 0.144 | 5 / 10 | tie |
| LightOnOCR-3 4B | 83.6 | 88.4 | -4.8 [-8.3, -1.2] | 0.025 | 4 / 11 | DocLayout-YOLO |
| Qwen3.6-27B | 82.9 | 88.9 | -6.0 [-9.7, -2.2] | 0.008 | 3 / 12 | DocLayout-YOLO |
| mean of the four readers | 85.6 | 90.2 | -4.6 [-8.0, -1.1] | 0.025 | 5 / 10 | DocLayout-YOLO |

### order-free bag-of-words F1

| reader | PP-DocLayoutV3 | DocLayout-YOLO | Δ PP − YOLO | p | wins PP / YOLO | verdict |
|---|---:|---:|---:|---:|---:|---|
| GLM-OCR | 94.9 | 97.1 | -2.2 [-3.4, -0.9] | 0.008 | 2 / 13 | DocLayout-YOLO |
| PaddleOCR-VL 1.5 | 96.4 | 97.5 | -1.1 [-2.2, -0.1] | 0.055 | 4 / 11 | DocLayout-YOLO |
| LightOnOCR-3 4B | 91.2 | 93.8 | -2.6 [-3.6, -1.4] | 0.001 | 3 / 12 | DocLayout-YOLO |
| Qwen3.6-27B | 91.7 | 93.9 | -2.2 [-3.0, -1.2] | 0.002 | 2 / 13 | DocLayout-YOLO |
| mean of the four readers | 93.6 | 95.6 | -2.0 [-2.9, -1.0] | 0.004 | 2 / 13 | DocLayout-YOLO |

## Measurement card

- **Truth.** L9's published transcriptions (the newspaper benchmark's own text), independent of every route here.
  The owner checked nothing specific to this item.
- **Selection.** The 15 frozen L9 pages of the 895 that W46.ocr-regions read; chosen by the bench's frozen draw,
  not by any detector's or reader's output. No ABBYY text was used.
- **Comparison.**
  - Same inputs: each reader read both detectors' crops of the same 2,400 px copies with the same prompt and
    settings in the one 2026-10-21 Sherlock pack; only the detector differs. Each arm is stitched in its own
    detector's order (DocLayout-YOLO through newspaper-ocr's column sort, PP-DocLayoutV3 in its own order).
  - Strict NES scores the stitched order; the order-free figure (bag-of-words F1, W46.ocr-rescore-offline)
    removes order, so a gap that survives it is content, not ordering.
  - Both OCR sets: the owner's 96 has no newspaper page, so this pair has nothing to say there. The detectors'
    figures on the 96 are in layout-photo-tables.md and regions-20261021.md (PP-DocLayoutV3 above DocLayout-YOLO).
- **Noise.**
  - n = 15 pages, paired; one reading at temperature 0 per arm. A paired interval that crosses 0 is a tie, as is a
    gap under the 0.49-point rerun floor (ocr-rerun-noise.md, taken by cluster routes as in ocr-pair-matrix.md).
  - 15 pages is under the 20-page line below which a group is descriptive in the parent reports, and they are not
    independent: 14 carry the `mss34132` prefix and four share one item, so they hold at most 12 items, almost all
    from one Library of Congress collection, and the page bootstrap is optimistic. The result is a direction, not a
    settled gap.
- **Scope.**
  - Scans only. No photographed newspaper set with truth exists (the owner corpus has none labelled), so the
    quad-then-detector route on photographed newspapers stays unmeasured; that is W46.layout-photo-newspapers.
  - Detector thresholds are the shipped or maker defaults, not tuned.
  - Four open readers on the cluster; the gateway arm (Gemini 3.7 Flash) read only PP-DocLayoutV3 on 3 L9 pages,
    so it cannot be paired.
