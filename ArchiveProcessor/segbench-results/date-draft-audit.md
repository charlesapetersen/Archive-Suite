# Dating: the second reader on the 95 the first did not support (W46.date-draft-audit)

Written by `scripts/segbench/date_draft.py audit-score --model qwen3-vl-8b-mlx4`. Qwen3-VL 8B, 4-bit MLX (this Mac, temperature 0, every page at 1100 px, not only the first) asked the same blind question page by page, with a box around any date it reads; the owner's year is never in the prompt. $0, no plan route. 310 pages read, median 5.7 s a page. The first reader was Qwen3.5 4B, 4-bit MLX on the first page only (`date-draft.md`).

A year counts only when it is in the date as read. The second reader settles a row when it reads the owner's year on any page. A year either reader read that differs from the tag, not so settled, is a dispute and goes to the owner's check sheet. Neither reader finding a year on any page leaves the owner's tag standing but unsupported by the page: the year came from somewhere else, as 24 of the owner's 54 did.

| first reader (page 1) | supported by the second reader | disputed: to the owner | no year on the page: tag unsupported | not audited |
|---|---|---|---|---|
| page year differs | 9 | 24 | 0 | 0 |
| date without a year | 3 | 2 | 7 | 0 |
| no date found | 12 | 3 | 35 | 0 |
| all | 24 | 29 | 42 | 0 |

24 of 95 are now supported (16 of them on a later page than the first), bringing the stratified 200 to 129 supported. 29 are disputed and on the owner's sheet; 42 have no year on the page.

Where both readers read a year that differs from the tag, they read the same year on 16 and different years on 4. 33 of the disputed readings carry the second reader's box on the sheet; the rest are placed by the reader's own words for where the date is.

Of the 29 disputes, 12 have the second reader one year from the tag (the page's date is probably right and the tag took a neighbouring year), and 4 carry the tag 1900, sometimes a placeholder and sometimes a real year (owner, 2026-10-22); both kinds are on the sheet, since only the owner can say what the tag should hold.

The sheet (private, in the bench cache's `date-tagging/pool/audit-sheet/index.html`) shows each disputed page with the boxes and asks what year the date says, offering every year read and the owner's tag in numeric order, unlabelled, so it does not say which is the current truth.

## The owner's answers (W46.date-audit-score)

The owner answered all 29 on 2026-10-22. 28 answers carry a note and 5 are a note with no year picked, so each was read by hand and classed with its reason in `OWNER` (`date_draft.py`); the score stops on an answer that changes. A note overrides the pick: 6 picks of a year carry a note that the year is only mentioned, or only an earliest year. The notes are kept verbatim only in the private `pool/audit-truth.jsonl`, beside the tag and the page's year.

| the answer | supported by the page | the page's date differs from the tag | no dating year on the page |
|---|---|---|---|
| dated | 4 | 11 | 0 |
| context | 1 | 0 | 0 |
| inferred | 1 | 0 | 0 |
| illegible | 0 | 2 | 0 |
| bound | 0 | 0 | 1 |
| mention | 0 | 0 | 9 |
| all | 6 | 13 | 10 |

`dated`: the page's dating year; `context`: the same, though the page alone reads otherwise (2-3-79 looks like 19); `inferred`: a year the owner infers from the text (a 1957-58 annual report, published 1958); `illegible`: a date whose year is one of a few (1919 or 1929; 197x); `bound`: only an earliest year (a review of a 1960 book); `mention`: a year the page mentions that does not date it.

### The 13 tags the answers show wrong

The page's own date gives another year. The tag may still have come from somewhere else, but it is not the page's year; which the tag should hold is the owner's call, and nothing here changes a tag.

| document | tag | the page's year | the answer |
|---|---|---|---|
| 15c3057d93639e52 | 1973 | 1927 | no pick; the note reads 5.11/27 as November 1927 |
| 172f76141bf8de82 | 1983 | 1981 | the date as read, February 17, 1981 |
| 2a1a3caec99509a6 | 1900 | 1998 | no pick; the 1997 read is a mention, the dating year is at the bottom, January 1998 |
| 486fe66f6af2dcbc | 1970 | 1982 | the date as read, 01/05/82 |
| 4a8775c6635a29b0 | 1942 | 1919 or 1929 | obscured: 1919 or 1929 |
| 60df3c077d20a2d4 | 1915 | 1916 | the date as read, October 6, 1916 |
| 692927d512142b83 | 1900 | 1981 | picked 1981, no note (the second reader's copyright line) |
| 84c3c2cd8bc297fa | 1982 | 1981 | the date as read, June 29, 1981 |
| 85c74ee4bbd28c1b | 1982 | 1983 | a copyright line, which the owner counts as a dating year |
| 904df6db7437826e | 1970 | 1969 | the date as read, September 3, 1969 |
| ab20e83f94bff0dd | 1972 | 1978 | the date as read, August 1978 |
| aeead1cf06ba4269 | 1900 | 197x | September 197x, the last digit not legible |
| e4be28828f7fd155 | 1900 | 1976 | the boxed date is the manuscript's receipt; the dating year is the citation at the top, June 1976 |

4 of them are one year from the tag. Of the 4 tagged 1900, each settled from its answer: 2a1a3cae the page's date differs from the tag (1998); e4be2882 the page's date differs from the tag (1976); aeead1cf the page's date differs from the tag (197x); 692927d5 the page's date differs from the tag (1981).

On the 17 the owner dated, a reader had read the page's year on 9. The 6 the owner found supported are tags the readers disputed by misreading or missing the date (1948 read as 1968, 1973 as 1978, a margin date not seen). 10 of the 29 disputes were a year the page mentions rather than a date of it, or only bounds: the blind question does not tell the two apart, which is the readers' main fault here.

### The stratified 200, final

| | documents |
|---|---|
| supported by the page: the first reader | 105 |
| supported by the page: the second reader | 24 |
| supported by the page: the owner's answer | 6 |
| the page's date differs from the tag | 13 |
| no dating year on the page (the tag stands, unsupported) | 52 |
| all | 200 |

135 of the 200 tags are supported by a date on the document's own pages, 13 are contradicted by it, and 52 have no dating year on the page (42 where neither reader found a year, 10 where the year found was only a mention or a bound).
