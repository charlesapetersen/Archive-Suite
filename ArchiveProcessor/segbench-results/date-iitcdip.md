# Dating: IIT-CDIP's <ag> and <dd> fields checked on a sample (W46.date-iitcdip)

Written by `scripts/segbench/date_iitcdip.py report`. The question (B-dating.md test 7 and question 6): is IIT-CDIP's attachment-group element `<ag>` a cover-with-attachments relation, and is its document date `<dd>` usable, so that 200 of its documents can be a public relation and dating set? $0, network only. The text, records and page images stay in the bench cache (`date-tagging/iitcdip/`); this page carries counts and case ids only.

## Verdict: one collection passes

`<ag>` means three different things. At American Tobacco it is a family number: a document and the attachments filed behind it share it, so it is the cover-with-attachments relation the item hoped for. At Brown & Williamson it is a running record number, and at R.J. Reynolds a free-text list of attachment titles; neither links a cover to its attachments. `<dd>` holds up as a year label where the page carries a date. So the 200 are drawn from American Tobacco families only, and their pages are checked before they are used. The AT family reading rests so far on the records' types, titles and Bates order; the pages of a sample of families are the next check.

## Where the data came from

The item said to use the Industry Documents Library API. IDL's Solr index has no `<ag>` field: its `attachment` field is filled on 321,478 tobacco records, every one in the JUUL collection (born-digital email, 2015-2019), and on none of the MSA collections IIT-CDIP was built from. IDL's PDF downloads refuse scripted requests (HTTP 403 from CloudFront). NIST now hosts IIT-CDIP openly (data.nist.gov, mds2-2531: six text tars of gzipped XML and 648 image tars of TIFF pages). Its README repeats that UCSF makes the documents available for research under fair use, so the no-redistribution reading from W46.fix-date-truth-score stands. The text records keep the producers' metadata block, where `<ag>` sits. NIST mds2-2531 cdip-text/cdip-6.tar (the only text tar fetched), plus single members fetched by Range request, gave 223,295 records.

## What <ag> holds, by producing company

| collection | records | numeric `<ag>` | `0` | free-text `<ag>` | none |
|---|---|---|---|---|---|
| American Tobacco (at) | 14,850 | 14,598 | 0 | 0 | 252 |
| Brown & Williamson (bw) | 21,120 | 17,231 | 3,847 | 0 | 42 |
| R.J. Reynolds (rj) | 45,140 | 0 | 0 | 5,446 | 39,694 |
| Philip Morris (pm) | 93,800 | 0 | 0 | 0 | 93,800 |
| Lorillard (ll) | 23,699 | 0 | 0 | 0 | 23,699 |
| Council for Tobacco Research (ct) | 15,122 | 0 | 0 | 0 | 15,122 |
| Tobacco Institute (ti) | 9,555 | 0 | 0 | 0 | 9,555 |

- **Numeric (AT, B&W).** Almost every record has one, so it is not a flag for records that have attachments. A family's members differ in the first or second letter of the tid, so they sit in different XML members and a single member shows few shared values. Of 27,326 distinct values, 3168 are shared by more than one record (sizes {'1': 24158, '2': 2301, '3': 734, '4': 24, '5': 49, '6+': 60}). Members of a shared value differ only in a tid letter and lie 20 to 30 Bates numbers apart. They are siblings filed together: a series of market snapshots, a run of magazine ads, six patent abstracts, five 1963 letters each marked "Attached to a Responsive Document", the tabbed sections of a binder. 1968 of the 3168 mix document types, and in 381 of the 3029 with two dated members the dates are a year or more apart.
- **The Bates-neighbour test.** A B&W letter or memo and the document right after it in Bates order (found in IDL, its record fetched from NIST), and an AT record marked "Attached to a Responsive Document" and the document right before it: at ag differs by 1: 2; at different ag: 1; at no neighbour in IDL: 2; at same ag: 15; bw ag differs by 1: 5; bw different ag: 1; bw no neighbour in IDL: 11; bw own ag is 0: 3. At AT the attachment and the document before it share the number in most pairs; the document before is the parent (a memo with its chart, a buck slip with its memo, a specification behind its project memo) or a sibling attachment of the same parent, and a value one apart is the next family. At B&W the next document's value is the letter's plus one, a running record number, so a B&W cover and its attachment never share it.
- **Free text (RJ).** A list of the attachments by title, author and date ("CIGARETTE ANALYSIS REPORT, BY SELLS RE, 771214."), or "LIST OF FOOTNOTES.". It names an enclosure but does not point to it. On 40 RJ records drawn at random (footnote lists excluded), the next record in Bates order was the named attachment on 2, something else on 32, and absent from IDL on 6.
- **PM, Lorillard, CTR, TI.** Never present.

## <dd> against the page

| collection | records | full date | year and month | year only | none or dummy | dd year in the OCR text | two-digit year only | absent from the OCR |
|---|---|---|---|---|---|---|---|---|
| at | 14,850 | 11,861 | 921 | 1,898 | 170 | 9,196 | 1,665 | 3,076 |
| bw | 21,120 | 16,166 | 1,326 | 1,444 | 2,184 | 11,600 | 1,776 | 5,133 |
| rj | 45,140 | 35,696 | 2,349 | 5,124 | 1,971 | 27,862 | 4,907 | 9,603 |
| pm | 93,800 | 58,841 | 1,859 | 1,451 | 31,649 | 44,149 | 9,727 | 7,470 |
| ll | 23,699 | 14,703 | 811 | 506 | 7,679 | 11,492 | 2,086 | 2,285 |
| ct | 15,122 | 10,201 | 1,225 | 2,010 | 1,686 | 9,075 | 1,091 | 2,918 |
| ti | 9,555 | 6,795 | 693 | 781 | 1,286 | 5,348 | 925 | 1,867 |

First pages of 36 documents with `<ag>` (14 from shared groups, 10 with free-text `<ag>`, 12 single numeric), streamed from NIST's z.s image tar. 30 were read blind by a subagent (dates transcribed before `<dd>` was shown) and 6 by the session. Each page's own date compared with `<dd>`: exact 14, no date on page 9, year+month agree 4, dd none 3, day differs 2, year agrees 2, month differs 1, year differs 1.

Where the page carries a date and `<dd>` is set, the years agree on all but one. That one is a 1995 email whose table gives 1994 data. The two day-level misses are minutes dated a week after the meeting and a cover letter a day after its typed date. The month-level miss is a sheet of two pasted clippings, where `<dd>` is the earlier one. Where the page has no date (ads, charts, clippings), `<dd>` is the producer's date from elsewhere and cannot be checked on the page. `19000000` is one of the dummy values Lewis warns about. Page kinds: attachment 17, standalone 10, cover 7, divider/blank 1, other 1.

## What follows

- The 200 come from AT families: a parent (`rn` a request code, not "Attached to a Responsive Document") and its attachments sharing `<ag>`, Bates-contiguous in IDL. Family members spread over tars paired by tid prefix, so the draw keeps families whose members all lie in one pair of image tars (`y.s` and `z.s` first) and checks each family's pages before it counts.
- `<dd>` is a weak year label, not truth: 21% of records have none, and on undated pages it cannot be checked.
- B&W and RJ give no relation. RJ's free text still names what a cover enclosed, a cue a relation classifier could use, but its attachment was the next record in only 2 of 40.
