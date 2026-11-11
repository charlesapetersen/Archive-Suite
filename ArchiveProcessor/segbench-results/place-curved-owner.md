# Selection on the owner's pages whose lines fan most (W46.place-curved-owner)

Owner, 2026-11-10 (point 9): UIUC 00233 and 00149 "test warping with selection; perhaps we've already fully tested
that". We had not: stage 01 calls strongly curled or bound pages untested (`01-reading-copy.md`), and the placement
results (`place-print.md`, `place-geom.md`) score the 96 benchmark pages, of which 10 are curl-tagged. This scores the
print placement route of `05-placement.md` on 32 curved pages against 32 flat pages from the same collections. No
model was called and nothing was spent. Script: `scripts/segbench/place_curved.py`; figures:
`place-curved-owner.json`.

## Verdict

**Curved pages select markedly worse.** The route passes 74.3% of the lines on the curved pages (978 of 1,316) and
94.1% on the flat ones (1,065 of 1,132). The difference is **−19.8 points (−26.2 to −12.8)**, and **−16.8
(−21.7 to −12.1)** as the mean over the 32 same-collection pairs. Both intervals are far from 0. The more curved the
page, the worse it selects: across all 62 pages with 5 or more scored lines, Spearman's ρ between the cue and the
page's pass rate is −0.64.

**What the curved set is** (measurement review pass 12, P12-5). It is the cue's top 1% of the sample: the pages whose
lines fan most, with covers, angled display type and some handwriting among them as well as bound volumes. Nobody
classed the 64 pages, so this is not a measured gap on bound or curled pages. The owner's own Finder tags on the 64
source PDFs (`corpus_survey.read_tags`, read only) tag 1 curved page Handwritten and 4 Clippings, against 0 and 1 in the
flat set. The gap survives taking those out: −19.8 (−26.3 to −12.4) without the handwritten pair, −17.1 (−23.5 to
−9.4) without the handwritten and clipping pairs, and −20.8 (−27.0 to −12.8) without the pages whose spread is over
15°; 25 of the 32 pairs are worse. The tags are far from complete (several pages are handwritten and only one is
tagged), so the effect is real on these pages, but how much of it is bending is not shown.

- **The owner's two pages.** UIUC 00233 (bound, curved, back showing through) passes 21 of 27 lines (78%); its UIUC
  pair 00254 passes 17 of 17. UIUC 00149 passes 33 of 33. Its curve is mild (cue 3.0°, against 9.2° for 00233), and
  deskewing it by its 3.5° median angle carries it.
- **How the failures happen.** Of the curved pages' 338 failing drags, 130 break across a line: Vision draws a bent
  or fanned line as one straight quad, the lab writer lays its words as one level run over that quad's box, and on a
  bent page the box reaches into the next line. A drag along the ink then starts or ends inside the neighbour's run.
  Another 91 return only part of the line, and the rest return the wrong words. On UIUC 00233 the drags along lines
  3 to 5 each pick up the end of the line above.
- **The control says it is the level run, not Vision's grouping.** The same drags over blla's own lines, each written
  as one level run over the band blla gives it, lose about as much on curved pages: 62.5% against 82.4%, −19.9
  (−28.3 to −10.5). The control is weaker than the route on flat pages too, because blla's bands include ascenders and
  descenders and overlap. So it is not a better layer. But the curved pages' loss survives a perfect grouping: one
  level run per line cannot follow a bent line.
- **Vision's own lines show it too.** Dragging each Vision line along its own words (no blla) passes 81.9% on curved
  pages and 97.6% on flat ones, −15.7 (−23.4 to −8.9).
- **Deskew helps a little but does not close it.** The raw photograph passes 69.3% on curved pages and 89.8% on flat
  ones. The route deskews 11 curved and 8 flat pages. On the curved ones deskewing lifts the pass from 304 to 370 of 535
  lines (57% to 69%), and on the flat ones from 149 to 197 of 209 (71% to 94%).

