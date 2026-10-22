# Dating: IIT-CDIP's <ag> and <dd> fields checked on a sample (W46.date-iitcdip)

Written by `scripts/segbench/date_iitcdip.py report`. The question (B-dating.md test 7 and question 6): is IIT-CDIP's attachment-group element `<ag>` a cover-with-attachments relation, and is its document date `<dd>` usable, so that 200 of its documents can be a public relation and dating set? $0, network only. The text, records and page images stay in the bench cache (`date-tagging/iitcdip/`); this page carries counts and case ids only.

## Verdict: one collection passes

`<ag>` means three different things. At American Tobacco it is a family number: documents filed together share it, and three in five of those families are the cover-with-attachments relation the item hoped for. At Brown & Williamson it is a running record number, and at R.J. Reynolds a free-text list of attachment titles; neither links a cover to its attachments. `<dd>` holds up: on AT family members it is the page's own date, to the day, on most dated pages. So the 200 are drawn from American Tobacco families only, each family checked on its pages: of all 134 families in four image tars, 80 are a cover with its attachment. The set is those 160 documents plus 40 from the other families as negatives, private in the bench cache.

## Where the data came from

The item said to use the Industry Documents Library API. IDL's Solr index has no `<ag>` field: its `attachment` field is filled on 321,478 tobacco records, every one in the JUUL collection (born-digital email, 2015-2019), and on none of the MSA collections IIT-CDIP was built from. IDL's PDF downloads refuse scripted requests (HTTP 403 from CloudFront). NIST now hosts IIT-CDIP openly (data.nist.gov, mds2-2531: six text tars of gzipped XML and 648 image tars of TIFF pages). Its README repeats that UCSF makes the documents available for research under fair use, so the no-redistribution reading from W46.fix-date-truth-score stands. The text records keep the producers' metadata block, where `<ag>` sits. NIST mds2-2531 cdip-text/cdip-6.tar (the only text tar fetched), plus single members fetched by Range request, gave 265,821 records.

## What <ag> holds, by producing company

| collection | records | numeric `<ag>` | `0` | free-text `<ag>` | none |
|---|---|---|---|---|---|
| American Tobacco (at) | 17,678 | 17,377 | 0 | 0 | 301 |
| Brown & Williamson (bw) | 25,144 | 20,513 | 4,581 | 0 | 50 |
| R.J. Reynolds (rj) | 53,737 | 0 | 0 | 6,490 | 47,247 |
| Philip Morris (pm) | 111,666 | 0 | 0 | 0 | 111,666 |
| Lorillard (ll) | 28,206 | 0 | 0 | 0 | 28,206 |
| Council for Tobacco Research (ct) | 18,004 | 0 | 0 | 0 | 18,004 |
| Tobacco Institute (ti) | 11,376 | 0 | 0 | 0 | 11,376 |

- **Numeric (AT, B&W).** Almost every record has one, so it is not a flag for records that have attachments. A family's members differ in the first or second letter of the tid, so they sit in different XML members and a single member shows few shared values. Of 32,359 distinct values, 3745 are shared by more than one record (sizes {'1': 28614, '2': 2570, '3': 1023, '4': 32, '5': 23, '6+': 97}). Members of a shared value differ only in a tid letter and lie 20 to 30 Bates numbers apart. They are siblings filed together: a series of market snapshots, a run of magazine ads, six patent abstracts, five 1963 letters each marked "Attached to a Responsive Document", the tabbed sections of a binder. 2380 of the 3745 mix document types, and in 460 of the 3585 with two dated members the dates are a year or more apart.
- **The Bates-neighbour test.** A B&W letter or memo and the document right after it in Bates order (found in IDL, its record fetched from NIST), and an AT record marked "Attached to a Responsive Document" and the document right before it: at ag differs by 1: 2; at different ag: 1; at no neighbour in IDL: 2; at same ag: 15; bw ag differs by 1: 5; bw different ag: 1; bw no neighbour in IDL: 11; bw own ag is 0: 3. At AT the attachment and the document before it share the number in most pairs; the document before is the parent (a memo with its chart, a buck slip with its memo, a specification behind its project memo) or a sibling attachment of the same parent, and a value one apart is the next family. At B&W the next document's value is the letter's plus one, a running record number, so a B&W cover and its attachment never share it.
- **Free text (RJ).** A list of the attachments by title, author and date ("CIGARETTE ANALYSIS REPORT, BY SELLS RE, 771214."), or "LIST OF FOOTNOTES.". It names an enclosure but does not point to it. On 40 RJ records drawn at random (footnote lists excluded), the next record in Bates order was the named attachment on 2, something else on 32, and absent from IDL on 6.
- **PM, Lorillard, CTR, TI.** Never present.

## <dd> against the page

