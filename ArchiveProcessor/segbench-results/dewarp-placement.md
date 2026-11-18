# Dewarp for placement only, and the licence-freed dewarpers, on bound or curled pages (W46.dewarp-placement)

W46.dewarp-curved-select scored a guarded UVDoc *reading copy*: the layer is carried onto the dewarped image, which
the user then keeps. Owner review of the pipeline doc (2026-11-17) asked for two things never tested: keep the image
the user keeps (the route's raw or deskewed copy) and use the dewarp only to place the layer, Vision reading the
flattened image and its words carried back onto the original through the dewarper's own lattice (enh-dewarp.md,
"Line boxes carried back through the saved lattice"); and DvD and DocTr++, which the 17 Nov licence call allows as
optional downloads.

Script: `scripts/segbench/dewarp_placement.py` (tests: `test_dewarp_placement.py`; the DvD and DocTr++ wrappers:
`dewarp_extra_arms.py`). Figures: `dewarp-placement.json`. No model was called through any API and nothing was spent.

## Verdict

- **Placing the layer through a dewarp, on the image the user keeps, selects worse than the route.** On the 24 bound
  or curled pages, on the blla lines both score: UVDoc −8.9 (−17.6 to −1.8) with one level run a line and −7.6
  (−16.7 to 0.0) with the line split into runs that follow the bend; DvD −8.9 (−13.8 to −4.6) and −7.2 (−13.0 to
  −1.0). Their flat pairs lose too (−2.2 to −3.2). Nothing here argues for revisiting the 2026-11-06 call (no
  dewarped copy) in favour of placement through a dewarp.
- **Why: the bend is still on the page the layer sits on.** Vision reads the flattened image in slightly longer lines
  (6.6 words a line against 6.2 raw, page medians on the 24), and those lines, carried back, span 1.55 word heights on
  the bent photograph against 1.40 for raw Vision's own lines. A level run over that box, or a stack of level runs,
  gives PDFKit more line breaks: 195 to 272 broken lines against the route's 117. A placement-only gain would need a
  writer that lays text along a curve (a run per word, or a rotated run per segment); no writer we have does.
- **DvD is worse than UVDoc as a reading copy.** It crops the page on nearly every photograph (the own-sheet guard
  passes it on 1 of the 24 curved pages and 3 of the flat pairs, UVDoc on 12 and 10): unguarded −11.9 (−25.4 to
  0.0) curved and −11.3 (−17.1 to −4.9) on the flat pairs; guarded −0.1, since it is nearly always held back. UVDoc
  stays the only dewarper with a guarded gain (+3.2, +0.4 to +7.7, as in dewarp-curved-select).
- **DocTr++ could not be measured.** Its authors publish no weights (DocTr-Plus 2b12e48: the README says to put
  `DocTrP.pth` in `model_pretrained/`, with no link in any commit, release or mirror; the DocTr Drive folder holds
  only DocTr's own). The wrapper is written and untested; running it needs the weights from the authors.
- **The owner's two pages.** UIUC 00233 (bound): route 21 of 27, UVDoc placement 19 (chunked 23), DvD placement 20
  (chunked 24); both guards hold the copies back (UVDoc cuts 8 own-sheet words, DvD 13). UIUC 00149 (curled): route
  33 of 33, UVDoc placement 29 of 34, DvD 23 of 32.

## The arms

All arms use place-curved-owner's 64 upright photographs, its blla truth lines and its drags (PDFKit, the lab
writer), as dewarp-curved-select did.

| arm | the image the layer sits on | the layer |
|---|---|---|
| route | raw, or deskewed at a median line angle of 1° or more | Vision's raw lines, one level run per line (place-curved-owner, replayed exactly) |
| d-copy | dewarper d's image after Apple's quad | Vision's raw lines carried onto it (dewarp-curved-select's uvdoc arm) |
| d-guarded | d-copy where the own-sheet guard passes, route elsewhere | as the arm it uses |
| d-place-line | the route's copy, unchanged | Vision's lines read on d's image, each word carried back through d's lattice; one level run per line |
| d-place-chunk | the route's copy, unchanged | the same words, each line split into consecutive level runs wherever one run would grow taller than 1.4 word heights |

- **Nothing is removed on a placement arm.** Raw Vision words that d's image does not show (outside its lattice) keep
  their raw lines in the layer.
- **A placement arm's words are its own.** Vision read the flattened image, so a blla line's expected words come
  from that arm's words, and an OCR difference is not a selection failure. Each arm is compared with the route on
  the blla lines both score; for the copy arms that is every line.
- **The replay holds.** The route's counts equal place-curved-owner's committed rows on all 64 pages, and the UVDoc
  copy and guarded arms equal dewarp-curved-select's to the line.

## Results