**For W46.dewarp-guard (no reopening of the 2026-11-06 call).** This is evidence for the case its revisit condition
names, not yet the case itself: the layer fails markedly on the owner's pages whose lines fan most, more than the 10
curl-tagged pages, but those pages are not classed as bound or curled. Before this figure reopens the call, the 64
pages are classed (bound or curled, perspective, display type, handwritten) by the owner or a gateway model, and the
gap is restated on the bound or curled pairs. One level run per line cannot carry a bent line, and a dewarped reading copy is the stage 01 remedy the owner
declined for now. `place-geom.md`'s −8.6 for UVDoc was measured on the 58 benchmark pages, which are mostly flat. A
sloped or curved run per line (the writer, not the image) is the other way to follow the bend. `place-geom.md`
measured a sloped run only on those mostly flat pages, where it lost (−7.4).

## How many of the owner's pages are curved

The survey read every image in the 5,000-file Reader sample (`reader-sample/`, made 2026-11-04): 3,747 JPEG
originals, plus the HEIC originals of the 24 UIUC PDFs the sample drew. The sample's partner rule does not pair
HEIC files, so those were converted from the corpus, read only. Apple Vision read the lines (`dewarp.swift lines`,
accurate, the stored pixels). Each page was turned upright by the quarter turn that makes its lines run left to right:
876 of the 3,773 images are stored turned, UIUC 00233 included. 3,043 distinct pages have 8 or more lines a quarter of
the page wide or wider (43 duplicate images left out: the sample holds some files under two folders).

