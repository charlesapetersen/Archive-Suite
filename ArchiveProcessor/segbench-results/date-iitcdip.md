# Dating: IIT-CDIP's <ag> and <dd> fields checked on a sample (W46.date-iitcdip)

Written by `scripts/segbench/date_iitcdip.py report`. The question (B-dating.md test 7 and question 6): is IIT-CDIP's attachment-group element `<ag>` a cover-with-attachments relation, and is its document date `<dd>` usable, so that 200 of its documents can be a public relation and dating set? $0, network only. The text, records and page images stay in the bench cache (`date-tagging/iitcdip/`); this page carries counts and case ids only.

## Verdict: one collection passes

`<ag>` means three different things. At American Tobacco it is a family number: documents filed together share it, and about half of those families are the cover-with-attachments relation the item hoped for. At Brown & Williamson it is a running record number, and at R.J. Reynolds a free-text list of attachment titles; neither links a cover to its attachments. `<dd>` holds up as a year label where the page carries a date. So the 200 are drawn from American Tobacco families only. On the page, 5 of 10 sampled families are a cover with its attachment, so each family is checked before it counts.

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

## What follows

- The 200 come from AT families sharing `<ag>`, cover taken as the first member in Bates order, and each is checked on its pages before it counts, since only about half are a cover with its attachment. A family's members lie in image tars a.X, b.X, y.X and z.X for one second letter X; the four `s` tars hold 134 families (about 270 documents), enough for 200 documents once each family's pages are checked.
- `<dd>` is a weak year label, not truth: 21% of records have none, and on undated pages it cannot be checked.
- B&W and RJ give no relation. RJ's free text still names what a cover enclosed, a cue a relation classifier could use, but its attachment was the next record in only 2 of 40.
