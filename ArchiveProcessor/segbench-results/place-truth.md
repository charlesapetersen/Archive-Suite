# W46.fix-place-truth — the placement truth set and its scorers (in progress)

The set of F-placement §6.2 and 10-gap-audit §4 fix 5. Pages, boxes and text are kept privately in
`~/Library/Application Support/ArchiveSuiteRehearsal/place-truth/` (one JSON per page, `xml/` PAGE-XML 2019,
`overlay/` audit renders). Counts and verdicts only are committed, in `place-truth.json`. No money was spent.

## What the set holds

| group | pages | words | words boxed | lines (with baseline) | where the geometry comes from |
|---|---:|---:|---:|---:|---|
| owner-typed | 40 | 14,243 | 12,958 | 1,743 | drafted from Apple Vision's word boxes, aligned to the truth text |
| owner-hand | 21 | 3,170 | 1,814 | 439 | the same; the hand drafts are poor (below) |
| L2-bentham | 20 | 4,314 | 4,314 (616 from PAGE word boxes, 3,698 shared from the line) | 517 | tranScriptorium PAGE GT: line polygons on all 20, word polygons on 3; baselines derived |
| N6 | 40 | 5,072 | none (line-level set) | 799 | ALTO v4 / PAGE: line boxes and baselines as published |

The owner-typed 40 are drawn by a fixed seed from the 96 in its mix (26 typewritten, 14 printed); owner-hand is every
handwritten or mixed truth page (19 + 2; 18 of them are in the 96). The 20 L1/L2 public pages are L2's Bentham pages,
the only English-hand pages in the bench corpus with published geometry; L1 (By the People) has none.

Each word records where its box came from (`vision`, `vision-sub`, `vision-moved`, `split`, `line-share`,
`page-xml`, `corrected`, or `missing` with no box). Transcripts are line-broken where the drafted lines break.

## The scorers

- `place_functional.swift` — Find-in-place on a PDF (PDFKit `findString`, the hit's bounds against the truth box),
  the text layer read back as word and line boxes, and an oracle writer for its self-test. Oracle on a typed page:
  Find 1.0, placed 1.0; shifted a fifth of the page: placed 0.
- `place_score.py` — word F1 at IoU 0.5 and 0.7 with mCER at 0.5; READ-BAD-style baseline R, P, F (a simplified
  reimplementation, not interchangeable with the Transkribus tool's figures); line-level alignment accuracy. The
  truth scored against itself is 1.0 on every figure in every group.
- A measurement to carry into W46.place-print: read back through PDFKit, the oracle PDF, whose text sits exactly on
  the truth boxes, scores word F1 0.85 at IoU 0.5 and 0.12 at 0.7, because a PDFKit selection's bounds are the
  font's line height, not the word's ink box. F1@0.7 on a PDF's own word rectangles is mostly a height-convention
  figure; compare writers on F1@0.5, the functional score and baselines.

## Audit so far (provisional)

Seven pages checked on overlays by the drafting session (Claude Opus 5.5), not yet by an independent model:
p002, p004 and p088 ok; p024 and p057 need their tables drawn (Vision did not read the figures); p007 (hand) needs
redrawing (Vision matched words on a neighbouring typed page in frame); Bentham 002_112_001 needs its two
line-shared lines boxed. Nine typed pages have over 10% of words unboxed (p018, p024, p034, p057, p064, p066, p080,
p081, p100: tables and newspaper columns Vision failed on); the rest are under 8%.

Still to do: draw the missing words (typed 1,260, hand 1,282) and the line-shared Bentham words, and audit every
page with an independent model; then this note gets the audited figures.