**The cue** is `angle_spread` from `place_geom.py`: fit each wide line's angle as linear in the line's centre and take
how far the fit moves across the page, in degrees. On a bound or curled page, the lines fan as the paper bends.
`angle_residual` (W46.enh-dewarp's bend signal) and a line-height-over-pitch measure were tried as well. They do not
separate 00233 from ordinary pages: 00233's residual 0.26 is below the median, 0.31. The spread puts 00233 11th of the
3,043.

| spread at least | pages | share |
|---|---:|---:|
| 2.96° (UIUC 00149) | 421 | 13.8% |
| 5° | 107 | 3.5% |
| 7.23° (the curved set's 30th page) | 30 | 1.0% |
| 9.22° (UIUC 00233) | 11 | 0.4% |

The median page's spread is 1.25°, the 90th percentile 3.45°. The spread is a geometry cue, so a strong camera
perspective raises it as well as a bend. The curved set below is the cue's top 30, not a judgement of each page.
Read it as "pages whose lines fan most"; how many of them are bound volumes or curled sheets was not counted.

## The pages

Curved: the two owner pages and the 30 distinct sample pages with the largest spread (7.2° to 41.1°). Flat: for each
curved page, one page at random (seed 4611) from the same collection (27 pages) or, where it has none, the same archive
(5), with a spread at or under the pool's median. Strict line pass on blla's lines, the route's reading copy:

| curved page | collection | spread | reading copy | pass | Vision lines | flat pair | pass |
|---|---|---:|---|---:|---:|---|---:|
| uiuc-00233 | UIUC | 9.2 | +1.3 deskew | 21/27 (78%) | 24/26 (92%) | uiuc-00254 | 17/17 (100%) |
| uiuc-00149 | UIUC | 3.0 | -3.5 deskew | 33/33 (100%) | 34/34 (100%) | uiuc-00032 | 38/38 (100%) |
| s03370 | Chicago, University of, Archives/Coleman papers | 41.1 | -0.2 raw | 3/4 (75%) | 8/11 (73%) | s03372 | 25/26 (96%) |
| s02046 | Stanford University Archives — Tech/Moore | 21.6 | +0.5 raw | 1/1 (100%) | 7/11 (64%) | s02115 | 23/23 (100%) |
| s01262 | Hoover Institute/Zschau | 15.8 | -0.1 raw | 133/159 (84%) | 241/259 (93%) | s01245 | 10/10 (100%) |
| s01776 | Stanford University Archives — Tech/Intel Publications | 12.4 | +5.6 deskew | 90/143 (63%) | 103/136 (76%) | s02009 | 48/52 (92%) |
| s01403 | Hoover Institute/Roger Freeman papers | 11.9 | +0.9 raw | 20/26 (77%) | 30/43 (70%) | s01401 | 23/24 (96%) |
| s03050 | Stanford University Archives/Stanford Alumni Review | 11.1 | -0.6 raw | 82/148 (55%) | 99/180 (55%) | s03044 | 38/40 (95%) |
| s01517 | NYPL/New Yorker papers | 10.7 | +0.9 raw | 17/21 (81%) | 27/27 (100%) | s01520 | 17/17 (100%) |
| s03048 | Stanford University Archives/Stanford Alumni Review | 10.6 | +1.3 deskew | 73/105 (70%) | 103/131 (79%) | s02488 | 25/25 (100%) |
| s01665 | Stanford University Archives — Tech/Anderson | 10.2 | +1.0 raw | 18/33 (55%) | 19/34 (56%) | s01629 | 20/27 (74%) |
| s03335 | USC/Brown | 10.1 | +1.3 deskew | 22/24 (92%) | 26/26 (100%) | s03297 | 32/32 (100%) |
| s01668 | Stanford University Archives — Tech/Anderson | 10.0 | +1.8 deskew | 22/34 (65%) | 27/33 (82%) | s01650 | 29/29 (100%) |
| s00676 | Harvard University Archives/Glazer papers | 9.1 | -1.8 deskew | 16/25 (64%) | 18/25 (72%) | s00747 | 26/33 (79%) |
| uiuc-00395 | UIUC | 8.9 | -0.4 raw | 6/10 (60%) | 13/13 (100%) | uiuc-00002 | 22/22 (100%) |
| s01319 | Hoover Institute/McCloskey | 8.9 | +3.1 deskew | 20/31 (65%) | 22/31 (71%) | s01323 | 25/29 (86%) |
| s00185 | Cambridge/Wilmott Peter | 8.8 | -0.6 raw | 14/18 (78%) | 21/22 (95%) | s00214 | 19/26 (73%) |
| s01667 | Stanford University Archives — Tech/Anderson | 8.8 | +2.2 deskew | 21/35 (60%) | 40/53 (75%) | s01646 | 24/24 (100%) |
| s01717 | Stanford University Archives — Tech/Cusick | 8.7 | -1.2 deskew | 23/36 (64%) | 25/40 (62%) | s01721 | 41/42 (98%) |
| s00573 | Harvard University Archives/Bell papers | 8.6 | +0.0 raw | 15/18 (83%) | 17/19 (89%) | s00591 | 29/30 (97%) |
| s00571 | Harvard University Archives/Bell papers | 8.4 | +0.0 raw | 38/38 (100%) | 40/40 (100%) | s00515 | 27/28 (96%) |
| s02141 | Stanford University Archives — Tech/Norman | 8.1 | +0.1 raw | 26/36 (72%) | 51/66 (77%) | s02113 | 17/17 (100%) |
| s00806 | Harvard University Archives/Riesman papers | 7.9 | +0.0 raw | 34/37 (92%) | 42/42 (100%) | s00862 | 14/14 (100%) |
| s01421 | Hoover Institute/Roger Freeman papers | 7.8 | +0.0 raw | 43/52 (83%) | 50/54 (93%) | s01418 | 101/108 (94%) |
| s00053 | Center for Jewish History/American Jewish Congress Records | 7.8 | +0.0 raw | 19/23 (83%) | 22/23 (96%) | s00052 | 35/45 (78%) |
| s03051 | Stanford University Archives/Stanford Alumnus | 7.7 | +1.9 deskew | 29/42 (69%) | 49/63 (78%) | s02736 | 27/27 (100%) |
| s01511 | NYPL/NYRB.pdf | 7.7 | +0.4 raw | 40/45 (89%) | 47/50 (94%) | s01515 | 27/28 (96%) |
| s03303 | USC/Brown | 7.6 | +1.0 raw | 19/24 (79%) | 22/24 (92%) | s03281 | 38/41 (93%) |
| s00122 | Babbage/CDC | 7.4 | +0.8 raw | 11/11 (100%) | 12/13 (92%) | s00126 | 35/36 (97%) |
| s01716 | Stanford University Archives — Tech/Cusick | 7.3 | +0.6 raw | 10/15 (67%) | 17/19 (89%) | s02026 | 150/156 (96%) |
| s01335 | Hoover Institute/McCloskey | 7.3 | -0.4 raw | 25/28 (89%) | 28/28 (100%) | s01327 | 41/42 (98%) |
| s02883 | Stanford University Archives/Richard W. Lyman, President of Stanford University Papers, SC0215 | 7.2 | -0.9 raw | 34/34 (100%) | 35/35 (100%) | s02881 | 22/24 (92%) |

The `s` keys are rows of `reader-sample/selection.tsv` (s plus the row number from 0, header excluded); the JSON
carries each page's sample-relative path.

## What was scored

- **The route** (`05-placement.md`, print): Vision's lines, one level run per line, through the Vision OCR lab's
  `SearchableWriter.compose` (`place_geom_writer.swift`, the lab at 7e7a52f). The reading copy is deskewed by the
  median line angle when that is 1° or more, as stage 01 rules. The reader is Vision itself, so "the reader's words
  aligned" is Vision's own layer here. `place-print.md` measured the two as a tie (+0.1, −0.4 to +0.7).
- **The drag** (`place_functional.swift drag`): from the first word's left edge to the last word's right edge, each at
  the middle of blla's band at that x, so along the ink and not along Vision's straight quad. A line passes when
  PDFKit's selection holds no line break and is exactly its words, in order.
- **The lines** are kraken 7.1.1 blla's (the Vision OCR lab's venv-kraken), read on upright copies with the EXIF
  orientation removed. A blla line's words are the Vision words whose box centre lies in its boundary, ordered along
  its baseline. It is scored when it holds two or more and none of them lies in another blla line.

## Measurement card

- **Truth.** No one drew truth for these pages. The lines are kraken blla's, a baseline segmenter that reads no text
  and does not see Vision's output. The words are Vision's: a line holds the words Vision read on it, so an OCR miss
  is not a selection failure. Neither blla nor Vision is checked against a human on these pages. Where blla groups
  wrongly, a line is left out (a word in two bands) or scored against blla's grouping. The levels are therefore not
  comparable with `place-print.md`'s 54.4%, which uses folded hand-checked truth and every truth word. Only the
  curved-against-flat difference is the result. The owner checked nothing here.
- **Selection.** By the geometry cue alone: the line-angle spread of Vision's lines. No reader, no ABBYY text, no tested
  route chose a page. The flat pages were drawn at random within the curved page's collection under the pool's
  median spread. I looked at the curved set's contact sheet as a sanity check, and nothing was chosen or left out by
  eye. It holds covers with angled display type and handwritten pages as well as bound volumes. Those pages stay in,
  so the curved set is "pages whose lines fan most", not a hand-sorted set of bound pages. That composition sentence
  rests on the look alone; the owner's tags count 1 Handwritten and 4 Clippings among the curved pages (0 and 1 among
  the flat), and the gap without them is in the Verdict.
- **Comparison.** The same route, writer, drag scorer and truth rule on both sets, with Vision read again on the
  upright copies of both. The route deskews 11 curved pages and 8 flat ones. The raw-photograph arm, scored on every
  page, shows the same gap (−20.5, −30.0 to −10.4).
- **Noise.** 32 pages a set: 1,316 curved and 1,132 flat scored lines. The interval is a two-sample page bootstrap
  (2,000 draws, pages resampled within each set). The paired figure is the mean of the 32 pairs' differences, also
  bootstrapped. Vision and blla are deterministic on a page, so the rerun floor is 0 for the same images. The gap is
  far outside both intervals' width.
- **Scope.** Print placement only. Handwritten pages in either set were scored on the print route, not on
  `hand-blla-ctc`. This does not measure whether a dewarped copy, a sloped run or a curved run would recover the loss
  on these pages; it only shows the loss. It does not settle how many pages are truly bound, since the cue also counts
  perspective. The JPEG originals cover 3,747 of the sample's images, and sample PDFs with no image partner were not
  surveyed (UIUC's HEIC originals excepted).
