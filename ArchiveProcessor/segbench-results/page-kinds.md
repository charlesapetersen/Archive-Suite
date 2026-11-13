# Page kinds: the app's one list, measured per kind (W42.int-s3)

The Processor's page-kind call (`OCR/PageKinds.swift`, `PageKind.detect`) on two truth sets, run through the app itself (`OCRPageKindTestDriver` §11) by `scripts/segbench/page_kinds.py`. The call puts three signals together: a Finder tag (Handwritten, Clippings, Statistics) corrects everything; then a whole newspaper page told by the shape of Vision's lines (VisionOCRKit's ocr-newspaper-detect rule); then the bundled classifier. Photographed is a second axis, from the engine's page-kinds-three rule. Clippings, registers and mixed pages are not detected: they come from a tag or the collection interview.

## Owner's labelled pages

144 pages: kind_classifier.py's 144 labelled originals. A form is a page labelled a form or table, whatever its hand; mixed pages count right when they reach the handwritten pick.

| Kind | Pages | Right, with the tags | Right, no tags | Its pick, with the tags | Its pick, no tags | Called |
|---|---:|---:|---:|---:|---:|---|
| handwritten | 34 | 34 (90-100%) | 34 | 34 | 34 | handwritten 34 |
| typewritten | 63 | 60 (87-98%) | 63 | 60 | 63 | typewritten 60, clippings 2, forms 1 |
| printed | 31 | 18 (41-74%) | 31 | 28 | 31 | printed 18, clippings 10, forms 3 |
| forms | 14 | 13 (69-99%) | 14 | 13 | 14 | forms 13, clippings 1 |
| mixed | 2 | 2 (34-100%) | 2 | 2 | 2 | handwritten 2 |

All: 127 of 144 right with the tags (82-92%, Wilson), 144 with none; 137 reach their kind's pick with the tags, 144 with none. Pages a Finder tag decided: 45 (30 by the truth set's record of the original's tags, the rest the held-out hand pages' own). Where a tag changed the call (label -> call): printed -> clippings 10, printed -> forms 3, typewritten -> clippings 2, typewritten -> forms 1, forms -> clippings 1. Pages called a newspaper: 0 (the engine's reading called 1, on a page the classifier did not call printed, so it was not read for it). Called photographed: 117. Unread or no kind: 0.

## Vision OCR's newspaper truth pages

147 of the 152 pages of `PAGE-KIND-2026-10-12.tsv` found on this Mac (5 not found: s55, nb13, nb15, nb16, nb19). A whole newspaper page should be called a newspaper; a clipping (one article cut to a page) and every other page should not.

| Truth | Pages | Right | Called |
|---|---:|---:|---|
| newspapers | 32 | 30 (80-98%) | newspapers 30, printed 2 |
| clippings | 11 | 11 (74-100%) | printed 11 |
| other | 104 | 104 (96-100%) | printed 101, typewritten 3 |

By set: sample 66 of 66; outside 79 of 81. Wrong on the newspaper question: nb14, xn01.

## Time

The engine's newspaper reading (banded Vision, split at the gutters) took a median 1.65 s a page on the owner pages and 1.26 s on the newspaper set (most 13.8 s), on an M3 Pro 18 GB under another session's load, beside the classifier's 0.6 s (kind-atrium.md §7). The app reads only pages the classifier calls printed for it. The app's own single Vision pass, tried first, called 13 of the 32 whole pages (it found 128 lines on a page the engine reads 615 on), so it was not kept.

## Measurement card

- **Truth.** Owner pages: kind_classifier.py's labels (KND-1: partly a session's and not blind; the bundled weights were fitted on these pages, so these figures are in-sample; the held-out figure is kind-atrium.md §1's 137 of 141). Tags: the truth set's record of each original's Finder tags (ocr-truth pages.tsv); the held-out hand pages' own tags, read where they are; the drawn pages none (they were drawn by a tag). Newspaper pages: Vision OCR's labels (the sample's route or the Zotero item type, one relabelled by looking; whole page or clipping judged from size and lines, three viewed).
- **Selection.** Owner pages: kind_classifier.py's draws (truth set, held-out hand folder, Statistics-tagged forms draw, low-resolution draw); none chosen by the call measured here. Newspaper pages: Vision OCR's sample plus the newspaper and print pages it gathered for the rule, which the rule's edges were set on, so the newspaper figure is the rule's fit through the app's Vision pass, not a held-out test.
- **Comparison.** None between routes: one detector, as the app runs it. The engine measured the rule on its own render and gutter-fitted lines; the app reads its classifier's Vision pass on the run's 2x render.
- **Noise.** Vision is deterministic on one Mac and OS; intervals are Wilson 95% on the page counts.
- **Scope.** No clipping, register or mixed detector is measured (none exists; they are asked). The photographed axis is reported, not scored (no truth for it here). Tags were not checked against the hand labels beyond these pages.

Pinned by `scripts/test-ocr-page-kind.sh` (when the caches are on the Mac): a fresh run may not get fewer pages right per kind than this file's json.