Pass rates are pooled over lines; "own" is the arm's own scored set, and the paired columns are on the blla lines
both the arm and the route score, with a 95% page bootstrap (2,000 draws, seed 4611). A "cut" line has a word the
arm's image does not show; a "broken" selection holds a line break.

**curved bound or curled** (24 pages; the guard passes UVDoc on 12, DvD on 1)

| arm | own lines | own pass % | cut | broken | lines both score | arm % | route % | Δ vs route, pooled | better / worse |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| route | 1,095 | 71.6 | 0 | 117 | | | | | |
| uvdoc-copy | 1,095 | 66.6 | 199 | 89 | 1,095 | 66.6 | 71.6 | −5.0 (−16.9 to +8.0) | 10 / 11 |
| uvdoc-guarded | 1,095 | 74.8 | 2 | 113 | 1,095 | 74.8 | 71.6 | +3.2 (+0.4 to +7.7) | 7 / 2 |
| uvdoc-place-line | 1,097 | 63.4 | 0 | 195 | 1,037 | 63.9 | 72.8 | −8.9 (−17.6 to −1.8) | 6 / 13 |
| uvdoc-place-chunk | 1,097 | 64.8 | 0 | 239 | 1,037 | 65.2 | 72.8 | −7.6 (−16.7 to +0.0) | 9 / 11 |
| dvd-copy | 1,095 | 59.7 | 255 | 74 | 1,095 | 59.7 | 71.6 | −11.9 (−25.4 to +0.0) | 6 / 18 |
| dvd-guarded | 1,095 | 71.5 | 0 | 118 | 1,095 | 71.5 | 71.6 | −0.1 (−0.3 to +0.0) | 0 / 1 |
| dvd-place-line | 1,086 | 62.5 | 0 | 200 | 1,034 | 63.3 | 72.2 | −8.9 (−13.8 to −4.6) | 4 / 18 |
| dvd-place-chunk | 1,086 | 64.6 | 0 | 272 | 1,034 | 65.1 | 72.2 | −7.2 (−13.0 to −1.0) | 12 / 11 |

**their flat pairs** (24 pages; the guard passes UVDoc on 10, DvD on 3)

| arm | own lines | own pass % | cut | broken | lines both score | arm % | route % | Δ vs route, pooled | better / worse |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| route | 851 | 93.5 | 0 | 25 | | | | | |
| uvdoc-copy | 851 | 89.7 | 27 | 35 | 851 | 89.7 | 93.5 | −3.9 (−7.0 to +0.0) | 2 / 12 |
| uvdoc-guarded | 851 | 94.6 | 0 | 17 | 851 | 94.6 | 93.5 | +1.1 (−0.6 to +3.8) | 2 / 1 |
| uvdoc-place-line | 842 | 91.2 | 0 | 37 | 835 | 91.4 | 93.5 | −2.2 (−4.8 to +0.3) | 5 / 10 |
| uvdoc-place-chunk | 842 | 90.9 | 0 | 42 | 835 | 91.0 | 93.5 | −2.5 (−5.0 to −0.1) | 5 / 11 |
| dvd-copy | 851 | 82.3 | 62 | 25 | 851 | 82.3 | 93.5 | −11.3 (−17.1 to −4.9) | 2 / 19 |
| dvd-guarded | 851 | 93.4 | 0 | 25 | 851 | 93.4 | 93.5 | −0.1 (−0.4 to +0.0) | 0 / 1 |
| dvd-place-line | 828 | 90.7 | 0 | 47 | 821 | 90.9 | 94.0 | −3.2 (−7.3 to −0.4) | 5 / 14 |
| dvd-place-chunk | 828 | 90.8 | 0 | 49 | 821 | 91.0 | 94.0 | −3.0 (−7.1 to −0.1) | 5 / 13 |

**curved, classed flat** (8 pages; the guard passes UVDoc on 1, DvD on 1)

| arm | own lines | own pass % | cut | broken | lines both score | arm % | route % | Δ vs route, pooled | better / worse |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| route | 221 | 87.8 | 0 | 13 | | | | | |
| uvdoc-copy | 221 | 84.6 | 11 | 12 | 221 | 84.6 | 87.8 | −3.2 (−6.6 to +0.0) | 2 / 6 |
| uvdoc-guarded | 221 | 87.3 | 7 | 11 | 221 | 87.3 | 87.8 | −0.5 (−1.2 to +0.0) | 0 / 1 |
| uvdoc-place-line | 222 | 86.0 | 0 | 17 | 214 | 86.4 | 87.4 | −0.9 (−5.7 to +2.2) | 1 / 2 |
| uvdoc-place-chunk | 222 | 85.1 | 0 | 19 | 214 | 85.5 | 87.4 | −1.9 (−9.1 to +1.5) | 2 / 2 |
| dvd-copy | 221 | 81.0 | 17 | 6 | 221 | 81.0 | 87.8 | −6.8 (−17.5 to −0.8) | 1 / 5 |
| dvd-guarded | 221 | 86.4 | 7 | 12 | 221 | 86.4 | 87.8 | −1.4 (−3.8 to +0.0) | 0 / 1 |
| dvd-place-line | 225 | 86.7 | 0 | 17 | 216 | 88.0 | 88.0 | +0.0 (−5.5 to +3.0) | 4 / 1 |
| dvd-place-chunk | 225 | 86.7 | 0 | 18 | 216 | 88.0 | 88.0 | +0.0 (−7.1 to +3.8) | 3 / 1 |

