# Dating: the relation and image-extraction truth sets (W46.fix-date-truth-score)

Written by `scripts/segbench/date_truth_sets.py` from the owner's answers to the dating cases sheet (W46.fix-date-truth; answered 2026-10-21, 54 cases, 0 unanswered). The records themselves, with the owner's 38 notes verbatim, stay private in the bench cache (`date-tagging/cases/truth-sets.json`); this page has no note text. No model call, $0.

## Where the owner's year came from

| structural class | basis | documents |
|---|---|---|
| A | own page | 14 |
| A | previous, not the cover | 7 |
| A | unsure | 5 |
| A | inferred from neighbours | 5 |
| A | cover | 2 |
| D | own page | 15 |
| D | unsure | 4 |
| D | cover | 1 |
| D | previous, not the cover | 1 |

The strict class was built on the guess that a previous document printing the same year was the cover the document came with. The owner's answers mostly refute it: of the 33 strict documents, 2 were sent with the previous document and 14 carry their own date on their pages, which the OCR text missed or misread. The others take the year from the previous document without it being the cover (a reply, a run of papers, the year guessed from the neighbours and tagged `Date Uncertain`) or the owner cannot say. So most of what the enclosure marker would propagate is better found on the page itself, and the image pass (W46.date-image) matters more than the relation classifier (W46.date-enclosure).

## The relation truth set

15 documents with an answer about the previous document: sent with it (the cover) 3, not sent with it 12. Refinements from the notes: other 6, inferred 4, bound issue 2, cover 2, reply 1. Two cases (a05, d10) are pages of one bound magazine issue, where the issue's cover or contents page is the dated member of a sequence rather than an enclosing letter; a scorer should treat a bound issue as its own relation, not as a cover. The image-sourced and unsure answers say nothing about the previous document and are left out (`sent_with` null).

## The image-extraction truth set

30 documents with a date on their own pages that is not in the OCR text sent: printed or typed 22, handwritten 4, stamped 2, not said 2. 28 legible; the owner read a year from the note on 26, and it matches the owner's tag on 22.

| case | class | kind | where | legible | page year = tag |
|---|---|---|---|---|---|
| a01 | A | stamped | below the byline | yes | – |
| a02 | A | handwritten | upper right | yes | yes |
| a04 | A | printed or typed | – | yes | yes |
| a06 | A | stamped | – | yes | yes |
| a07 | A | handwritten | top | yes | yes |
| a08 | A | printed or typed | upper right | yes | no (1985 vs 1984) |
| a09 | A | printed or typed | upper left | yes | yes |
| a12 | A | handwritten | upper right | yes | yes |
| a14 | A | printed or typed | upper right | yes | yes |
| a16 | A | printed or typed | first line | yes | yes |
| a17 | A | printed or typed | second line | yes | yes |
| a18 | A | printed or typed | lower left | yes | yes |
| a19 | A | printed or typed | page 2 | no | – |
| a30 | A | printed or typed | upper right | no | – |
| a32 | A | handwritten | upper right | yes | – |
| d01 | D | printed or typed | upper right | yes | yes |
| d02 | D | printed or typed | upper right | yes | yes |
| d03 | D | printed or typed | lower right, last line | yes | yes |
| d04 | D | printed or typed | upper right | yes | yes |
| d05 | D | printed or typed | upper right | yes | yes |
| d06 | D | printed or typed | upper right | yes | no (1967 vs 1965) |
| d07 | D | printed or typed | – | yes | yes |
| d08 | D | printed or typed | upper left | yes | yes |
| d09 | D | printed or typed | upper right | yes | yes |
| d12 | D | not said | lower left | yes | yes |
| d13 | D | printed or typed | top | yes | yes |
| d14 | D | not said | – | yes | yes |
| d16 | D | printed or typed | lower right | yes | yes |
| d18 | D | printed or typed | upper right | yes | no (1936 vs 1935) |
| d20 | D | printed or typed | upper right | yes | no (1936 vs 1935) |

## Where a note contradicts the answer or the tag

Carried into the records as `conflicts`; nothing is dropped and no tag is changed (the corpus is read-only). A scorer of page-date extraction scores against the page's date; a scorer of the owner's year scores against the tag and reports these separately.

- a07: kind 'handwritten' from the note; left blank on the sheet.
- a08: page reads 1985, owner tag 1984.
- a19: the answer names the previous document, the note an illegible date on page 2.
- a32: the page's own date has no year; a later reader pencilled one in.
- d06: page reads 1967, owner tag 1965; date blurry in the processed PDF, clear in the JPEG original.
- d18: page reads 1936, owner tag 1935 (Date Uncertain).
- d20: page reads 1936, owner tag 1935 (Date Uncertain).
