# W46.fix-place-truth — the placement truth set and its scorers

The set of F-placement §6.2 and 10-gap-audit §4 fix 5. Pages, boxes and text are kept privately in
`~/Library/Application Support/ArchiveSuiteRehearsal/place-truth/` (one JSON per page, `xml/` PAGE-XML 2019,
`overlay/` audit renders, `audits/round1.json` the first round's verdicts). Counts and verdicts only are committed,
in `place-truth.json`. No money was spent: drawing and auditing ran on the coding session's plan.

## What the set holds

| group | pages | words | words boxed | lines (with baseline) | audit: ok / fix / redraw / none |
|---|---:|---:|---:|---:|---|
| owner-typed | 40 | 14,243 | 14,043 (2,978 drawn) | 1,987 | 26 / 13 / 0 / 1 |
| owner-hand | 21 | 3,170 | 2,925 (2,307 drawn) | 564 | 4 / 9 / 5 / 3 |
| L2-bentham | 20 | 4,314 | 616 (published word boxes) | 517 | 14 / 6 / 0 / 0 |
| N6 | 40 | 5,072 | none (line-level set) | 850 | 28 / 12 / 0 / 0 |

The owner-typed 40 are drawn by a fixed seed from the 96 in its mix (26 typewritten, 14 printed); owner-hand is every
handwritten or mixed truth page (19 + 2; 18 of them are in the 96). The 20 L1/L2 public pages are L2's Bentham pages,
the only English-hand pages in the bench corpus with published geometry; L1 (By the People) has none.

**One box convention: tight round the word's ink**, ascenders, descenders and flourishes included. Vision's and
Tesseract's drafted boxes are trimmed to their ink (`tighten`); drawn lines are split at their ink gaps along the
drawn baseline (`gap_split`) or boxed by hand. Each word records where its box came from (`vision`, `vision-sub`,
`vision-moved`, `split`, `tesseract`, `tesseract-sub`, `drawn`, `page-xml`; `missing`, `illegible`, `line-only`
are unscored).

How the owner pages were made: Vision's words aligned to the truth text; a third pass over Tesseract 5's words
(290 more typed words); then 30 pages redrawn by Claude Opus 5.5 subagents on a permille grid (`grid`, `zoom`,
`bands`, `lines`): the 24 with the most unboxed words, and 6 of the 16 the first audit sent back. Hand pages
mostly needed every word placed by hand: ink gaps do not separate cursive words.

## The audit

Independent: Claude Sonnet 5.5 subagents judged every page's overlay (a different model from the drawers), verdict
and note stored on the page (`audit`). Two rounds on the public pages, one or two on the owner pages.

- **N6**, round 1: 19 ok. Nearly all faults were line boxes covering part of a line, and the cause was the
  published ALTO: a TextLine's HPOS/WIDTH often hold a fragment while its BASELINE spans the line (dudhadasa1900/07
  line 4: box x 1463-1549, baseline 243-1476). Boxes are now widened to their baseline. Round 2: 28 ok; the 12
  fixes are the published baselines' kinks and a few collapsed published boxes, which this set keeps as published.
- **Bentham**, round 1: 0 ok. Derived straight baselines ran through the letters and the ink-gap word split of
  cursive was 10-40% wrong. Baselines are now fitted to the ink (`ink_baseline`); words outside the 3 pages with
  published word boxes are line-level only. Round 2: 14 ok.
- **Owner-typed**: 26 ok. The 13 fixes are mostly baselines joined across a gutter or slanting through a table
  (Vision's lines), and on the drawn newspaper pages p080 and p081 loose boxes in broken type.
- **Owner-hand**: 4 ok. On looped cursive a tight ink box overlaps its neighbours by design, which the auditor
  often counted against a page: p007, which it called redraw, has every box on its word (checked by the
  coordinating session), with large boxes where a loop is large. The hand set's word boxes are usable with
  F1@centre and not yet with IoU.

Not done, filed as `W46.fix-place-truth-fu`: the 13 typed and 14 hand pages marked fix or redraw, and the
unaudited p040, p045, p066 and p094 (their drawing was stopped to keep the session inside its budget). Until then,
`place_score.py --verdict ok` scores only the pages the audit passed.

## The scorers

- `place_functional.swift` — Find-in-place on a PDF (PDFKit `findString`, the hit's bounds against the truth box),
  the text layer read back as word and line boxes, and an oracle writer for its self-test. Oracle on a typed page:
  Find 1.0, placed 1.0; shifted a fifth of the page: placed 0.
- `place_score.py` — word F1 at IoU 0.5 and 0.7 and at centre (each box holds the other's centre), with mCER at
  0.5; READ-BAD-style baseline R, P, F (a simplified reimplementation, not interchangeable with the Transkribus
  tool's figures); line-level alignment accuracy. A reader's word on ink the truth calls illegible is left out.
  The truth scored against itself: 1.0 on every figure in every group, except owner-hand word F1 0.9998 (one pair
  of drawn words share a box).
- **Box convention dominates IoU.** Vision's own padded word boxes against this truth (owner-typed, all 40):
  F1 0.627 at IoU 0.5, 0.192 at 0.7, 0.947 at centre; baselines F 0.909; alignment 0.880. On the 26 audited-ok
  pages: 0.630, 0.176, 0.980. So a padded reader or a PDF's font-height rectangles lose IoU for their convention,
  not their placement (the PDFKit oracle read-back, 0.85 at 0.5 and 0.12 at 0.7 on the draft truth, said the same).
  W46.place-print compares writers on F1@centre, the functional score and baselines; IoU figures are reported
  beside them, not ranked on.
