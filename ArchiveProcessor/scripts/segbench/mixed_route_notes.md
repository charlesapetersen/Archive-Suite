## What this says

**Whole page instead of the mark's region is not shown worse for any reader ranked on all 35, and a detector makes
the region route far worse.** Apple Vision given the whole page gets 14 of the 35 marks, against 13 from the owner's
own box; LightOnOCR-3 4B gets 16 against 17; GLM-OCR 13 against 18. The Vision and LightOnOCR gaps are one mark.
GLM-OCR's is five (3 marks only whole, 8 only from the box; exact sign test on the 11 discordant marks p = 0.23),
inside intervals about 30 points wide, so it leans to the box but is not shown; on the A-core GLM-OCR's whole page
reads none of the 5 marks against 3 of 5 from the box. Through YOLO11m's boxes alone every reader falls to 2-6 of 35
(W46.marks-detect), so on today's detector **region routing in place of the whole page loses marks**.

**But a whole-page reader does miss marks a region pass reads (W46.marks-two-pass).** The readers do not get the
*same* marks the two ways (LightOnOCR: 9 both ways, 7 only whole, 8 only from the box), and a detector would serve as
a region pass added to the whole page, the text layer carrying both readings, so its ceiling is the union, not the box
alone: given the owner's box as well, Vision reads 17, LightOnOCR-3 4B 24 and GLM-OCR 21 of 35, against 14, 16 and 13
whole page. Those gains are not doubled text buying matches by chance: the same reader's crop of a different mark on
the same page reads a missed mark 0-1 times in 33-53 tries (the Two passes table), so LightOnOCR's 8 (sign test
p = 0.016) and GLM-OCR's 8 (p = 0.008) stand, and Vision's 3 (p = 0.25) does not. By core the gain is mostly B-core:
on the A-core's 5 marks the union adds nothing for Vision (4 and 4), one for LightOnOCR (3 to 4) and three for GLM-OCR
(0 to 3). Today's detector reaches little of it: whole page plus a YOLO11m box adds 0-3 marks per
reader at either floor, none significant (p >= 0.5), and its own floor is about one mark. These are the owner's
boxes, so a trained detector would get less than the union. A second sense in which the layer needs a box: the form
that works is an invisible run at the mark's box (below), and only Vision's whole-page reply carries coordinates (13
of its 14 whole-page reads are read again from the lines meeting the mark's box); LightOnOCR's, GLM-OCR's and
Qwen3.6-27B's replies are plain text, so a mark they read whole page cannot be placed without a box. A fine-tuned
detector (W46.marks-detect-own) would be judged against the union, not against the owner's-box figure alone.

**Qwen3.6-27B reads the most marks whole page, but it cannot be ranked on these pages (MRK-1).** Whole page it gets
26 of 35 (mean NES 0.86) against 19 from the owner's box (18 both ways, 8 only whole, 1 only from the box). But 30 of
the 35 marks are on B-core pages, which were drawn from Qwen3.6-27B's own pre-flag, so those figures are chosen by
its own pre-flag; on the A-core it reads 3 of 5 whole and 4 of 5 from the box, too few to rank. Its whole-page
figure also leans most on chance: 5 of its 26 reads score 0.8 against some other page's text too (short marks and
the recurring stamp; 1-2 for the other readers). Ranking it on marks needs marks it did not choose, which is
W46.marks-detect's A-core rule and is not available here.

GLM-OCR read the 86 requests in 12 s on one card at concurrency 16 (median 4.0 s a whole page under that load) and
Qwen3.6-27B (FP8) in 41 s (13.1 s); both jobs, model load included, took 2 and 6 minutes, about 0.13 GPU-hours in
all against the 0.5 expected. No page hit the 4,096-token cap.

Chance agreement is small. A mark's text scores 0.8 against another page's text on 1.7% of pairs, and 8 marks
(all but one under 9 characters; the other a stamp that recurs across a collection's pages) do so on some other
page; one of Vision's and of LightOnOCR's whole-page reads is among them, two of GLM-OCR's and five of
Qwen3.6-27B's. The same-page floor (each mark against its own page's Vision text with the lines in its box
removed, measured in measurement review pass 10) is 1 of 35, a 2-character annotation already among these.

**Per-line kind: Vision's line periodicity does not tell handwriting from type on these pages.** On every labelled
line the AUC is 0.49 (periodicity) and 0.56 (harmonic); on the lines of 15 characters or more it is 0.32, the wrong
way round, on only 20 handwritten lines from 7 pages. Line height separates them better (0.87-0.92): handwritten
lines sit in taller boxes. That is one cue, not a classifier, and the labels come from the owner's rough mark boxes,
so the 51 handwritten lines include some edges of print. Kind-signals.swift's periodicity was designed to tell
typewriter from print, and it does not carry over to handwriting.

