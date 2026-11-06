# Mixed-page routing by handwriting amount, with cost and time (W46.mixed-route-bands)

W46.mixed-route's scores cut by the four handwriting bands of `mixed-def-score.md` (owner, 2026-10-28), with each route's time and cost a page and the typed-text cost of a handwriting reader (`mixed_route_bands.py`; figures in `mixed-route-bands.json`). No new model was run and nothing was spent: every reading is W46.mixed-route's or the 96-page OCR panel's. W46.mixed-route-paid (Gemini) was retired by the owner on 2026-11-05, so it has no row.

## The bands on the marks core

Each of the 32 detector-eligible core pages is banded by its owner-reviewed handwriting (MRK-1): the words of its annotations and marginal notes (stamps and "other" marks are not handwriting). Signatures, initials and date-only notes make the first band. A page with a handwritten mark the owner left unread has no known count.

| Band (owner core) | Pages | A-core | B-core |
|---|---:|---:|---:|
| No handwriting (print or stamps only) | 15 | 11 | 4 |
| Signature, initials or date only | 5 | 1 | 4 |
| Under about 10 words | 4 | 2 | 2 |
| About 10-29 words | 4 | 0 | 4 |
| 30 words or more | 1 | 0 | 1 |
| Handwriting the owner left unread | 3 | 1 | 2 |

The unread pages' known words: 0, 0, 12 (so one of the three is at least the 10-29 band).

The Qwen3.6-27B pre-flag band the pages were drawn by (rows) against the owner-core band (columns):

| Pre-flag \ owner | No handwriting (print or stamps only) | Signature, initials or date only | Under about 10 words | About 10-29 words | 30 words or more | Handwriting the owner left unread |
|---|---:|---:|---:|---:|---:|---:|
| No handwriting (print or stamps only) | 15 | 0 | 0 | 0 | 0 | 0 |
| Signature, initials or date only | 0 | 4 | 1 | 1 | 0 | 0 |
| Under about 10 words | 0 | 0 | 1 | 2 | 0 | 3 |
| About 10-29 words | 0 | 1 | 2 | 1 | 0 | 0 |
| 30 words or more | 0 | 0 | 0 | 0 | 1 | 0 |

The pre-flag band agrees with the owner core on 22 of 32 pages, but 15 of those are pages with no handwriting; on the 14 pages with handwriting of a known band it is right on 7. So a result cut by the pre-flag band would be cut by the wrong band about half the time.

## Marks read, by band

