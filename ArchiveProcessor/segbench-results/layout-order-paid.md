# W46.layout-order-paid — Gemini asked for its blocks in reading order

Gap audit §5 item 28, the gateway arm of W46.layout-order (route R4: "order from the model on whole pages"). Produced
by `scripts/segbench/layout_order_gemini.py` (`run`, `rerun`, `score`; figures in `layout-order-paid.json`).
Gemini 3.7 Flash through the Stanford AI API gateway, 2026-11-05. Real money: $1.68 for every call in the item, the
gateway's own figure equal to the token estimate (1.00 times). That covers 151 pages read twice, plus one pass the
gateway answered from its cache (below).

## What was run

- **The ask.** One call per page, temperature 0, low reasoning. Gemini was asked for its text blocks (paragraphs,
  headings, lists, tables, captions, handwriting, marginalia, headers, footers, page numbers) in the order a person
  would read them, each as a `box_2d`, with no transcription (the prompt is in the JSON). Every block it returns is
  kept.
- **Pages, and the lines each set orders.** Each set uses the same lines and rules as its free arms, so the rows
  compare directly.
  - **Benchmark.** The 40 scored pages of the historical reading-order benchmark. Each truth body line takes its
    Gemini block's place, top to bottom inside it, as in W46.layout-order's regions panel.
  - **L9.** The 15 NewsBench pages, with the Vision lines inside DocLayout-YOLO's body regions that every L9 arm
    orders. Lines Gemini's blocks miss go last, top to bottom, as for PP-DocLayoutV3's native arm.
  - **Owner.** The 96 owner truth pages, with Vision's lines at the app's settings. The arm keeps the lines inside
    Gemini's blocks (W46.layout-order-marks's rule).
- **Arms.** `gemini/native` is Gemini's own order. The geometric orderers of `layout_order` are also run on
  Gemini's blocks.
- **Scores.** Tau, word error from order, the L9 gap and the reading-order edit are unchanged from W46.layout-order
  and W46.layout-order-marks. Each Gemini arm is paired with the free arms' cached per-page figures, over the pages
  both score, with a page-bootstrap interval.
- **Rerun.** A second live read of all 151 pages gives the rerun floor.

## Results

Tau on the pages that pass each set's guard, shown as [valid/pages]. The free arms are from `layout-order.json` and
`layout-order-marks.json`.

**Benchmark pages.**

| Arm | multi-column tau | single tau | lines in a block, multi | word error from order, multi |
|---|---|---|---|---|
| Gemini, its own order | 0.961 [14/15] | 0.997 [20/25] | 94% | 5.2% |
| Gemini blocks · app region sort | 0.980 [14/15] | 0.974 [20/25] | 94% | 2.6% |
| PP-DocLayoutV3, its own order | 0.999 [15/15] | 0.998 [19/25] | 89% (all) | – |
| DocLayout-YOLO · app region sort | 0.991 [5/15] | 0.996 [14/25] | 50% (all) | – |

- **Gemini finds the manuscripts DocLayout-YOLO misses.** All 10 Swedish court-hand and Middle-French pages are
  valid, at tau 0.996-1.000 each.
- **One English page drags the mean.** eng_01 scores 0.495, about what top to bottom gives, and pulls the mean down.
  The other three valid English pages score 0.969-1.000.
- **Against PP-DocLayoutV3's own order** on the 14 pages both score, Gemini is −0.039 [−0.112, −0.000]. On the second
  read it is −0.041 [−0.123, −0.000] (n 12).
- **Against the app's sort on YOLO's regions** only 4 pages pair. The gap is −0.123 [−0.363, +0.014], a tie on too
  few pages.
- **Single-column pages** are a tie with every free arm.
- **frp_00** came back as an empty list on the first read (`{"blocks": []}`) and is scored as finding nothing.

**L9 newspapers** (15 pages, all valid).

| Arm | tau | word acc. | order gap | reading-order edit | lines in a block (own tau) |
|---|---|---|---|---|---|
| Gemini, its own order | 0.455 | 19.4% | 41.2 | 0.392 | 66% (0.663) |
| Gemini, second read | 0.552 | 23.9% | – | – | 71% (0.819) |
| Gemini blocks · app region sort | 0.591 | 24.1% | 36.5 | 0.300 | 66% (0.918) |
| DocLayout-YOLO · app region sort | 0.905 | 34.1% | 26.5 | **0.147** | – |
| PP-DocLayoutV3, its own order | 0.881 | **37.2%** | **23.4** | 0.318 | 94% (0.977) |

- **Gemini fails on newspapers, in both detection and order.** Its blocks hold two thirds of the lines. On three
  pages it returned 2-4 blocks for the whole page.
- **Its own order on the lines it does place** is tau 0.66. The app's region sort on the same blocks does better
  (0.92).
- **Against every free region arm** it is −0.43 to −0.47 tau, with intervals well clear of zero. The second read is
  −0.33 to −0.41.

**The owner's 96.**