**all 64** (64 pages; the guard passes UVDoc on 28, DvD on 6)

| arm | own lines | own pass % | cut | broken | lines both score | arm % | route % | Δ vs route, pooled | better / worse |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| route | 2,448 | 83.5 | 0 | 165 | | | | | |
| uvdoc-copy | 2,448 | 78.4 | 246 | 164 | 2,448 | 78.4 | 83.5 | −5.0 (−10.6 to +0.5) | 14 / 35 |
| uvdoc-guarded | 2,448 | 84.9 | 9 | 159 | 2,448 | 84.9 | 83.5 | +1.4 (−0.1 to +3.3) | 9 / 7 |
| uvdoc-place-line | 2,439 | 78.4 | 0 | 266 | 2,361 | 79.1 | 84.2 | −5.0 (−9.3 to −1.6) | 13 / 30 |
| uvdoc-place-chunk | 2,439 | 78.9 | 0 | 317 | 2,361 | 79.5 | 84.2 | −4.7 (−9.2 to −1.2) | 17 / 29 |
| dvd-copy | 2,448 | 72.0 | 356 | 116 | 2,448 | 72.0 | 83.5 | −11.4 (−17.7 to −5.3) | 10 / 49 |
| dvd-guarded | 2,448 | 83.3 | 7 | 164 | 2,448 | 83.3 | 83.5 | −0.2 (−0.5 to +0.1) | 1 / 3 |
| dvd-place-line | 2,419 | 77.9 | 0 | 282 | 2,347 | 78.7 | 84.2 | −5.5 (−8.3 to −3.1) | 14 / 38 |
| dvd-place-chunk | 2,419 | 78.9 | 0 | 357 | 2,347 | 79.5 | 84.2 | −4.7 (−8.0 to −1.8) | 21 / 30 |

## Measurement card

- **Truth.** kraken blla's lines, as in place-curved-owner: a baseline segmenter, blind to Vision and to every
  dewarper. The page classes are dewarp-guard's single Gemini 3.7 Flash reply a page, checked by no one. The owner
  checked nothing in this item.
- **Selection.** place-curved-owner's 64 pages (its line-angle cue) and dewarp-guard's classes; no tested route and
  no ABBYY text chose a page.
- **Comparison.** Every arm has the same photograph, blla lines, writer and PDFKit drag tool. The placement arms
  differ from the route in two things at once, by design: the words (Vision on the flattened image) and their
  geometry (carried back through the lattice). The paired figure is on the blla lines both score.
- **Noise.** Vision, the dewarpers on CPU, the writer and PDFKit are deterministic on an image, so the rerun floor
  is 0. The sets are 24 pages each, and the intervals say so.
- **Dewarpers.** UVDoc 4c9b82b5 (`best_model.pkl`), CPU, torch-env, as in dewarp-curved-select. DvD db87dd2f
  (`model1852000.pt` sha256 0d7d50da058…, `line_model2.pth` 3890f1758e0b…, `seg.pth` cb79fdec55a5…, `seg_model.pth`
  b1716f4dec7f…), 3 sampling steps on CPU, about 3 s a page and 5 GB, through its own sampling loop with three local
  patches (`.cuda()` calls moved to the input's device in geotr_core.py and position_encoding.py; `block =
  self.blocks[-1]` where the released cross_model.py leaves it unbound, which the checkpoint bears out, since only
  block 11 has trained adaLN weights), `mpi4py` stubbed and mmcv's ConvModule replaced by conv → BN → ReLU (mmcv has
  no Mac wheel; the checkpoint loads with no missing or unexpected keys). Its map is scaled by its code's 0.987. The patches are
  `scripts/segbench/dewarp_dvd_local.patch`. Both
  run after Apple's quad.
- **Scope.** Selection on Vision's own layer, not OCR accuracy of the flattened reading. The 64 pages are photographs
  from the Reader sample and two UIUC originals; the dewarpers ran after Apple's quad, as UVDoc did in
  dewarp-curved-select.