Marks read at NES >= 0.8 (all owner-reviewed marks on the band's pages, stamps included; the handwritten annotations and marginal notes alone in brackets). The no-handwriting band's marks are stamps only.

| Route | No handwriting (print or stamps only) | Signature, initials or date only | Under about 10 words | About 10-29 words | 30 words or more | Handwriting the owner left unread |
|---|---|---|---|---|---|---|
| Apple Vision, whole page (the app's settings) | 3 of 4 | 4 of 6 (2 of 3) | 2 of 6 (1 of 5) | 1 of 9 (1 of 8) | 4 of 9 (2 of 7) | 0 of 1 (0 of 1) |
| LightOnOCR-3 4B 8-bit, whole page (mlx-vlm, Mac) | 2 of 4 | 4 of 6 (2 of 3) | 2 of 6 (2 of 5) | 2 of 9 (1 of 8) | 6 of 9 (4 of 7) | 0 of 1 (0 of 1) |
| GLM-OCR, whole page (Sherlock) | 0 of 4 | 3 of 6 (1 of 3) | 3 of 6 (2 of 5) | 2 of 9 (2 of 8) | 5 of 9 (4 of 7) | 0 of 1 (0 of 1) |
| Qwen3.6-27B, whole page (Sherlock) ‡ | 3 of 4 | 5 of 6 (2 of 3) | 4 of 6 (3 of 5) | 7 of 9 (6 of 8) | 6 of 9 (4 of 7) | 1 of 1 (1 of 1) |
| Apple Vision, the owner's box (oracle) | 3 of 4 | 4 of 6 (2 of 3) | 2 of 6 (1 of 5) | 2 of 9 (1 of 8) | 2 of 9 (1 of 7) | 0 of 1 (0 of 1) |
| LightOnOCR-3 4B 8-bit, the owner's box (oracle) | 3 of 4 | 5 of 6 (2 of 3) | 4 of 6 (3 of 5) | 3 of 9 (3 of 8) | 1 of 9 (0 of 7) | 1 of 1 (1 of 1) |
| GLM-OCR (Sherlock), the owner's box (oracle) | 2 of 4 | 5 of 6 (2 of 3) | 3 of 6 (2 of 5) | 5 of 9 (4 of 8) | 3 of 9 (1 of 7) | 0 of 1 (0 of 1) |
| Qwen3.6-27B (Sherlock), the owner's box (oracle) ‡ | 3 of 4 | 5 of 6 (2 of 3) | 5 of 6 (4 of 5) | 3 of 9 (2 of 8) | 2 of 9 (1 of 7) | 1 of 1 (1 of 1) |

‡ Not ranked (MRK-1): it chose the B-core pages by its own pre-flag, and every page in the 10-29 and 30-plus bands is a B-core page.

## Time and tokens a page, by band

Whole-page reads of the 32 pages. Apple Vision ran as one batch, 1.31 s a page on average. LightOnOCR-3 4B on the M3 Pro (an engine session's timing, so an upper bound); GLM-OCR and Qwen3.6-27B on one Sherlock GPU each at concurrency 16, so a request's latency under load, not its share of the GPU. Median seconds (median output tokens):

| Reader | No handwriting (print or stamps only) | Signature, initials or date only | Under about 10 words | About 10-29 words | 30 words or more | Handwriting the owner left unread |
|---|---|---|---|---|---|---|
| LightOnOCR-3 4B 8-bit, whole page (mlx-vlm, Mac) | 31.3 s | 26.7 s | 21.5 s | 23.4 s | 17.4 s | 27.2 s |
| GLM-OCR, whole page (Sherlock) | 4.2 s (534) | 3.1 s (438) | 4.7 s (313) | 4.0 s (304) | 2.0 s (192) | 5.9 s (415) |
| Qwen3.6-27B, whole page (Sherlock) | 15.1 s (572) | 8.3 s (476) | 10.5 s (321) | 11.4 s (346) | 5.4 s (203) | 15.1 s (465) |

Time follows the page's text, not its handwriting: the pages with the most handwriting carry the least print and are read fastest. A band adds no time of its own; what adds time is sending the page to a slower reader at all.

## The typed-text cost of a handwriting reader

The marks core has no body-text truth, so this is read off the owner's 96 OCR truth pages (`ocr-scorers-pages.csv`, the current scorer): each reader against Apple Vision on the same typed and printed pages, which is what a signature-only or few-word page mostly is. Body NES in points, paired by page (95% page bootstrap); *worse pages* are pages more than 2 points below Vision's. Cost is the panel's per-page price (an estimate from tokens and list price; Mac and Sherlock routes cost no money).

| Route | Typed and printed pages | Body NES | Against Vision | Worse pages | Cost a page |
|---|---:|---:|---|---:|---:|
| Apple Vision (the app's settings) | 78 | 88.0 | (reference) | 0 | $0 |
| LightOnOCR-3 4B 8-bit (Mac) | 78 | 89.8 | +1.8 (-2.2 to +5.9) | 14 | $0 |
| GLM-OCR | 78 | 92.3 | +4.3 (+0.4 to +8.8) | 20 | $0 |
| Qwen3.6-27B (hosted) | 78 | 95.3 | +7.3 (+2.6 to +12.3) | 6 | $0.0019 |
| Gemini 3.7 Flash (gateway) † | 78 | 97.4 | +9.4 (+5.8 to +13.6) | 0 | $0.0039 |

† Gemini 3.7 Flash is a relative of Gemini 3.8 Flash, one of the 96's two truth drafters, so its gain is partly agreement with its relative's text; it is shown for its cost, not ranked.

Only 2 of the 96 are mixed pages, so mixed pages have no body figure of their own (LightOnOCR-3 4B is -12.1 points against Vision on those two: two pages, not a result).

## How many pages each band is

Post-stratified share of the 2,000-page bulk-pilot draw (mixed-def-score.md's estimator), with a 95% interval from resampling the owner's 170 answers within each sheet stratum (KND-3); the unsampled strata's assumptions stay as mixed-def-score.md states them.

| Band | The band alone | This band or more |
|---|---|---|
| Signature, initials or date only | 8.7% (4.0-16.7%) | 33.0% (24.2-44.2%) |
| Under about 10 words | 20.9% (13.8-30.8%) | 24.4% (17.1-33.5%) |
| About 10-29 words | 2.2% (0.8-3.5%) | 3.4% (1.6-4.5%) |
| 30 words or more | 1.2% (0.4-1.5%) | 1.2% (0.4-1.5%) |

## What this says

**Sending a signature-only or few-word page through a handwriting reader does not lower its typed-text accuracy.**
On the 96's 78 typed and printed pages every handwriting-capable reader is level with Apple Vision or better on body
NES: LightOnOCR-3 4B +1.8 points (a tie, -2.2 to +5.9), GLM-OCR +4.3, Qwen3.6-27B +7.3. A typed page is what a
signature-only page mostly is, so the band does not change the answer: a page loses no typed accuracy for being
routed for its handwriting. The per-page spread is real, though: LightOnOCR is more than 2 points below Vision on 14 of
the 78 pages and GLM-OCR on 20, so a given page can lose even where the average gains. Mixed pages themselves have
no body truth (2 of the 96), so this is the typed-text cost measured where the typed text is, not on mixed pages.

**What it costs is time, or money, not accuracy.** On the Mac, Vision reads a page in about 1.3 s and LightOnOCR-3 4B
in about 24 s (an upper bound), so routing a page to the Mac handwriting reader costs about 19 times the time and
no money. Hosted, Qwen3.6-27B costs about $0.002 a page and Gemini 3.7 Flash about $0.004. The band does not change the
time: a page's time follows its print, and the pages with the most handwriting were read fastest. With mixed pages an
estimated 33% (24-44%) of the draw, routing all of them on the Mac adds about 2.1 hours a thousand pages (1.6-2.8);
leaving out the signature-only band (8.7%, 4.0-16.7%) saves about a quarter of that.

**On marks, the bands are too small to tell routes apart, and the signature-only band gains little.** The
signature-only band's handwriting is three dates, which Vision reads as often as LightOnOCR-3 4B (2 of 3 whole
page; GLM-OCR 1). The one 30-plus page is the only place the whole page clearly leads the owner's box (whole page 2-4 of
its 7 handwritten marks, from the box 0-1), and every 10-29 and 30-plus page is a B-core page, chosen by Qwen3.6-27B's
pre-flag. Per band there are 3-9 marks: no band figure is a ranking.

**Recommendation: give users the choice, with the trade-off stated, not a default that hides it.** A setting such as
"Read handwriting on typed pages (signatures, dates, notes in the margin)" with a note that it costs about 19 times
the reading time on this Mac (or about $0.002-0.004 a page hosted) and does not lower the typed text's accuracy. A
finer choice by band (leave out signature-only pages) saves about a quarter of the time on these estimates but
needs a page's band before it is read, and the pre-flag guessed the band right on 7 of 14 pages; it is not worth a
setting of its own on this evidence. The setting is filed as W46.mixed-route-setting, behind Phase 4 and the
settings research, which decide the settings layer.

## Measurement card

- **Truth.** Marks: the 35 owner-reviewed mark texts of W46.mixed-route (drafted by Gemini 3.7 Flash and Qwen3-VL 8B,
  kept or corrected by the owner); bands from the owner core's own marks and texts, not the pre-flag (MRK-1). Body:
  the owner's 96 OCR truth pages, drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner
  (`ocr-truth.md`); Gemini 3.7 Flash is a drafter's relative and is not ranked. Share: the owner's 170 answers
  (`mixed-def-score.md`).
- **Selection.** No page chosen here. The marks core is W46.marks-set's (A-core independent of any reader, B-core by
  Qwen3.6-27B's pre-flag band); every 10-29 and 30-plus page is B-core, and Qwen3.6-27B is not ranked on it. The 96
  are the panel's fixed draw (seed 41). None chosen by a tested route or ABBYY text.
- **Comparison.** W46.mixed-route's settings unchanged for the marks; the 96-page panel's settings for the body
  figures (every route on the same 78 pages). Times come from three machines and load conditions and are stated as
  such; they compare routes, not hardware.
- **Noise.** Marks: 3-9 marks a band, too few for any band-level difference to be more than a tie. Body: paired page
  bootstrap, 2,000 resamples, seed 46; LightOnOCR-3 4B's gain is inside it, GLM-OCR's and Qwen3.6-27B's are not. No
  rerun floor is measured for the open readers (W46.ocr-rerun-noise covers Vision and the gateway). Share: within-
  stratum resampling of the owner's answers; the unsampled strata's assumptions are not in the interval.
- **Scope.** Descriptive only (P3-3): no band figure is weighted to the corpus. Not settled: the typed-text cost on
  mixed pages themselves (no body truth there), Gemini on mixed pages (retired), a two-reader cascade, and the
  setting's form (Phase 4, W46.settings-design-research).