| collection | records | full date | year and month | year only | none or dummy | dd year in the OCR text | two-digit year only | absent from the OCR |
|---|---|---|---|---|---|---|---|---|
| at | 17,678 | 14,091 | 1,109 | 2,278 | 200 | 10,953 | 1,996 | 3,648 |
| bw | 25,144 | 19,245 | 1,591 | 1,694 | 2,614 | 13,821 | 2,107 | 6,103 |
| rj | 53,737 | 42,464 | 2,811 | 6,086 | 2,376 | 33,159 | 5,848 | 11,406 |
| pm | 111,666 | 70,089 | 2,209 | 1,709 | 37,659 | 52,527 | 11,574 | 8,933 |
| ll | 28,206 | 17,497 | 960 | 605 | 9,144 | 13,665 | 2,480 | 2,722 |
| ct | 18,004 | 12,218 | 1,428 | 2,360 | 1,998 | 10,808 | 1,302 | 3,481 |
| ti | 11,376 | 8,094 | 835 | 940 | 1,507 | 6,393 | 1,092 | 2,227 |

First pages of 36 documents with `<ag>` (14 from shared groups, 10 with free-text `<ag>`, 12 single numeric), streamed from NIST's z.s image tar. 30 were read blind by a subagent (dates transcribed before `<dd>` was shown) and 6 by the session. Each page's own date compared with `<dd>`: exact 14, no date on page 9, year+month agree 4, dd none 3, day differs 2, year agrees 2, month differs 1, year differs 1.

Where the page carries a date and `<dd>` is set, the years agree on all but one. That one is a 1995 email whose table gives 1994 data. The two day-level misses are minutes dated a week after the meeting and a cover letter a day after its typed date. The month-level miss is a sheet of two pasted clippings, where `<dd>` is the earlier one. Where the page has no date (ads, charts, clippings), `<dd>` is the producer's date from elsewhere and cannot be checked on the page. `19000000` is one of the dummy values Lewis warns about. Page kinds: attachment 17, standalone 10, cover 7, divider/blank 1, other 1.

## AT families on the page

10 AT families drawn at random (seed 46) from those whose members all lie in the y.s and z.s image tars, every member's first page read by the session: cover with attachment 5, related, not the enclosure 3, filed together, no cover 2. In every true pair the first member in Bates order is the cover; the `rn` field named the wrong parent in two of them, so the cover is taken from Bates order, not `rn`. So `<ag>` at AT is a filed-together family, a candidate pool rather than truth: about half are a cover with its attachment, the rest related papers (a reply with the letter it answers, a memo with an earlier memo, a paper with its outline) or clippings filed together.

Then every AT family wholly in the a.s, b.s, y.s and z.s image tars, 134 in all, read by seven subagents in batches of 20, each shown only the members' first pages in Bates order (no `<dd>`, no `rn`, no title), asked to class the family strictly (the later document must be what the first one sends) and to transcribe each page's date: cover with attachment 80, related, not the enclosure 33, filed together, no cover 21. The cover was the first member in Bates order in all but 1. The blind reread agreed with the session's reading above on 9 of 10; the one change is a market-lot memo and its table, which the strict reader called related because the memo never says "attached". Readers noted that an attachment is usually dated before its cover, by days or weeks; where both carry a date the years are same year 61, attachment earlier 4.

## The set

200 documents from 99 families: cover 80, attachment 80, filed with 40. The covers and attachments are all 80 cover families; the negatives are whole families of the other two verdicts, drawn in proportion (seed 46). Private: `iitcdip-set.jsonl` in the bench cache (tid, family, role, verdict, page date as read, `<dd>`, Bates). `<dd>` against the date read on each page, at the finest level both carry:

| role | same day | same month | same year | day differs | month differs | year differs | page undated | dd none |
|---|---|---|---|---|---|---|---|---|
| cover | 74 | 0 | 0 | 0 | 0 | 1 | 5 | 0 |
| attachment | 58 | 6 | 2 | 1 | 1 | 0 | 12 | 0 |
| filed with | 22 | 2 | 1 | 0 | 2 | 1 | 12 | 0 |

On covers `<dd>` is the page's own date almost always; the one year miss is a 1968 memo whose `<dd>` reads 1989. On attachments and filed papers the misses are readings the readers flagged as unsure (a fax header, a faint handwritten date, a digit hidden by a punch hole) or a document spanning months.

## What follows

- The set is ready for the dating and relation benches: 80 cover-with-attachment pairs with page-read dates and `<dd>`, and 40 negatives that share `<ag>` but are not a cover and its enclosure. It is the page images and the set stay in the bench cache, since the documents may not be redistributed.
- `<dd>` is close to truth where the page is dated (169 of 171 dated pages in the set agree on the year), but 21% of all records have none, and on undated pages (ads, charts, clippings) it cannot be checked.
- B&W and RJ give no relation. RJ's free text still names what a cover enclosed, a cue a relation classifier could use, but its attachment was the next record in only 2 of 40.
