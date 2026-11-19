# The dating route's month and day, against the page (W46.date-full-date)

Written by `scripts/segbench/date_full_date.py score`. The route of W46.date-route-pipeline on the owner's documents, Gemini 3.7 Flash through the gateway, from its cached replies ($0, no new model call). An explicit year (from the text or the page image) now carries the month and day of the dated form it rests on: the trace reply's own quote when it cites the document and passes the evidence check, else the rule's dated form of that year; from the image pass, the quoted date the year rests on. Estimates and inherited years carry neither. A numeric date is read month-first when its first part can be a month.

## Findings

- **On the page's own date: the month right on 98.5% (131/133) (95% 95-100), wrong on 0 of 133 (95% upper bound 2.8%), not written on 2; the day right on 94.6% (105/111) (95% 89-98), wrong on 2, not written on 4.** Of 142 documents with a page truth, 126 of 132 with a month on the page get the full date exactly. A month or day written where the page has none: 1 and 0. These figures are a fit, not a held-out score: the OCR forms were written from this set's own misses (below); their held-out check is the public set's, where they write a wrong month on 6 of 574.
- **The two strata apart.** Owner-ruled (53 documents, his blind sheet and his earlier reading): the month right on 95.7% (45/47) (95% 86-99), 70.2% (33/47) before the OCR forms; the day 85.7% (36/42), wrong on 2. Agreed (89): the month right on 100.0% (86/86), the day 100.0% (69/69), but that truth is the second reader's full date, which equalled the route's on each of them when it was frozen (W46.p16-date-truth-strata), so a later route is scored against it: this route is right there by construction, and the agreed truth matched the owner on 8 of 8 sheet controls (95% 68-100), so it may be wrong on up to about 32% of these documents. The headline counts both.
- **Against the Finder tags alone (W46.date-month-score's question): the owner's month on 94.9% (94/99), another month on 1, none on 4** (99 explicit years that are the owner's year and carry his month tag). The route before this item wrote 86.9% (86/99), another month on 1. The old tagging call's figure, 75.0% of 120 (date-tagging.md), was on the ABBYY text and a different document set.
- **Before and after on the page truth:** the old rule's month right on 88.7% (118/133); 13 documents right only now, 0 only before. The old rule never wrote a day.
- **Where the month comes from** (explicit years): image 6, image month 4, image ocr form 1, none 36, ocr form 11, quote 123, rule 8.
- **The owner's sheet is folded** (35 of its 36 documents scored; W46.date-full-date-fold). Its controls: 8 of 8 agreed documents as the owner reads them (one on the month only: he reads the typed-over day as 27 or 29, the route wrote 29), so the agreed truth stands.

- **The OCR forms (W46.date-full-date-ocr-forms) take the month from 89.5% (119/133) to 98.5% (131/133) and the day from 86.5% (96/111) to 94.6% (105/111): right only with them, 12 months and 9 days; right only without them, 0 and 0; no new wrong month or day.** A fit: the forms were written from the misses on these very documents, so this says they recover what they were written for; the public set below is their held-out check. Where the strict forms give an explicit year no month, the route now reads that year's dated forms as Vision damages them: a spaced day (`APR 2 0 1977`, `DEC 2 1 1982`), a bullet for a full stop (`Aug• 4, 1903•`), a misread month within two letters of one name in a full date with the four-digit year (`NIRCH 13, 1965`), Cyrillic look-alikes (`ОстОВЕя 1, 1966`), spaces in a numeric date (`8 - 3-87`) and a two-digit year after a month word (`Dec. 70`, `Sept 69`, `9 Oct 75`, `Jan 3 64`); and an l for a 1 gives `1lth November 1915` its day. An image year whose quote holds no dated form takes the reply's document month. Four of the six documents filed as having no dated form had one with a two-digit year.
- **Left without a month: 2**, both pages whose Vision text holds no dated form of the date at all. A month written where the page has none: 1, the same document as before this item.
- **On the public set's dates** (11,165 Library of Congress items with a catalogue month): where the strict forms give the title's year no month, the OCR forms write one on 574, the title's month on 99.0% (568/574), its day on 93.5% (503/538) of the days written; the strict forms where they give one, 97.6% (7521/7702) and 94.5% (6845/7243). The misses on both are other dates in the text (a docket's received date, a date the letter mentions) and a day-first numeric date, not misreadings.
- **The image pass for a text year with no dated form, not adopted:** 33 of 175 text years still have no month; the image replies cached for every owner document give the route's year a month on 3, right on 2 on the page truth and written where the owner reads none on 1. Sending it costs one image call (mean $0.0027 over 134 cached owner calls) on each such document, about $0.51 per 1,000 text-year documents, for about 2 months in 133: the route keeps sending the image pass only where the text has no year.

## Truth by source

| source | documents |
|---|---|
| agreed | 86 |
| not explicit | 83 |
| owner, this sheet | 35 |
| year not the owner's | 21 |
| no owner year tag | 20 |
| owner, earlier sheet | 18 |
| no month found | 6 |
| agreed, no month | 3 |

Not scored: "year not the owner's" is an explicit year other than his Finder year tag; "no owner year tag" is a document he left without one; "disputed" is a document that agrees only since the agreed truth was frozen, or that no ruling covers.

## Month and day on the page truth

| | right | wrong | not written | written, none on the page |
|---|---|---|---|---|
| month, this route | 131 | 0 | 2 | 1 |
| month, before the OCR forms | 119 | 0 | 14 | 1 |
| month, before W46.date-full-date | 118 | 1 | 14 | 1 |
| day, this route | 105 | 2 | 4 | 0 |
| day, before the OCR forms | 96 | 2 | 13 | 0 |

Wrong months or days:

- `o:952140959eef6e8e`: route [1978, 2, 4], truth [1978, 2, 9] (owner, earlier sheet)
- `o:3420db3d37f3464f`: route [1969, 1, 23], truth [1969, 1, 22] (owner, this sheet)

## Measurement card

- **Truth:** the page's own full date. Strongest is the owner's own reading of the page on his 2026-10-21 date sheet (18 scored documents) and his blind sheet of 2026-11-18 (35; his two notes read first: one day he can't tell, 27 or 29, is left out of the day score; one confirms the date at the foot of the page over a December date on a document behind it). One sheet document is no longer scored: since W46.date-stamp-fallback the route takes its year from a stamp, with no month or day by design, where he reads 31 July 1975 on the page. Next, the route and a second reader agreeing: the Gemini 3.7 Flash image pass on the first two pages (the same gateway model as the route's trace call, but reading the page image, where the route reads Apple Vision's text and takes its date by rule from a quote that must be in that text), and not against the owner's Finder month tag. That agreed truth was frozen into the rulings file at W46.p16-date-truth-strata (the second reader's full date, equal on every one of them to the route's and to the strict forms' the sheet was drawn on), so it is the route's own answer at the freeze and a later route is scored against it; a document that agrees only since then counts as disputed. Agreement-made truth cannot catch an error both readings share, and it leans the score towards the easy documents: the disputed ones go to the owner, with controls drawn from the agreed ones to measure that truth's own error. Documents whose year came from the image pass are never agreed, since the second reader is then the route's own evidence. The owner's Finder tags carry no day. The sheet is blind (no reading shown; every date-like string Vision read is boxed); where no box holds the second reader's year, the card says a date may lie outside the boxes, which marks a document as harder without saying which reading is right.
- **Selection:** the owner's documents of W46.date-route-pipeline (stratified by date kind from his Finder tags, seed 41), those with a confirmed JPEG original, not chosen by any route or by the ABBYY text. But the score is conditional on the route: a document is scored only where the route gives an explicit year and it equals the owner's year tag, so its month and day are measured on the documents whose year the route already got right.
- **Comparison:** the same cached trace and image replies scored under the new rule and the rule before this item, and with the OCR forms switched off (`date_route_pipeline.OCR_FORMS`); Vision text on the JPEG originals for all. The public set has no route replies, so the route itself is scored on the owner's documents only; the OCR forms alone are checked on the public set's dates (its catalogue titles' month and day against the item's transcribed text, so a title date that is not the text's first date counts against both the strict and the OCR forms).
- **Noise:** n is small (133 months, 111 days); intervals are Wilson 95%, and the agreed stratum's own truth error is bounded only by the sheet's controls (above). The rule is deterministic on cached replies, so there is no rerun noise in the rule itself; a fresh trace call could quote a different date.
- **Scope:** not the tagging call's own month and day (the app keeps its day when it read the same year and month, and both when the route has no dated form; its cached replies here were made on the ABBYY text, so they are not scored), not estimates or inherited years (no month or day by design), and not day-first numeric dates below 13 (read month-first).