**The text layer: a labelled invisible run at the mark's box is the form that works.** With the run fitted to its
box (not stretched), all 35 marks are found by the Reader's Find, the hit lands on the mark, a drag over the mark
selects it, and Spotlight's importer takes it. A FreeText annotation is invisible to all of them: it scores the
same as the control with no marks at all (3-4 of 35, which is print agreeing with short marks). A text page after
the image is found and indexed (33 of 35; the two misses are the 300- and 351-character marks, which this test
writer draws as one unwrapped line off the page) but never placed on the mark. The first run of the check stretched
each run to its box's width, as `place_functional.swift oracle` does by default, and Find then found only 14 of 35:
the stretched runs read back as spaced letters (W46.place-hands' finding), so the layer writer has to fit, not
stretch, a mark's run.

## Measurement card

- **Truth.** The 35 mark texts the owner reviewed on the 32 detector-eligible core pages (reconciled record
  `marks-set-reconciled-da388b05c388-dac79c80c2f6`), drafted by Gemini 3.7 Flash and Qwen3-VL 8B and kept or
  corrected by the owner; no reader scored here drafted them (Qwen3-VL 8B is a smaller relative of Qwen3.6-27B, a
  drafter's relative, and Qwen3.6-27B chose the B-core pages: Selection). Per-line kind has no owner label: a Vision line is
  labelled handwritten when half its box lies in an owner annotation, marginal-note or signature box, typed when
  under a tenth lies in any mark box (MRK-1; the Azure flags the item named were never made).
- **Selection.** Every owner-reviewed text on the eligible pages, the set W46.marks-detect read; none chosen by a
  reader or by ABBYY text. The pages were drawn for the marks set by the owner's protocol (phase A independent of
  any reader, phase B by a Qwen3.6-27B pre-flag band), so they are not a corpus sample (no population weights, P3-3). By MRK-1 (P10-2) Qwen3.6-27B is ranked on the
  A-core's 5 marks alone, too few to rank, and its B-core figures are labelled chosen by its own pre-flag; Vision,
  LightOnOCR and GLM-OCR are ranked on all 35.
- **Comparison.** Same pages, same marks, each reader at fixed settings both ways: Vision at the app's settings on
  the 2,400 px freeze copy whole and on the crops; LightOnOCR-3 4B with its card's empty prompt, temperature 0, the
  page at 2,048 px and 4,096 tokens (no page reached the cap), crops as `marks_read.py` cut them (1% pad, at least
  768 px); GLM-OCR and Qwen3.6-27B on Sherlock (vLLM, one GPU each) with W46.ocr-regions' request unchanged (the
  route's prompt, JPEG 95, temperature 0, 4,096 tokens), the page at 1,800 x 2,400 and crops cut to the same 1% pad
  (`sherlock/mixed-route/mixed_route_cluster.py`); 86 of 86 requests a reader answered, none capped. The whole-page score aligns the mark to its closest stretch of page text, which is kinder than scoring a
  crop's whole reply; the floor row bounds what that kindness can buy.
- **Noise.** n = 35 marks on 17 pages; page bootstrap, 2,000 resamples, seed 46; read-rate intervals about ±16
  points, so every whole-against-box gap of the ranked readers is a tie (GLM-OCR's five, the largest, sign test
  p = 0.23 on its 11 discordant marks). Vision's determinism is measured (its 2026-11-04 and 2026-11-05 runs give
  identical tokens on 32 of 32 pages); LightOnOCR's, GLM-OCR's and Qwen3.6-27B's at temperature 0 are asserted; no
  rerun floor was measured.
- **Scope.** Marks only: these pages have no body-text truth, so the body cost of region routing on mixed pages is
  W46.ocr-regions' and W46.layout-photo's result on the 96, not this one. Not settled here: Qwen3.6-27B's rank on marks
  (it chose 30 of the 35), Gemini (W46.mixed-route-paid, retired by the owner 2026-11-05), results by handwriting band
  (W46.mixed-route-bands), and whether a two-reader cascade is worth its cost. The two-pass union is taken on the
  owner's boxes, so it is a ceiling for a detector used beside the whole page, not a detector's figure: whether a
  trained one reaches it (W46.marks-detect-own, put to the owner 2026-11-05) and what the second pass costs in time
  are not measured, and its gains sit mostly on the B-core (Qwen3.6-27B's pre-flag chose those pages, which does not
  bias the other three readers but makes them pages rich in marks). The layer check is PDFKit and the Spotlight
  importer on scratch PDFs, not the Processor's own writer.
