# Dating: the model draft of the stratified 200, calibrated on the owner's 54 (W46.fix-date-truth-score)

Written by `scripts/segbench/date_draft.py score --model qwen3.5-4b-mlx4`. Qwen3.5 4B, 4-bit MLX (this Mac, temperature 0, first page at 1100 px) asked blind whether a date is on the page; the owner's year is never in the prompt. $0, no plan route. 254 pages read, median 3.7 s a page.

## Calibration on the owner's 54

Of the 26 owner cases with a legible page date and a year, the draft found a date on 25 and read the owner's page year on 20. On the 24 cases whose year the owner took from somewhere other than the page, the draft claimed a page date on 5, 0 of them with the owner's year (a date the owner may have had but did not name, or a misreading). 

Where the draft's year differs from the owner's page year: a06 1971 for 1975 (read "WED. SEP. 1 1971"); d06 1984 for 1967 (read "TUESDAY, MARCH 7"); d12 1957 for 1967 (read "1957"); d13 no year for 1928; d18 1956 for 1936 (read "July 12, 1956"); d20 1976 for 1936 (read "May 21, 1976").

## The 200, drafted and audited

`own page (supported)`: the blind reading of the page gives the owner's year, so two independent sources agree; accepted as truth with the owner's tag. A year the model gave that is not in the date it read counts as `date without a year`. Every other row goes to the second-reader audit list (`audit: true` in the private `pool/draft-truth.jsonl`).

| class | own page (supported) | page year differs | date without a year | no date found | unreadable reply | not drafted |
|---|---|---|---|---|---|---|
| A | 20 | 6 | 1 | 13 | 0 | 0 |
| A' | 24 | 8 | 3 | 5 | 0 | 0 |
| B | 21 | 6 | 3 | 10 | 0 | 0 |
| C | 20 | 3 | 3 | 14 | 0 | 0 |
| D | 20 | 10 | 2 | 8 | 0 | 0 |
| all | 105 | 33 | 12 | 50 | 0 | 0 |

105 of 200 are supported; 95 await the audit. Only the first page is read, so a date on a later page (as on the owner's a19) counts as not found; the calibration's recall is the figure to read this table through.
