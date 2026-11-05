## What this says (Mac arms; GLM-OCR and Qwen3.6-27B wait for Sherlock)

**Whole page is as good as reading the mark's region, for both Mac readers.** Apple Vision given the whole page gets
14 of the 35 marks, against 13 from the owner's own box; LightOnOCR-3 4B gets 16 against 17. Both gaps are one mark,
inside intervals about 30 points wide, so they are ties. The readers do not get the *same* marks the two ways
(LightOnOCR: 9 both ways, 7 only whole, 8 only from the box), so a route that read both would carry more, but that
is a two-reader cascade and is not ranked here. Through a detector the region route is far worse (2-6 of 35 through
YOLO11m), because detection is (W46.marks-detect). So on today's detectors **region routing does not beat the
whole page for marks on the Mac, and the whole page needs no detector**: the case for W46.marks-detect-own rests on
whether the cluster readers or Gemini miss marks that a region would catch.

Chance agreement is small. A mark's text scores 0.8 against another page's text on 1.7% of pairs, and 8 marks
(all but one under 9 characters; the other a stamp that recurs across a collection's pages) do so on some other
page; one of each reader's whole-page reads is among them.

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
  corrected by the owner; no reader scored here drafted them. Per-line kind has no owner label: a Vision line is
  labelled handwritten when half its box lies in an owner annotation, marginal-note or signature box, typed when
  under a tenth lies in any mark box (MRK-1; the Azure flags the item named were never made).
- **Selection.** Every owner-reviewed text on the eligible pages, the set W46.marks-detect read; none chosen by a
  reader or by ABBYY text. The pages were drawn for the marks set by the owner's protocol (phase A independent of
  any reader, phase B by a Qwen3.6-27B pre-flag band), so they are not a corpus sample (no population weights, P3-3).
- **Comparison.** Same pages, same marks, each reader at fixed settings both ways: Vision at the app's settings on
  the 2,400 px freeze copy whole and on the crops; LightOnOCR-3 4B with its card's empty prompt, temperature 0, the
  page at 2,048 px and 4,096 tokens (no page reached the cap), crops as `marks_read.py` cut them (1% pad, at least
  768 px). The whole-page score aligns the mark to its closest stretch of page text, which is kinder than scoring a
  crop's whole reply; the floor row bounds what that kindness can buy.
- **Noise.** n = 35 marks on 17 pages; page bootstrap, 2,000 resamples, seed 46; read-rate intervals about ±16
  points, so every whole-against-box gap here is a tie. Both readers are deterministic at these settings; no rerun
  floor was measured.
- **Scope.** Marks only: these pages have no body-text truth, so the body cost of region routing on mixed pages is
  W46.ocr-regions' and W46.layout-photo's result on the 96, not this one. Not settled here: GLM-OCR and Qwen3.6-27B
  (Sherlock pack `mixed-route-20261105`), Gemini (W46.mixed-route-paid), results by handwriting band
  (W46.mixed-route-bands), and whether a two-reader cascade is worth its cost. The layer check is PDFKit and the
  Spotlight importer on scratch PDFs, not the Processor's own writer.
