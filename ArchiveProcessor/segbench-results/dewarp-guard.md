# A per-page guard for a dewarped reading copy (W46.dewarp-guard)

Owner, 2026-11-06 (call 6): no dewarped copy is offered. The revisit condition has three parts. First, split the 96's
lost words into own-sheet and neighbour (ENH-4). Second, test a "lattice keeps every word" guard on the 63 originals
and on Real5. Third, OCR-score Real5's quad and UVDoc arms (ENH-1's remaining half). On 2026-11-11 the owner moved
the item into the regular queue, with P12-5's step first: class place-curved-owner's 64 pages and restate the gap on
the bound or curled pairs. This report does all four.

Script: `scripts/segbench/dewarp_guard.py`. Figures: `dewarp-guard-class.json`, `dewarp-guard-96.json` and
`dewarp-guard-real5.json`. The only spend was the classing, $0.0957 on the Stanford gateway, which agrees with the
gateway's own figure of $0.0957.

## Verdict

- **The selection gap is on the bound or curled pages (P12-5).** Gemini 3.7 Flash classed each page without being
  told its set. It called 16 of the 32 curved pages bound and 8 curled. On those 24 pairs the print layer passes
  71.6% of lines against 93.5%: **−21.9 (−29.0 to −14.0)**, or −19.2 (−25.0 to −13.3) paired, with 19 of 24 pages
  worse. The 8 curved pages it called flat lose −7.9 (−14.4 to −1.9). The figure was restricted three ways, and the
  gap holds each time:
  - to bound or curled pages with neither display type nor handwriting on either page of the pair: −23.3 (11 pairs);
  - to pairs whose flat page the model also called flat: −14.7 (−27.1 to −0.7, 9 pairs);
  - to pages with bent lines whose flat page has straight lines: −14.9 (−26.0 to −4.2, 9 pairs).
- **Most of the 96's lost words are own sheet for UVDoc, and over half are neighbour for the quad (ENH-4).**
  - Quad: its 44 truth words split 19 own-sheet (on 4 pages) and 25 neighbour.
  - UVDoc: its 429 split 397 own (on 41 pages) and 32 neighbour.
  - The 63 originals: UVDoc's 170 split 138 own and 32 neighbour.
  - The no-crop rule therefore stands on own-sheet losses alone: UVDoc cuts the page's own text on 27 of the 63
    originals.
- **The guard removes UVDoc's harm on the owner's originals, and no gain appears.** The guard lets the arm's image
  through only when its lattice keeps every own-sheet word Vision read on the raw photograph. It passes UVDoc on 24 of
  the 63 originals and the quad on 54. Reading the arm where the guard passes and the raw photograph elsewhere, UVDoc's
  NES against raw on the originals is:
  - Gemini 3.7 Flash: +0.4 (−0.6 to +2.0);
  - Qwen3.6-27B: −0.5 (−3.2 to +1.6);
  - Vision: +0.1 (−2.0 to +2.7).
  
  Unguarded, the same figures are −2.5, −1.4 and −1.7. No paired interval is above 0, so §6's condition is still not
  met on the originals.
- **On Real5's warped photographs, UVDoc helps Vision, and the guard keeps most of the gain.** On the 155 Warping
  pages, Vision reads raw 78.5 NES, the quad crop 79.6 (+1.1, −1.3 to +3.4) and UVDoc 84.5 (**+6.0, +3.5 to +8.8**;
  79 pages better, 57 worse). Guarded UVDoc is **+4.3 (+2.2 to +6.6)**. The guard passes 112 of 155 images, and those
  pages gain +6.0 (+3.1 to +9.1). The 43 it holds back gain +0.1 on average, so it throws little gain away. Over all
  310 Warping and Skew images, the guard passes UVDoc on 218 and the quad on 296.
- **What this means for the call.** A guarded UVDoc does what an unguarded one does not: it removes no own-sheet word
  by construction, and it pays where pages are truly bent (Real5 Warping). On the owner's mostly flat originals it
  neither helps nor harms. The owner's pages where it could matter are place-curved-owner's 24 bound or curled pages,
  and nothing scores a guarded copy there yet. That is filed as **W46.dewarp-curved-select**: free selection drags
  with the guarded UVDoc copy against the route's copy on those pages. The 2026-11-06 call stands until the owner
  revisits it.

