# The dating route's month and day, against the page (W46.date-full-date)

Written by `scripts/segbench/date_full_date.py score`. The route of W46.date-route-pipeline on the owner's documents, Gemini 3.7 Flash through the gateway, from its cached replies ($0, no new model call). An explicit year (from the text or the page image) now carries the month and day of the dated form it rests on: the trace reply's own quote when it cites the document and passes the evidence check, else the rule's dated form of that year; from the image pass, the quoted date the year rests on. Estimates and inherited years carry neither. A numeric date is read month-first when its first part can be a month.

## Findings

- **On the page's own date: the month right on 98.2% (108/110) (95% 94-100), wrong on 0, not written on 2; the day right on 96.7% (88/91) (95% 91-99), wrong on 1, not written on 2.** Of 115 documents with a page truth, 106 of 110 with a month on the page get the full date exactly. A month or day written where the page has none: 0 and 0.
- **Against the Finder tags alone (W46.date-month-score's question): the owner's month on 87.0% (87/100), another month on 1, none on 12** (100 explicit years that are the owner's year and carry his month tag). The route before this item wrote 87.0% (87/100), another month on 1. The old tagging call's figure, 75.0% of 120 (date-tagging.md), was on the ABBYY text and a different document set.
- **Before and after on the page truth:** the old rule's month right on 97.3% (107/110); 1 documents right only now, 0 only before. The old rule never wrote a day.
- **Where the month comes from** (explicit years): image 7, none 51, quote 124, rule 8.
- **Not yet settled: 28 disputed documents** (the route and the second reader differ, or the year came from the same image pass the second reader is) wait on the owner's blind sheet (36 documents with 8 controls); the figures above leave them out, so they lean towards documents where two readings agree.

## Truth by source

| source | documents |
|---|---|
| agreed | 94 |
| not explicit | 82 |
| year not the owner's | 41 |
| disputed | 28 |
| owner, earlier sheet | 18 |
| no month found | 6 |
| agreed, no month | 3 |

## Month and day on the page truth

| | right | wrong | not written | written, none on the page |
|---|---|---|---|---|
| month, this route | 108 | 0 | 2 | 0 |
| month, before this item | 107 | 1 | 2 | 0 |
| day, this route | 88 | 1 | 2 | 0 |

Wrong months or days:

- `o:952140959eef6e8e`: route [1978, 2, 4], truth [1978, 2, 9] (owner, earlier sheet)

## Measurement card

- **Truth:** the page's own full date. Strongest is the owner's own reading of the page on his 2026-10-21 date sheet (18 scored documents). Next, the route and a second reader agreeing: the Gemini 3.7 Flash image pass on the first two pages (the same gateway model as the route's trace call, but reading the page image, where the route reads Apple Vision's text and takes its date by rule from a quote that must be in that text), and not against the owner's Finder month tag. Agreement-made truth cannot catch an error both readings share, and it leans the score towards the easy documents: the disputed ones go to the owner, with controls drawn from the agreed ones to measure that truth's own error. Documents whose year came from the image pass are never agreed, since the second reader is then the route's own evidence. The owner's Finder tags carry no day. The sheet is blind (no reading shown; every date-like string Vision read is boxed); where no box holds the second reader's year, the card says a date may lie outside the boxes, which marks a document as harder without saying which reading is right.
- **Selection:** the owner's documents of W46.date-route-pipeline (stratified by date kind from his Finder tags, seed 41), those with a confirmed JPEG original; scored where the route gives an explicit year equal to the owner's year. Not chosen by any route or by the ABBYY text.
- **Comparison:** the same cached trace and image replies scored under the new rule and the rule before this item; Vision text on the JPEG originals for both. The public set has no full-date truth, so only the owner's documents are scored (no second OCR set).
- **Noise:** n is small (110 months, 91 days); intervals are Wilson 95%. The rule is deterministic on cached replies, so there is no rerun noise in the rule itself; a fresh trace call could quote a different date.
- **Scope:** not the tagging call's own month and day (the app keeps its day when it read the same year and month, and both when the route has no dated form; its cached replies here were made on the ABBYY text, so they are not scored), not estimates or inherited years (no month or day by design), and not day-first numeric dates below 13 (read month-first).
