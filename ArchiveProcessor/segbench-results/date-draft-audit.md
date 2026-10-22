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

Of the 29 disputes, 12 have the second reader one year from the tag (the page's date is probably right and the tag took a neighbouring year), and 4 carry the tag 1900, which looks like a placeholder rather than a year; both kinds are on the sheet, since only the owner can say what the tag should hold.

The sheet (private, in the bench cache's `date-tagging/pool/audit-sheet/index.html`) shows each disputed page with the boxes and asks what year the date says, offering every year read and the owner's tag in numeric order, unlabelled, so it does not say which is the current truth.
