## Findings

**Yes, a handwritten page can leave the text page, given a reading that keeps the page's line breaks, and with a
per-page gate.** The best route on the owner's 20 audited hand pages: kraken `blla` lines (CPU, about 6 s a page)
with the reading force-aligned by a kraken CTC recogniser, one reading line to one detected line. With Gemini 3.8
Flash's saved reading, Find finds 1,511 of the 1,584 truth words of four or more letters (95%) and the highlight
lands on the word for 1,305 (82%); 15 of the 20 pages have 80% or more of their found words placed (McCATMuS; the
English revcity model 1,285, 81%). With the truth text itself, 1,340 (85%), 16 of 20 (these one-to-one figures are the `s1` arm of the W46.place-hands-fu run; the per-page pick below adds a little to both). Proportional placement on the
same lines: 1,177 (74%), 12 of 20. The text page places nothing; Vision's own layer finds 922 of 1,405 distinct
words on these pages (F-placement, HW-BUILD). So the hand route is a real layer, and the pages under 80% are
why the text page stays as the per-page fallback.

**The matcher, per page (W46.place-hands-fu).** One-to-one (`s1`) suits readers that keep the page's lines; letting
a reading line cover up to 8 detected lines (`s8`) suits LightOnOCR-3 4B, which reflows each handwritten paragraph
into one line (blla with McCATMuS: LightOnOCR-3 placed 295 → 601 of 1,584, Gemini 1,305 → 1,145, the truth 1,340 →
1,146). The placer now runs both on every page and keeps the one whose alignment is surer: the higher mean CTC
confidence over the reading's characters, an unaligned character counting 0 (`conf`). On blla with McCATMuS that pick
beats both fixed settings for every reading: the truth 1,354 (85%, 18 of 20 pages at 80%), Gemini 1,312 (83%, 17),
LightOnOCR-3 687 (43%, 6). It is not free: Gemini's Find hits fall from 1,511 to 1,456, because a reading line the span match leaves unmatched drops out of the layer, while the hits off the word fall from 206 to 144. It chose `s8` on 12 of Gemini's 20 pages and 18 of LightOnOCR-3's: a span lets a reading
line that blla split in two still align, so it is not only for reflowing readers. Two other picks, the matched runs'
character error (`cer`: Gemini 1,319, LightOnOCR-3 687) and the reading's line count against the detected lines
(`lines`, span below 70%: 1,300 and 687), land within a few words, and every detector and both recognisers rank the
same way (the matcher table). One loss: on Bentham, LightOnOCR-3's line alignment is best one-to-one (0.884 against
the `conf` pick's 0.828), so the pick is tuned on the owner's pages and Bentham is a caution, not a confirmation.

**The gate: CTC confidence of at least 0.67 keeps a page's placed layer; the rest go to the text page.** Three
per-page features were swept, each threshold set as the loosest at which at most 10% of the kept pages' Find hits
highlight off the word, fitted on all three readings' pages together so that one gate serves any reader, and checked
leaving each page out (the threshold fitted on the other 19, applied to it). The alignment's own confidence is the
one that works: at 0.666, left out page by page, Gemini keeps 17 of 20 pages with 1,201 of 1,584 words placed on the
word (76%) and 64 Find hits off the word on the kept pages (5% of 1,265 found); the truth 17 pages, 1,218, 52 off.
The pages it sends to the text page are p094 (confidence 0.03, 3 found, 0 placed), p009 (0.42, 42 of 59) and p096
(0.56, 69 of 129), the three worst. The recogniser's own character error against the reading cannot be the gate:
McCATMuS reads these hands at 40-60% CER whatever the reading, so the 10% bar keeps only 4-5 pages. The matched runs'
character error is a weaker second (Gemini 16 pages, 1,075). **The gate does not rescue a reflowing reader:**
LightOnOCR-3 keeps 13 pages with 632 placed and 221 off the word (26% of found), so the hand route the Processor
ships is blla + McCATMuS forced alignment of a line-keeping reading (Gemini 3.8 Flash), `conf` pick, the 0.67 gate;
a reading from a reflowing reader stays on the text page. Twenty pages fit the threshold, so it is a starting value,
to be refit when more hand truth is drawn.

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
