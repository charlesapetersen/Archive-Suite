# W46.ocr-vision-unfiltered — Apple Vision on owner pages drawn without the 20-word filter

Written by `ArchiveProcessor/scripts/segbench/ocr_vision_unfiltered.py`. Vision is `segbench-ocr` (ocr.swift: .accurate, language correction on), the panel's tool, read on macOS 27.2. Counts only: the pages and the sheet are in the bench cache (`ocr-vision-unfiltered/`), outside git.

**Status: the sheet waits for the owner.** The figures below are Vision's word counts alone; without the owner's answers they do not say how many of the short readings are pages with no text (a blank, a photograph) and how many are pages Vision failed on.

## The draw

200 pages, one per document, ordered by a salted hash over the 20,986 documents of the 96's pool that hold none of the 96's pages (no caps, strata or word filter); 0 passed over as unreadable from disk. Apart from them, the 19 pages the 96's draw replaced, read again: they were chosen by Vision's reading, so they show what the filter took out, not a rate.

| | drawn | replaced at the 96's draw |
|---|---|---|
| pages | 200 | 19 |
| Vision reads nothing | 0 of 200 (0.0%, 95% 0.0-1.9%) | 1 of 19 (5.3%, 95% 0.9-24.6%) |
| Vision reads under 20 words | 10 of 200 (5.0%, 95% 2.7-9.0%) | 17 of 19 (89.5%, 95% 68.6-97.1%) |
| tagged Handwritten: under 20 words | 0 of 1 (0.0%, 95% 0.0-79.3%) | 2 of 4 (50.0%, 95% 15.0-85.0%) |

## Measurement card

- **Truth:** none yet: the owner's yes or no per page, on the sheet this item built (about 18 minutes); Vision's counts here are not truth.
- **Selection:** a salted hash over documents, fixed before the draw ran; never by a route's answer or the ABBYY text. The replaced pages were selected by Vision (26.6) and are kept apart for that reason.
- **Comparison:** one route, Vision as the panel reads it, on the prepared image as stored (turned like the PDF page, as the 96's were); the app's rotation step is not applied first, so a page stored sideways counts against Vision here (6 pages are stored turned, by a clear text score or an eye check).
- **Noise:** Vision is deterministic on one OS build (vision-27-reread.md); the intervals are Wilson 95% on pages, one page per document.
- **Scope:** owner material in the collection folders only; a rate of pages, not of words read wrongly on pages Vision does read (the 96 measure that); the free default's card cites the drawn figure, never the replaced pages'.
