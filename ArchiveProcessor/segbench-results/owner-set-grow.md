# W46.owner-set-grow: S1, about 200 more random owner pages beside the 96

Owner review of the pipeline doc, 2026-11-17: the 96 resolve about 3 NES on a typical pair of routes, and 730-2,303 pages are needed for 1 point (`execution-plans/benchmark-corpus/00-plan.md` §4). S1 adds about 200 pages; the 96 (S0) stay frozen. Built by `scripts/segbench/owner_set_grow.py`; images, drafts and the sheet stay in the bench cache, since the pages are the owner's.

## The draw

- Base: W46.ocr-vision-unfiltered's 200 hashed-draw pages (one page per document, uniform over the 20,986 documents of the 96's pool that hold none of the 96's pages), of which the owner answered "a page of text" for 181 on 11 Nov (19 "a few words", 0 "no text").
- Top-up: the next 30 documents of the same hashed order (the rebuilt order holds the first draw's 200 as its first 200); 1 document passed over as unreadable from disk. The owner answers the has-text question for these on the sheet.
- 211 pages in all. Images: 194 original, 10 pdf image (no original), 7 pdf image (no original; pair below MIN_CORR).
- Upright: 4 pages turned for the sheet. ocr_orient.swift's scores gave 2 clear wins and 11 pages where another turn scored highest without one. All 13 were judged by eye on four-turn thumbnails, 7 recorded in orient-eye.tsv (two clear wins were wrong: upright handwriting that Vision read better upside down). Up and upside down score alike on most pages, so the rest stay as stored, and the sheet has a turn button.

## Measurement card

- **Truth:** not made yet: the drafts and the owner's sheet are pending.
- **Selection:** a hashed draw, one page per document, uniform over documents; the text filter is the owner's own answer, not a route's reading; English by the drafters' language line, the owner able to overrule.
- **Comparison:** S1 is scored with the same scorer and settings as the 96 (`ocr_panel_score`), and reported beside it, never pooled into the 96's figures.
- **Noise:** with about 200 pages a typical pair resolves about 2 NES (n = (2.8 σd / Δ)², σd 9.7); pooled with the 96, about 1.6. Not yet 1 point.
- **Scope:** the owner's English collections only; what the scored drafters gain on agreed words is measured by the controls, not removed.
