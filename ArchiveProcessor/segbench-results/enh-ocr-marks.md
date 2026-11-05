# Enhancement on the marks set: does the hand survive?

W46.enh-ocr-input-marks. The marks arm of W46.enh-ocr-input (`execution-plans/processing-review/10-gap-audit.md` §5 item 11): the enhancement methods run on the marks set's 40-page owner core, and the ink inside every mark box the owner kept checked against the raw image. It decides whether any method may touch the reading copy. Script `scripts/segbench/enh_ocr_marks.py`; per-box figures `enh-ocr-marks.json`.

40 pages (32 of them detector truth), 85 kept mark boxes. Each figure is a mean over pages with a 95% bootstrap interval over pages. *Kept*: the share of the raw image's ink pixels in a box that are still ink. *Kept − print*: the same page's box figure less its figure outside every box (mostly print), paired by page: below zero means the method takes marks more than print. *Lost*: boxes with under half their ink left. *Contrast*: mean darkness kept on raw's ink. *Colour*: coloured ink still coloured. *Added*: new ink in the box, as a share of raw's ink. `jpeg` is the raw image saved again as every arm is: the floor.

## Ink darker than its background by 0.30 (clear ink)

| Arm | Kept % | Kept − print | Lost boxes | Contrast % | Colour % | Added % | Print kept % |
|---|---|---|---:|---|---|---|---|
| jpeg | 97.1 (96.3 to 97.9) | -0.004 (-0.012 to +0.004) | 0 of 82 (0 pages) | 100.6 (100.5 to 100.8) | 86.1 (79.1 to 92.3) | 5.5 (3.7 to 7.4) | 97.5 (97.0 to 97.9) |
| shading | 96.3 (94.9 to 97.5) | +0.017 (-0.003 to +0.038) | 0 of 82 (0 pages) | 98.7 (98.3 to 99.1) | 65.4 (46.9 to 82.6) | 1.5 (1.1 to 2.1) | 94.6 (93.0 to 96.0) |
| gcdrnet | 97.8 (95.6 to 99.4) | +0.011 (-0.012 to +0.031) | 1 of 82 (1 page) | 131.3 (125.5 to 137.2) | 68.0 (48.4 to 85.7) | 49.9 (27.6 to 77.5) | 96.7 (95.8 to 97.5) |
| sbb | 89.0 (81.0 to 95.2) | +0.184 (+0.079 to +0.305) | 6 of 82 (4 pages) | 181.7 (162.0 to 198.5) | 0.0 (0.0 to 0.0) | 113.5 (38.0 to 218.1) | 73.7 (64.8 to 81.8) |

Kept % by subset:

| Arm | detector pages (32) | handwriting classes | stamps | boxes clear of print |
|---|---|---|---|---|
| jpeg | 97.4 (96.3 to 98.2), lost 0/43 | 97.1 (96.1 to 98.0), lost 0/64 | 96.5 (93.7 to 98.1), lost 0/13 | 96.4 (95.4 to 97.4), lost 0/37 |
| shading | 96.4 (94.7 to 97.9), lost 0/43 | 96.0 (94.3 to 97.5), lost 0/64 | 95.6 (91.8 to 98.1), lost 0/13 | 95.6 (94.0 to 97.2), lost 0/37 |
| gcdrnet | 98.1 (95.9 to 99.4), lost 0/43 | 98.2 (96.2 to 99.4), lost 0/64 | 92.9 (79.5 to 99.9), lost 1/13 | 96.1 (91.0 to 99.3), lost 1/37 |
| sbb | 88.9 (78.0 to 96.4), lost 3/43 | 90.2 (80.9 to 96.7), lost 4/64 | 88.2 (79.2 to 95.7), lost 0/13 | 79.9 (65.1 to 92.2), lost 5/37 |

## Ink darker than its background by 0.15 (faint ink included)

| Arm | Kept % | Kept − print | Lost boxes | Contrast % | Colour % | Added % | Print kept % |
|---|---|---|---:|---|---|---|---|
| jpeg | 97.9 (97.5 to 98.3) | +0.006 (+0.001 to +0.012) | 0 of 85 (0 pages) | 100.9 (100.8 to 101.1) | 82.3 (74.4 to 89.3) | 4.8 (3.9 to 5.9) | 97.4 (97.0 to 97.7) |
| shading | 97.3 (96.4 to 97.9) | +0.037 (+0.021 to +0.058) | 0 of 85 (0 pages) | 98.6 (98.2 to 99.1) | 64.1 (46.8 to 80.4) | 1.4 (1.2 to 1.6) | 93.9 (92.1 to 95.3) |
| gcdrnet | 84.9 (79.5 to 89.8) | +0.021 (-0.040 to +0.082) | 6 of 85 (3 pages) | 124.2 (116.9 to 131.4) | 61.1 (42.7 to 79.0) | 8.7 (2.2 to 16.7) | 82.6 (78.7 to 85.9) |
| sbb | 75.9 (67.8 to 82.7) | +0.202 (+0.105 to +0.311) | 13 of 85 (5 pages) | 199.3 (173.6 to 224.4) | 0.0 (0.0 to 0.0) | 4.7 (2.7 to 6.8) | 56.8 (49.4 to 63.5) |