## 1. The 64 pages classed (P12-5)

Gemini 3.7 Flash (`gemini-3.7-flash`, Stanford gateway, temperature 0, low reasoning) saw each page once:

- upright, at the 2048 px long side and JPEG 0.85;
- with a fixed prompt asking for six fields: bound, curled or flat; lines bent; perspective; display type;
  handwriting; and a note of at most 15 words;
- without being told which set the page was in.

All 64 replies parsed. No Claude session looked at a page to class it (owner, 2026-10-30).

| field | curved (32) | flat (32) |
|---|---|---|
| page: bound / curled / flat | 16 / 8 / 8 | 8 / 11 / 13 |
| lines bent | 17 | 10 |
| perspective: strong / mild / none | 0 / 28 / 4 | 0 / 31 / 1 |
| display type | 3 | 0 |
| handwritten: mostly / some / none | 5 / 8 / 19 | 3 / 8 / 21 |

**The class is generous.** The model calls a sheet with one lifted corner "curled" (11 flat-set pages, seven of them with
"corner curled" notes), and it calls almost every page "mild" perspective, so that field does not separate the sets.

**Restating the gap.** The table below uses the same rows and drags as place-curved-owner (the route's copy, strict
pass on blla's lines). "Pooled" is a two-sample page bootstrap and "paired" is the mean pair difference, as in that
report.

| pairs | n | curved pass | flat pass | pooled Δ | paired Δ | pages worse |
|---|---:|---:|---:|---|---|---:|
| all | 32 | 74.3 | 94.1 | −19.8 (−26.2 to −12.8) | −16.8 (−21.7 to −12.1) | 25 |
| **curved page bound or curled** | 24 | 71.6 | 93.5 | **−21.9 (−29.0 to −14.0)** | −19.2 (−25.0 to −13.3) | 19 |
| … and the flat page classed flat | 9 | 77.5 | 92.3 | −14.7 (−27.1 to −0.7) | −16.0 (−25.7 to −5.5) | 6 |
| … with lines bent, flat page's lines straight | 9 | 78.1 | 93.0 | −14.9 (−26.0 to −4.2) | −14.0 (−22.0 to −4.8) | 6 |
| … no display type, no handwriting on either | 11 | 72.2 | 95.5 | −23.3 (−34.6 to −11.7) | −20.4 (−29.3 to −10.6) | 9 |
| curved page not bound or curled | 8 | 87.8 | 95.7 | −7.9 (−14.4 to −1.9) | −9.5 (−14.9 to −4.2) | 6 |
| curved page has display type | 3 | 70.2 | 98.7 | −28.5 (−30.7 to 0.0) | −17.4 (−31.0 to 0.0) | 2 |

The owner's two pages: UIUC 00233 is classed bound with bent lines ("gutter shadow and faint bleed-through"), and UIUC
00149 curled with bent lines. The model put no page in "strong" perspective. So perspective explains little of the
cue on this set, and the three display-type covers are too few to read.

## 2. The 96's lost words, own sheet against neighbour (ENH-4)

These come from the cached enh-dewarp lattices (`grids/<arm>/<page>.npz`), its raw Vision reading on macOS 26.6 and
Apple's quad. No model ran.

**Lost words.** A word is lost when its centre lies in no lattice cell carried into the source (enh-dewarp's
`covered`). It is own sheet when its centre is inside Apple's quad or another word of its Vision line is still shown
(place-geom's rule, a line cut through). Otherwise it is neighbour text.

**Truth words** are the raw words that align to the truth text (enh-dewarp's `truth_words` rule). Their totals
reproduce enh-dewarp's 44 and 429 exactly. "All Vision words" counts every word Vision read, which is what an in-app
guard can see.

| pages | arm | truth words lost: own (pages) | neighbour (pages) | all Vision words lost: own (pages) | neighbour (pages) |
|---|---|---|---|---|---|
| 63 originals | quad | 19 (4) | 25 (8) | 42 (9) | 223 (19) |
| 63 originals | UVDoc | 138 (27) | 32 (9) | 297 (39) | 247 (20) |
| 63 originals | DocRes | 1,054 (37) | 27 (8) | 1,542 (43) | 212 (20) |
| the 96 | quad | 19 (4) | 25 (8) | 42 (9) | 223 (19) |
| the 96 | UVDoc | 397 (41) | 32 (9) | 676 (56) | 247 (20) |
| the 96 | DocRes | 4,105 (68) | 27 (8) | 5,335 (75) | 212 (20) |

Apple found a quad covering the whole image on the 33 PDF images, so the quad cuts nothing there. UVDoc cuts 379
own-sheet words on them. DocRes's lattice folds on about 14 pages (enh-dewarp.md), so its rows describe its lattice,
not the image Vision read.

## 3. The guard

**The guard.** An arm's image passes when no own-sheet Vision word of the raw photograph falls outside its lattice.
It uses only what the app has at that point: Vision's words on the raw image, Apple's quad and the dewarper's lattice.
A stricter form ("no word at all") is in the JSON: on the originals it passes UVDoc on 19 and the quad on 41.

**The guarded pipeline** reads the arm's image where the guard passes and the raw photograph elsewhere, so a held-back
page contributes 0. "Passing only" is the gain on the pages it lets through. NES is in points against raw, as a
95% page bootstrap of the mean paired difference. The readings are enh-dewarp's committed per-page rows:
`enh-dewarp-pages.csv` (Vision 26.6), `enh-dewarp-gateway.csv` and `enh-dewarp-cluster.csv`.

| pages | arm | guard passes | reader | every page | guarded | passing only |
|---|---|---:|---|---|---|---|
| 63 originals | UVDoc | 24 | Gemini 3.7 Flash | −2.5 (−5.3 to −0.0) | +0.4 (−0.6 to +2.0) | +1.1 (−1.5 to +5.3) |
| 63 originals | UVDoc | 23 of 62 | Qwen3.6-27B | −1.4 (−4.8 to +1.6) | −0.5 (−3.2 to +1.6) | −1.4 (−8.4 to +4.7) |
| 63 originals | UVDoc | 24 | Vision (26.6) | −1.7 (−5.2 to +1.6) | +0.1 (−2.0 to +2.7) | +0.1 (−5.3 to +7.2) |
| 63 originals | quad | 54 | Gemini 3.7 Flash | −0.3 (−1.5 to +1.4) | +0.2 (−0.8 to +1.7) | +0.2 (−0.9 to +1.9) |
| 63 originals | quad | 54 | Qwen3.6-27B | +0.3 (−2.5 to +2.7) | −0.0 (−2.6 to +2.2) | −0.0 (−2.9 to +2.5) |
| 63 originals | quad | 54 | Vision (26.6) | −1.4 (−4.1 to +1.6) | −0.2 (−2.5 to +2.5) | −0.2 (−3.0 to +2.9) |
| the 96 | UVDoc | 40 | Gemini 3.7 Flash | −2.6 (−4.6 to −0.7) | +0.3 (−0.4 to +1.3) | +0.6 (−0.9 to +3.0) |
| the 96 | UVDoc | 39 of 95 | Qwen3.6-27B | −2.4 (−5.3 to +0.0) | −0.9 (−2.9 to +0.9) | −2.1 (−7.5 to +2.0) |

Qwen's one unread original is left out of its rows. The guard turns UVDoc's loss into a tie on the owner's pages, but
no reader gains. Those pages are mostly flat loose sheets (10 curl-tagged), where a dewarp has little to straighten.

## 4. Real5: the guard and the OCR arms

The source is place-geom-real5's 310 images: Real5-OmniDocBench's Warping and Skew copies of the 155 English
OmniDocBench v1.5 pages with plain-text truth.

- They were fetched again from Hugging Face and frozen as before (2,400 px, JPEG 90).
- Vision on macOS 27.2 reads the raw images line for line as place-geom-real5's cached readings on 309 of 310, so the
  images are the same.
- Apple's quads are place-geom-real5's.
- UVDoc 4c9b82b5 (`best_model.pkl`) ran on the quad crop, on CPU, in the shared torch environment (torch 2.15). On two
  of the 96 its lattice sits within 0.0035 of the page (about 8 px at 2,400 px) of enh-dewarp's venv run. That is
  close, not bit-identical. Here UVDoc's own-sheet loss counts 495 Vision words on the 310 images, where
  place-geom-real5 counted 443. The neighbour count, 97, and the quad's 79 and 65 match exactly.
- Vision read each Warping arm image (frozen as the panel freezes) with `segbench-dewarp lines`. It was scored against
  OmniDocBench's text with `ocr_panel_score` (NES, chrF2).

**Vision on Real5 Warping (155 pages):**

| arm | NES | Δ NES vs raw | Δ chrF2 | better / worse | own-sheet words removed (images) | guard passes | guarded Δ NES |
|---|---:|---|---|---|---|---:|---|
| raw | 78.5 | — | — | — | — | — | — |
| quad crop | 79.6 | +1.1 (−1.3 to +3.4) | +5.5 (+3.4 to +7.8) | 70 / 60 | 31 (9) | 146 | +0.1 (−2.1 to +2.2) |
| UVDoc after the quad | 84.5 | **+6.0 (+3.5 to +8.8)** | +6.1 (+3.7 to +8.6) | 79 / 57 | 254 (43) | 112 | **+4.3 (+2.2 to +6.6)** |

**The guard over all 310 images:**

| folder | arm | own-sheet words lost (images) | neighbour (images) | guard passes |
|---|---|---|---|---:|
| Warping | quad | 31 (9) | 15 (7) | 146 of 155 |
| Warping | UVDoc | 254 (43) | 17 (8) | 112 of 155 |
| Skew | quad | 48 (5) | 50 (2) | 150 of 155 |
| Skew | UVDoc | 241 (49) | 80 (4) | 106 of 155 |

## Measurement card

- **Truth.**
  - Classing: there is none. The classes are one Gemini 3.7 Flash reply a page, checked by no one. It is not a scored
    route here, only a filter on place-curved-owner's figure. Its "curled" is generous (§1).
  - The 96: the owner-adjudicated truth text of the OCR panel. Lost words are counted on raw Vision words aligned to
    it, so a truth word Vision missed on the raw image is not counted.
  - Real5: OmniDocBench v1.5's human text, made on the digital page, not on the photographs. All three arms are scored
    against the same text.
  - The owner checked nothing in this item.
- **Selection.**
  - The 64 pages are place-curved-owner's, chosen by its line-angle cue.
  - The 96 are the frozen benchmark, and the 63 originals are its JPEG-original pages (`pages.tsv` source).
  - Real5 is every English plain-text page of OmniDocBench v1.5 in two folders.
  - No tested route and no ABBYY text chose a page.
  - The guard decides per page from the raw reading and the lattice, never from the truth.
- **Comparison.**
  - On the 96 every arm has the same raw reading, quad, lattices and readers. The NES rows are enh-dewarp's committed
    readings, unchanged: Vision on 26.6, Gemini through the gateway, Qwen on Sherlock.
  - On Real5 the three arms are read by Vision on 27.2 in one run, frozen and scored the same way.
  - The class restatement uses place-curved-owner's rows unchanged.
- **Noise.**
  - Intervals are 95% bootstraps over pages (2,000 draws, seed 4611): paired for the arm gains and pair differences,
    two-sample for the pooled gaps.
  - Vision, UVDoc on CPU and the guard are deterministic on an image, so their rerun floor is 0.
  - enh-dewarp's Gemini and Qwen rows carry their own rerun noise (enh-dewarp.md). A guarded gain inside about ±1 for
    them is a tie.
  - The class subsets are small (9 to 24 pairs), and their intervals say so.
- **Scope.**
  - Real5's gain is Vision's alone. Gemini and Qwen were not run on Real5 (free item; §6's condition names them on the
    originals).
  - The 96's Vision rows are 26.6 readings (W46.vision-27-swap).
  - Nothing here scores a guarded dewarp for selection on the owner's bound or curled pages. That is
    W46.dewarp-curved-select.
  - The guard is checked on word centres, so a word whose centre is shown but whose ink is clipped passes.
