## Findings

**Yes, a handwritten page can leave the text page, given a reading that keeps the page's line breaks, and with a
per-page gate.** The best route on the owner's 20 audited hand pages: kraken `blla` lines (CPU, about 6 s a page)
with the reading force-aligned by a kraken CTC recogniser, one reading line to one detected line. With Gemini 3.8
Flash's saved reading, Find finds 1,511 of the 1,584 truth words of four or more letters (95%) and the highlight
lands on the word for 1,304 (82%); 14 of the 20 pages have 80% or more of their found words placed (McCATMuS; the
English revcity model 1,285, 81%). With the truth text itself, 1,339 (85%), 16 of 20. Proportional placement on the
same lines: 1,177 (74%), 12 of 20. The text page places nothing; Vision's own layer finds 922 of 1,405 distinct
words on these pages (F-placement, HW-BUILD). So the hand route is a real layer, and the six pages under 80% are
why the text page stays as the per-page fallback.

These one-to-one figures are from the run before the span matcher (PLACE_HANDS_SPAN=1; checkpoint f06184f5); the
tables below are the default PLACE_HANDS_SPAN=8 run. Letting a reading line cover several detected lines lifts
LightOnOCR-3 4B, which reflows each handwritten paragraph into one line (placed 295 → 601 of 1,584, blla with
McCATMuS), but costs the readers that keep their lines (Gemini on the same arm 1,304 → 1,145; the truth 1,339 →
1,146), so neither setting is right for every reader: W46.place-hands-fu picks per reading. Even at its best
LightOnOCR-3 places 38%: a reflowing reader is not a hand-placement route.

**Detectors.** All four find the hand baselines far better than Vision (owner-hand F 0.733): Orli 0.865, PP-OCRv6
0.865, blla 0.858, Surya 0.804; on Bentham Orli leads (0.901). Orli finds fewer lines on the owner's pages (453 of
553; 78% of truth words inside one, against blla's 90%), and placement follows coverage: blla's lines place best.
Orli base runs on the Mac's GPU in bf16, about 6-8 s a page once loaded (it reloads its 594 MB weights on every
`orli.pred.segment` call, and a run that did so grew to 12 GB and swapped this 18 GB Mac), so it is an R2 tool, not
a cluster one: no Sherlock job was needed for this item. PP-OCRv6 det at the pinned settings (max side 4000)
peaked at 32 GB on CPU for one Bentham page and paddlex has no MPS device, so its figures are the FarmShare run's
saved polygons, read on 2400-px copies and scaled up.

**Two defects found in the tools, both worked around here.** kraken 7.1.1's `ForcedAlignmentTaskModel` takes
`log_softmax` of the recogniser's output, which is already a probability per frame, so every frame is near uniform
and the aligned text packs at the line's start (p049: cuts end at 264 px of a 1,307 px line); place_hands aligns
on the log of the probabilities with kraken's own trellis. And `place_functional`'s oracle writer stretched each
word to its box, which on tall handwritten boxes reads back from PDFKit as spaced letters: the truth's own boxes
lost Find on p086 (105 of 152); `--fit` sizes the font instead (152 of 152). Whether the Processor's own writer has a
like loss on hands belongs to W46.place-print.