| Arm | tau | ≥ 0.95 | lines kept | word acc. |
|---|---|---:|---:|---:|
| Gemini, its own order | 0.982 [66/96] | 58 | 86% | 66.2% |
| Gemini, second read | 0.971 [67/96] | 59 | 85% | 63.9% |
| Gemini blocks · rows-first XY-cut | 0.968 [66/96] | 56 | 86% | 65.8% |
| Gemini blocks · app region sort | 0.961 [66/96] | 50 | 86% | 65.7% |
| PP-DocLayoutV3, its own order | 0.992 [66/96] | 63 | 82% | 69.0% |
| No detector · Vision's line order | 0.972 [72/96] | 64 | 100% | 75.1% |
| No detector · app line column sort | 0.971 [72/96] | 64 | 100% | **75.6%** |
| DocLayout-YOLO · app region sort | 0.945 [68/96] | 50 | 92% | 71.4% |

Gemini's own order, paired, on each read:

| Against | first read | second read |
|---|---|---|
| DocLayout-YOLO · app region sort | +0.032 [+0.009, +0.064] (62) | +0.021 [−0.012, +0.056] (63) |
| PP-DocLayoutV3, its own order | −0.013 [−0.025, −0.004] (61) | −0.019 [−0.042, −0.004] (61) |
| Vision's line order | +0.001 [−0.015, +0.021] (66) | −0.010 [−0.034, +0.011] (67) |
| App line column sort | +0.002 [−0.015, +0.023] (66) | −0.009 [−0.035, +0.016] (67) |

By page kind, Gemini's own order (first read) scores:

| Page kind | tau |
|---|---|
| typed | 0.993 [37/41] |
| clippings | 0.957 [10/13] |
| tables | 0.944 [6/12] |
| handwritten | 0.997 [3/16] |

## What it says

1. **Gemini's order changes no default.**
   - On the owner's pages it ties the free no-detector arms: Vision's line order and the app's line column sort,
     on both reads.
   - It is below PP-DocLayoutV3's own order on both reads, by 0.013-0.019.
   - It keeps 86% of the lines against their 100%, so its word accuracy is 9-12 points lower.
   - The app's region sort on DocLayout-YOLO is the one free arm it beats, and only on the first read.
   - On public print it is below PP-DocLayoutV3. On newspapers it is far below every free region arm.
   - Route R4's "order from the model on whole pages" is therefore not a reason to send a page to Gemini for
     layout. W46.layout-order-marks's conclusion stands: free arms already reach tau 0.95 on the owner's pages.
2. **Where it helps, PP-DocLayoutV3 already does.** Gemini finds the manuscript blocks DocLayout-YOLO misses and
   orders them at about 1.0. So does PP-DocLayoutV3, for free, at 0.999.
3. **Asking Gemini for boxes does not suit newspapers.** On 50-plus blocks a page, its blocks hold two thirds of
   the lines. A second read moves tau by 0.32 a page on average. For a dense page, a cloud route should keep the
   free detector and send regions, as R1/R2's detector-first design already says.
4. **The replies need a forgiving reader.** 63 of the 151 first-read replies were not valid JSON: a stray key, a
   brace in place of a bracket, the key written `box_2` or `box`. Every block in them was still whole and is read
   object by object here. Any app path that asks 3.7 for boxes must parse the same way, or it loses about 40% of
   its pages.

## Measurement card

- **Truth.** It is the same as the free arms' truth.
  - The benchmark's PAGE/ALTO lines (Jha, MIT).
  - L9's volunteer transcriptions, partial on some pages.
  - The owner's adjudicated text on the 96 (`ocr-truth.md`). Claude Opus 5.5 and Gemini 3.8 Flash drafted it, and
    the owner checked it.
  - Gemini 3.8 drafted the 96's truth text, but not its order or boxes. The arm here is 3.7, asked only for
    blocks, and no text it wrote is scored.
- **Selection.**
  - The pages are the ones W46.layout-order and W46.layout-order-marks used, unchanged.
  - The 96 carry their Vision filter: every page Vision read as under 20 words was replaced at the draw
    (`ocr-truth.md`).
  - No page was chosen by Gemini or by ABBYY text.
- **Comparison.**
  - Each set orders the same lines as its free arms, with the same guard and scorer, so only the blocks and their
    order differ.
  - Gemini sees the whole page. The free arms see their detectors' output.
  - Both OCR sets are covered: the owner's 96, and the public benchmark and L9 pages.
- **Noise.**
  - The first rerun came back in 0.9 s a page, against 7.3 s live, with all 151 replies byte-identical. The gateway
    (LiteLLM) had answered from its response cache. That pass is kept aside (`replies-rerun-gateway-cached`) and is
    counted in the cost. The live second read sends `cache: {no-cache: true}`, which is `ocr_rerun_noise.py`'s fix.
  - On the 96, the two live reads differ by 0.027 tau a page on average (15 of 65 pages by more than 0.01). The
    paired first-minus-second is +0.011 [−0.009, +0.037].
  - On the benchmark the two reads differ by 0.004 on multi-column pages and are identical on single-column pages.
    On L9 they differ by 0.32.
  - Each verdict above holds on both reads, except the margin over DocLayout-YOLO, which holds on the first read
    only.
  - n is 61-67 paired owner pages, 14 multi-column benchmark pages and 15 L9 pages.
- **Scope.**
  - One model (3.7 Flash, as served by the gateway; 3.8 is not served there), one prompt, low reasoning. A stronger
    model or a prompt per page kind might order newspapers better. That is not measured here, and it would not
    change the owner-page verdict, where the free arms already reach 0.97-0.99.
  - Handwritten pages are 3 of 16 valid, as for the free arms.
  - This does not rank OCR routes, or say where a mark belongs in the stream.