Kept % by subset:

| Arm | detector pages (32) | handwriting classes | stamps | boxes clear of print |
|---|---|---|---|---|
| jpeg | 97.9 (97.4 to 98.4), lost 0/45 | 97.9 (97.4 to 98.4), lost 0/66 | 97.9 (97.4 to 98.4), lost 0/14 | 97.8 (97.3 to 98.2), lost 0/40 |
| shading | 97.3 (96.5 to 98.0), lost 0/45 | 97.1 (96.1 to 98.0), lost 0/66 | 97.2 (95.8 to 98.3), lost 0/14 | 97.0 (95.8 to 97.9), lost 0/40 |
| gcdrnet | 85.4 (79.3 to 90.9), lost 2/45 | 85.5 (79.4 to 90.7), lost 3/66 | 80.2 (61.4 to 92.3), lost 3/14 | 79.3 (70.9 to 86.3), lost 4/40 |
| sbb | 75.9 (65.2 to 84.3), lost 6/45 | 78.4 (69.8 to 85.4), lost 8/66 | 70.2 (58.7 to 82.1), lost 3/14 | 67.1 (53.5 to 79.7), lost 11/40 |

## Verdict

**Only the contrast-only control may touch the reading copy; the content-removing methods may not.** Shading division keeps 97.3% of the faint-inclusive ink in the mark boxes against the re-encoding floor's 97.9%, loses no box at either threshold, and takes marks no more than print, but it greys the marks' colour: paired by page against the floor, -18.2 colour points (-33.0 to -4.7) with faint ink and -20.7 colour points (-37.4 to -5.4) clear, on the 14 pages and 31 boxes with coloured ink (10 of the 14 pages below the floor). GCDRNet keeps clear ink (97.8%) but erases faint ink: 84.9% kept, 6 of 85 boxes lost on 3 pages (three stamps, a signature and two marginal notes), and greys colour like shading (-21.1 colour points (-37.9 to -5.0) with faint ink). Its loss is no worse on marks than on the page's faint print: it erases faint ink wherever it is. SBB keeps 75.9% of faint ink, loses 13 boxes on 5 pages and every mark's colour by construction (coloured ink and typed print become the same black), and on 4 pages (Dean-334e2d7a9b3ec242, Herrnstein-ffa375644a778474, RG165-396a60e40b8cda58, Stanton-00948e05eccffc0d) it kept under a fifth of the print's ink as well. Its positive kept-minus-print is that print loss, not a gain for the marks. With W46.enh-ocr-input (no method helps any reader as OCR input), the rule for the app: the reading copy and the OCR input both stay the raw image; a gain-only shading division is the one method that may be offered for viewing, and it greys about a fifth of a mark's colour there; a content-removing method never replaces the stored page.

## Measurement card

- **Truth.** The marks set's owner core after the 2026-11-04 recheck (`marks-set-reconciled.md`): the owner kept or rejected every candidate mark, its class and whether it touches print; the boxes are rough draft boxes from Gemini 3.7 Flash and Qwen3-VL 8B plus one owner box, not tight geometry. The ink itself is measured, not judged: no person or model read a page for this item.
- **Selection.** The frozen two-phase draw's 40-page core (16 A-core, 24 B-core), drawn before any enhancement method existed for these pages; no method or ABBYY text chose a page. Descriptive, no population weights (W46.marks-sampling-support). The 8 pages excluded from detector truth are in the measure (their boxes are regions, whatever their completeness) and the 32 detector pages are shown alone.
- **Comparison.** Every arm from the same 2400 px JPEG the models read, at its size, saved at JPEG 90 like the `jpeg` floor; the same ink function, thresholds and boxes for every arm; the code and weights of W46.enh-ocr-input.
- **Noise.** n = 28 pages: the 85 boxes lie on 28 of the 40 pages (the rest have no kept mark), and 14 of those have coloured ink (31 boxes); boxes are nested in pages and the bootstrap resamples pages. The `jpeg` arm is the floor: re-encoding alone moves 2-3% of ink pixels across a threshold and no box. A box figure within the floor is no change. The floor keeps only about 80% of the coloured ink (JPEG chroma subsampling), but every arm went through the same JPEG 90 save, so the colour loss is read paired by page against the floor: shading's and GCDRNet's intervals stay below zero, a resolved loss, not noise. Whether the colour measure itself reads divided images differently was not tested.
- **Scope.** Ink survival, not legibility: a mark can keep its pixels and still read worse, and no reader transcribed the marks here. Rough boxes include print where a mark touches it (the clear-of-print subset is the purer figure). DocRes appearance and deshadow were not run: they need a cluster GPU, neither helped any reader in W46.enh-ocr-input and the app ships no enhancement, so their marks arm decides nothing now and is filed behind W46.nice-to-have (W46.enh-ocr-input-marks-docres). Gemini on the enhanced images (W46.enh-ocr-input-paid) is untouched.

