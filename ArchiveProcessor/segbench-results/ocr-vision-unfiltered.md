# W46.ocr-vision-unfiltered — Apple Vision on owner pages drawn without the 20-word filter

Written by `ArchiveProcessor/scripts/segbench/ocr_vision_unfiltered.py`. Vision is `segbench-ocr` (ocr.swift: .accurate, language correction on), the panel's tool, read on macOS 27.2. Counts only: the pages and the sheet are in the bench cache (`ocr-vision-unfiltered/`), outside git.

## Verdict

On 181 drawn pages the owner marked as a page of text, Vision read fewer than 20 words on 1 of 181 (0.6%, 95% 0.1-3.1%): that is the free first reader's failure rate on owner material, one page per document. It read nothing on 0 of 200 (0.0%, 95% 0.0-1.9%) of the drawn pages with any text. On handwritten-tagged pages of text: 0 of 1 (0.0%, 95% 0.0-79.3%).

## The draw

200 pages, one per document, ordered by a salted hash over the 20,986 documents of the 96's pool that hold none of the 96's pages (no caps, strata or word filter); 0 passed over as unreadable from disk. Apart from them, the 19 pages the 96's draw replaced, read again: they were chosen by Vision's reading, so they show what the filter took out, not a rate.

| | drawn | replaced at the 96's draw |
|---|---|---|
| pages | 200 | 19 |
| Vision reads nothing | 0 of 200 (0.0%, 95% 0.0-1.9%) | 1 of 19 (5.3%, 95% 0.9-24.6%) |
| Vision reads under 20 words | 10 of 200 (5.0%, 95% 2.7-9.0%) | 16 of 19 (84.2%, 95% 62.4-94.5%) |
| tagged Handwritten: under 20 words | 0 of 1 (0.0%, 95% 0.0-79.3%) | 2 of 4 (50.0%, 95% 15.0-85.0%) |
| owner: no text / a few words / a page of text | 0 / 19 / 181 | 1 / 15 / 3 |
| Vision under 20 words on a page of text | 1 of 181 (0.6%, 95% 0.1-3.1%) | 0 of 3 (0.0%, 95% 0.0-56.2%) |
| Vision reads nothing on a page with text | 0 of 200 (0.0%, 95% 0.0-1.9%) | 0 of 18 (0.0%, 95% 0.0-17.6%) |

## The JPEG originals

The draw read 56 pages from the PDF's image, because ocr_truth.prepare finds an original only by the PDF's exact file name (W46.prepare-jpeg-pairs). corpus-pairs/pairs.tsv pairs 44 of them with a JPEG; each was made as an original is (EXIF applied, turned like the PDF's page 1) and kept at orient_like_pdf >= 0.65, which is also the check that it is the page the owner saw on the sheet. 40 were kept (5 by folder, 35 by number) and read by Vision in their place; the owner's answers carry over by page. 9 drawn and 3 replaced pages have no paired JPEG and stay PDF images.

Refused below 0.65, so read from the PDF's image (checked by eye):

- `replaced:28e1455b6dc8fa4c`: 0.439, a different photograph of the same cover; Vision 4 words on the PDF's image
- `drawn:2c68ee4a154e5148`: 0.399, a different page (pairs.tsv paired the wrong JPEG); Vision 202 words on the PDF's image
- `drawn:1ebcf4a91fe092e8`: 0.623, the same page, cropped differently; Vision 317 words on the PDF's image
- `drawn:e41b7dddbe95d4d3`: 0.528, the same page, cropped differently; Vision 399 words on the PDF's image

Pages the JPEG moves across the 20-word line or off zero: `replaced:cebc4714d8d8edc7` 1 -> 80.

Read again at the owner's turn (a note or the sheet's turn button), the as-stored count staying the one counted above: `replaced:cebc4714d8d8edc7` 80 as stored, 78 at 180°.

## Measurement card

- **Truth:** the owner's answer per page (1 no text, 2 a few words, 3 a page of text), on a sheet that shows neither Vision's count nor which pages were replaced; no model drafted it.
- **Selection:** a salted hash over documents, fixed before the draw ran; never by a route's answer or the ABBYY text. The replaced pages were selected by Vision (26.6) and are kept apart for that reason.
- **Comparison:** one route, Vision as the panel reads it, on the prepared image as stored (turned like the PDF page, as the 96's were); the app's rotation step is not applied first, so a page stored sideways counts against Vision here (6 pages are stored turned, by a clear text score or an eye check; 0 of the 5 drawn ones reads under 20 words). The JPEG original where one exists, by file name or a pairs.tsv pair (40 by the pair), else the PDF's image.
- **Noise:** Vision is deterministic on typed pages, but on 27.2 a handwritten page varies by up to 3.7 NES from run to run (vision-27-reread.md), and each page here was read once; the intervals are Wilson 95% on pages, one page per document.
- **Scope:** owner material in the collection folders only; a rate of pages, not of words read wrongly on pages Vision does read (the 96 measure that); the free default's card cites the drawn figure, never the replaced pages'.
