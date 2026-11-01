# W46.layout-photo — whether DocLayout-YOLO collapses on our photographs

Gap audit §5 (`execution-plans/processing-review/10-gap-audit.md`), R1, R2, R7 and R8. Produced by
`scripts/segbench/layout_photo.py score` over the Sherlock pack `layout-photo-20261030` (batch 20261031-131437).
The figures are in `layout-photo.json`, the tables in `layout-photo-tables.md` and the per-page rows in
`layout-photo-pages.csv`. The handwriting arm without a reader is `layout-photo-hands.md`. No money was spent;
reading took 0.9 GPU-hours on one L40S a shard.

## Answer

**Yes.** In the app's setup, DocLayout-YOLO collapses on skewed photographs, on handwriting and on registers.
PP-DocLayoutV3 holds up best on every photographed condition. A quad correction before the layout stage restores
most of what YOLO loses. GLM-OCR on the whole page beats every detector except on newspapers.

- **Skew.** On Real5's Skew folder, YOLO scores 41.1 NES, 40.1 points [33.1, 47.2] under its own Scanning score
  of 81.2. On 58 of 155 pages it keeps no region at all. PP-DocLayoutV3 loses 10.0 points (91.7 to 81.8), heron
  11.9 and Vision 16.1. RT-DocLayout's Table 2 puts YOLO at 48.74 on Skew against 91.66. Our drop is of the same
  size, but our pages are text-only and our scorer is not theirs, so the comparison is between drops, not levels.
- **Warping and illumination** cost YOLO less: 11.7 and 1.6 points. Warping still leaves 14 pages with nothing
  read.
- **Handwriting and registers.** On the 96's 16 handwritten pages YOLO scores 14.2 against 85.8 for the whole
  page, and it reads nothing on 10 of them. On L4's 80 registers it scores 1.6 against 59.7, with nothing read on
  49. YOLO through newspaper-ocr's own processing does no better (11.0 and 1.1). This confirms the Mac-only
  `layout-photo-hands.md` with a reader: YOLO must not run on hands or registers.
- **The whole page wins** on the 96 (90.9; the best detector is heron at 87.1, −3.9 [−7.7, −0.3]), on L4, and on
  every Real5 condition (92.1 on Scanning, and PP-DocLayoutV3 is the only detector inside the noise there, at
  −0.4 [−3.4, +2.5]). On the 96's typed pages with no table or clipping, every detector except Vision ties the
  whole page.
- **Newspapers (L9) are the exception.** Every detector except Vision gains on the whole page's 29.2 (GLM-OCR
  hits its token cap or returns nothing on 9 of 15 whole pages). Newspaper-ocr's YOLO scores 91.1, PP-DocLayoutV3
  86.2, YOLO in the app's sort 73.5 and heron 65.0.
- **Apple Vision's document regions are not a substitute.** On L9 they score 16.8 and leave about 41,000 of
  the truth's words unread. They also score worst on every photographed Real5 condition (61.3 on Warping).
- **The staged pre-step.** Apple's quad with a perspective correction lifts YOLO by 37.1 points on Skew (to 78.2)
  and 9.1 on Warping. It lifts PP-DocLayoutV3 by 7.4 on Skew. UVDoc after the quad adds more on Warping (YOLO
  +13.3, PP +3.2 [+0.2, +6.3]), and nothing on Skew beyond the quad alone. On the whole page the pre-step is
  inside the noise everywhere (+1.7 [−0.3, +4.2] on Skew with the quad; +3.2 [−0.4, +7.0] on Warping with
  UVDoc), which is W46.enh-dewarp's finding again. The quad was found on all 310 Warping and Skew photographs.

What this means for the open decisions, left to the processing review's Phase 4 (W46.review-phase4):

1. The evidence is against shipping DocLayout-YOLO as the layout detector. PP-DocLayoutV3 is the robust choice
   on photographs. Heron scores a little higher on the 96 (87.1 against 84.9; the pair was not tested), but it
   is 9.8 points under the whole page on Real5 Scanning, where PP-DocLayoutV3 ties the whole page.
2. The kind-gated rule holds: run a layout stage on newspapers and other dense multi-column print, never on
   handwriting or registers. Elsewhere GLM-OCR reads the whole page better.
3. If a layout stage runs on a photograph, a quad correction should come before it. Dewarping the whole page
   for OCR still does not pay.

## What was run

- **Reader.** GLM-OCR (`zai-org/GLM-OCR`), with W46.ocr-regions' request unchanged: the same crop padding,
  JPEG 95, 4,096 tokens a crop and temperature 0. A page's regions are joined as paragraphs in the arm's order. A
  page with no region read scores 0.
- **Detectors**, each run as the app or its maker would run it, on the Mac (`layout_photo.py detect`):
  DocLayout-YOLO DocStructBench (the ONNX export of the weights the app ships, 1,024 px, conf 0.25, the app's
  region sort); PP-DocLayoutV3 (the mlx-vlm port, 1,024 px, conf 0.5, its own order); docling-layout-heron
  (RT-DETRv2, 640 px, conf 0.3, the app's sort); Apple Vision's RecognizeDocumentsRequest (macOS 26, its own
  order). The bench arms also include W46.ocr-regions' readings of YOLO through newspaper-ocr's own layout
  processing (`yolo_newsocr`) and of PP-DocLayoutV3, rescored here. They reproduce `regions-20261021` exactly.
- **Pages.**
  - The 96 (the three agreement-only letters excluded), and L9 (15 NewsBench pages) and L4 (80 registers) of
    the 895.
  - Real5-OmniDocBench: every English OmniDocBench v1.5 page whose truth is plain text (155 pages, with no
    table, equation, mask or inline LaTeX). Each is read in four of Real5's folders: Scanning, Illumination,
    Warping and Skew. Screen-Photography is left out because a box photograph does not have that condition.
  - The Warping and Skew copies are also read after the quad and after UVDoc-after-quad, using W46.enh-dewarp's
    code. Heron and Vision were not run on those copies.
- **Scoring.** `ocr_panel_score.score` strict NES; a markup-stripped NES is given beside it in the tables, and is
  within 0.1 points of strict on every row except tables (+0.9 at most). Paired differences use
  `ocr_panel_score.paired`: a 95% bootstrap interval over the same pages or the same Real5 page.

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
