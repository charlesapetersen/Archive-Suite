# Segmentation ground truth — the owner's check and the draft document rules

Written 2026-10-05 by `W36.seg-truth` (plan: `00-plan.md` Part 2). The owner's answers are recorded by
`W36.seg-truth-owner-ok` (HOLD). No CSV in `Test Files/` is changed until the owner has answered; the bench
(`W36.seg-bench`) can start on the development set before then.

## How to open the review pack

The pack holds page thumbnails of private archival photos, so it lives outside git:

```
open ~/Library/Caches/ArchiveSuiteRehearsal/seg-truth/index.html
```

`index.html` shows each case with the page, the page before and the page after, the current label, the text
the spring Gemini runs saved for the page (up to 300 characters, every distinct reading), and one question with
its answer options. `rules.html` beside it is the draft of the document rules below. Answers are kept in the
browser as the owner clicks; the "Collect my answers" button at the bottom turns them into text to paste into
the session.

Rebuild it (reads `Test Files/` only, writes thumbnails with `sips -Z 800` into the cache folder, reuses
thumbnails already made, stdlib only, no OCR, no network):

```
python3 ArchiveProcessor/scripts/segbench/make-truth-pack.py            # the pack
python3 ArchiveProcessor/scripts/segbench/make-truth-pack.py --markdown # the case list below
```

## How the cases were picked

- **Saved text.** The three spring runs (`test_results/`, `test_results/improved_v1/`, `improved_v2/`) each
  saved up to 300 characters per page. All distinct readings are used, because they disagree: some readings
  show the previous page's text (RG 165 91 is one), and the model's bracketed notes (`[folder_label]`) are
  skipped.
- **Page number first (case type a).** A New page where a page number of 2 or more appears in the top three
  lines of any reading: `-2-`, `- 2 -` inside a heading line, `Page 2`, `Pg 2`, `(2)`, a number alone on its
  line, and on the first line only `2.` and `6A`. Pages whose top also carries a newspaper masthead, section
  line or the stars printed beside newspaper page numbers get the clipping question instead of the letter one.
  This finds **33** pages, 3 of which are the named suspects in type b, so 30 are listed under a. The plan's
  "38" was not reproduced: a looser pattern adds filing codes ("44A"), a list item ("2." on line 3), a
  citation ("From p. 59") and the model's own notes ("[DOCUMENT START - PAGE 2]"), which are not page
  numbers. Newspaper page numbers (15 of the 30) are kept because they raise the clipping rule.
- **Opening on a Cont page (type c).** A Cont page whose top eight lines, in any reading, hold a greeting
  ("Dear …", "Gentlemen") or a memo heading ("MEMORANDUM", "TO:"), excluding pages that also carry a page
  number (a page 2 that quotes a form letter) and matches in lower case mid-sentence. **5** pages.
- **Named in the plan (types b and d).** Dean 13, 15 and 111–112; RG 165 41–42, 91–93 and 107–113; Herrnstein
  64–65.

## The cases

The pack numbers the cases the same way. "What to check" names the cue only; the page text is in the pack.

### Labels that look wrong — 3

| Case | Collection | File number(s) | Current label | What to check |
|---|---|---|---|---|
| 1 | Dean | 13 | 13: New | page 13 starts “-2-”, same addressee and date as page 12 |
| 2 | Dean | 15 | 15: New | page 15 heading has “- 2 -”, same addressee and date as page 14 |
| 3 | Dean | 111–112 | 111: New, 112: Cont | two copies of a page 2 with the same addressee and date; page 1 apparently absent |

### Pages marked “new document” that start with a page number of 2 or more — 30

| Case | Collection | File number(s) | Current label | What to check |
|---|---|---|---|---|
| 4 | Dean | 87 | 87: New | page number “-5-” at the top |
| 5 | Dean | 105 | 105: New | page number “- 2 -” at the top |
| 6 | Dean | 177 | 177: New | page number “4.” at the top |
| 7 | Deaver | 12 | 12: New | newspaper page number “Page 14” at the top |
| 8 | Deaver | 29 | 29: New | newspaper page number “Page A8” at the top |
| 9 | Deaver | 60 | 60: New | newspaper page number “Page 58” at the top |
| 10 | Deaver | 62 | 62: New | newspaper page number “Page 69” at the top |
| 11 | Deaver | 66 | 66: New | newspaper page number “Page 8” at the top |
| 12 | Deaver | 71 | 71: New | newspaper page number “Page 2” at the top |
| 13 | Deaver | 79 | 79: New | newspaper page number “Page 61” at the top |
| 14 | Deaver | 82 | 82: New | newspaper page number “Page 6” at the top |
| 15 | Deaver | 119 | 119: New | newspaper page number “Page 55” at the top |
| 16 | Deaver | 121 | 121: New | page number “14” at the top |
| 17 | Deaver | 144 | 144: New | newspaper page number “Page A3” at the top |
| 18 | Deaver | 146 | 146: New | newspaper page number “Page A3” at the top |
| 19 | Herrnstein | 21 | 21: New | page number “Page 2” at the top |
| 20 | Herrnstein | 60 | 60: New | page number “Page 2” at the top |
| 21 | Herrnstein | 72 | 72: New | page number “Page 2” at the top |
| 22 | Herrnstein | 113 | 113: New | page number “-2-” at the top |
| 23 | Herrnstein | 127 | 127: New | page number “Page 2” at the top |
| 24 | Herrnstein | 136 | 136: New | page number “Page 2” at the top |
| 25 | Herrnstein | 159 | 159: New | page number “Page 2” at the top |
| 26 | Herrnstein | 175 | 175: New | page number “Page 2” at the top |
| 27 | Herrnstein | 192 | 192: New | page number “page 2” at the top |
| 28 | RG 165 | 51 | 51: New | page number “-2-” at the top |
| 29 | RG 165 | 106 | 106: New | page number “Pg 2” at the top |
| 30 | Stanton | 121 | 121: New | newspaper page number “Page 31” at the top |
| 31 | Stanton | 131 | 131: New | newspaper page number “Page 6” at the top |
| 32 | Stanton | 230 | 230: New | newspaper page number “6A” at the top |
| 33 | Stanton | 232 | 232: New | newspaper page number “10A” at the top |

### Pages marked “continues” that start like a new letter or memo — 5

| Case | Collection | File number(s) | Current label | What to check |
|---|---|---|---|---|
| 34 | Dean | 23 | 23: Cont | begins with a “MEMORANDUM” heading |
| 35 | Herrnstein | 22 | 22: Cont | begins with a greeting (“Dear …”) |
| 36 | Herrnstein | 25 | 25: Cont | begins with a greeting (“Dear …”) |
| 37 | RG 165 | 4 | 4: Cont | begins with a “MEMORANDUM” heading |
| 38 | Stanton | 102 | 102: Cont | begins with a greeting (“Dear …”) |

### Runs of box and folder labels — 4

| Case | Collection | File number(s) | Current label | What to check |
|---|---|---|---|---|
| 39 | Herrnstein | 64–65 | 64: Folder, 65: Box | folder label immediately before a box label |
| 40 | RG 165 | 41–42 | 41: Folder, 42: Folder | two folder labels in a row; 42 carries a stamp |
| 41 | RG 165 | 91–93 | 91: Box, 92: Box, 93: Box | three box labels in a row; one reading of 91 matched page 90 |
| 42 | RG 165 | 107–113 | all Box | seven box labels in a row at the end of the box, no documents after |

## Document rules — APPROVED by the owner 2026-10-05, with two changes

The owner approved the nine rules below ("The rules look good"), changed rule 1 so that an enclosure with a date of
its own is dated twice — its own date and the date of the letter that sent it — and added a tenth: a full magazine is
one document. Two dates on one file is not possible in the current tag format (one Year/Month/Day per file,
`SPEC/tag-format.md`); whether to build it is the owner's decision. The pack's `rules.html` is rebuilt from `make-truth-pack.py`.

### The rules as first drafted

Each rule has a recommended default and the reason. Box and folder labels keep their own marks and are
never part of a document. Rules 1 and 2 split the "enclosure or attachment" question by whether the item has
a date, author or heading of its own.

1. **An enclosure — a complete item sent with a letter (a report, a pamphlet, someone else’s letter).** Recommended: Its own document: mark its first page New. Why: It has its own author, date and subject. Joined to the cover letter it would take the letter’s date and tags. It stays next to the letter in the box, so the link is not lost.
2. **An attachment — something made to go with this letter or memo (“Attachment A”, a list, a table, a budget) with no date or heading of its own.** Recommended: Part of the letter: mark its pages Cont. Why: It has no date or author apart from the letter, and it makes no sense on its own.
3. **A carbon copy of a letter (the sender’s file copy).** Recommended: Treat it as the letter: its first page is New, like any letter. Why: In most files the carbon is the only copy the archive has, so it is the document.
4. **Two copies of the same document kept together (an original and a carbon, or two carbons).** Recommended: Each copy is its own document: the second copy’s first page is New. Why: They are separate pieces of paper the archive kept, and one may carry notes the other lacks.
5. **The same page photographed twice by mistake.** Recommended: Mark the repeat Cont, as part of the same document. Why: It is one piece of paper; a second document would be false. Leaving the photo out would lose it from the record.
6. **An envelope.** Recommended: Part of the letter it held, when it sits next to that letter: mark it Cont. An envelope on its own is its own document. Why: Its postmark and addresses date and place that letter.
7. **A newspaper clipping.** Recommended: Each article is its own document. A second piece of the same article (“continued on page 8”) is Cont. Several articles in one photo stay one document. Why: Articles have their own dates and subjects. A photo cannot be split, so one photo is never more than one document.
8. **A photograph (a print in the folder).** Recommended: Its own document. A photo of its back (caption, stamp) is Cont. Why: A print is an item in its own right; the back belongs to the same print.
9. **A blank page or the blank back of a sheet.** Recommended: Cont, as part of the document it belongs to. Why: It carries nothing of its own and should not start a document.

## What the answers change

An answer of "change" is applied to the collection's CSV by the owner, or with the owner's approval, in the
session that records `W36.seg-truth-owner-ok`; the bench reads the CSVs as they stand. Proposed for an answer that
leaves a photo out of the test: record it in a list the bench reads, rather than deleting the CSV row, so the
owner's file stays a full list of the photos (the bench item decides the form). Approved rules apply to the fresh box if the owner labels
one, and become the definition the bench scores against.

## Added 2026-10-05 by W36.seg-base — a possible one-row shift

Herrnstein 19–25 may be shifted by one row in the CSV: 19 is labelled a continuation but reads as a folder label,
20 is labelled Folder but is a letter, and 21 is labelled New but is that letter's page 2. Not yet in the review
pack (rebuild it with `make-truth-pack.py` after adding the case); the CSV is unchanged.

## The owner's answers (2026-10-05) and what was done with them

**Applied to the CSVs** (with the owner's approval; the originals are backed up outside git at
`~/Library/Caches/ArchiveSuiteRehearsal/seg-truth/csv-backup-20261005/`): Dean 13 New→Cont, Dean 15 New→Cont,
Dean 23 Cont→New, Herrnstein 21 New→Cont, Herrnstein 22 Cont→New, Herrnstein 25 Cont→New, RG 165 4 Cont→New. Every
other case is kept as labelled; case 3 (Dean 111–112) is the owner's own correct segmentation (see note).
**Still open:** Herrnstein 19 and 20 from the suspected one-row shift were not in the pack and are not answered.
**Not yet approved:** the document rules (`rules.html`).

**What the owner's notes teach every method** (these are domain facts; prompts and features should use them):
- **Show-through ("onion skin").** Thin paper shows the page beneath, and OCR reads that text: a "-2-" or "Page 2"
  read on a new document is often the NEXT sheet's page number seen through the paper (cases 5, 6, 20–29). A page
  number is only a continuation cue if it is printed on this sheet; OCR text from underneath must be ignored.
- **A small item photographed on top of a full page.** A telegram or a small cover letter lying on a full sheet: the
  sheet underneath is visible in the photo but is the NEXT document's first page (case 3, Dean 110–111).
- **Newspaper clippings start with a byline, a wire credit ("(AP)", "(UPI)") or a section heading ("Opinion").**
  Continuation pages of an article rarely carry a byline; a wire service is credited on the first page only. A
  newspaper page number ("Page A8") at the top is where the clipping began, not a continuation cue (cases 7–18, 30–33).
- **A full magazine is one document**, not a set of clippings (case 38).
- **Never change the order of photographs.** Empty folders and empty boxes are common: a run of box or folder
  photos means the box or folder was examined and nothing was worth photographing (cases 39–42).

The owner's answers, as pasted:

```
Case 1 (Dean 13): Change 13 to Cont (page 2 of the letter on page 12)
Case 2 (Dean 15): Change 15 to Cont (page 2 of the letter on page 14)
Case 3 (Dean 111–112): NOT ANSWERED | note: Page 110 shows a telegram at the bottom of the page. The top of page 111 is visible at the top of Page 110. This leads to the mistake. My segmentation here was correct. We need to look out for cases where the entirety of a page is visible but a smaller main object is in front, in this case a telegram, in other cases a small cover letter.
Case 4 (Dean 87): Keep as is (starts a new document) | note: No "-5-" appears on this page. There is a new date and a new title. It is clearly a different document.
Case 5 (Dean 105): Keep as is (starts a new document) | note: There is no "- 2 -" on this page. Instead, the OCR is picking up on the text of the page below this page, which does include a "- 2 -." The letter is likely onion skin. We need to prevent OCR of text below a page.
Case 6 (Dean 177): Keep as is (starts a new document) | note: Same problem with transparent onion skin paper.
Case 7 (Deaver 12): Keep as is (a new clipping) | note: It is a clipping that began on page 14 of the newspaper. Note the byline, which signals this is a new clipping. Bylines typically do not appear on continuation pages.
Case 8 (Deaver 29): Keep as is (a new clipping) | note: It is a clipping that begins on page A8. Note the byline, which signals this is a new clipping.
Case 9 (Deaver 60): Keep as is (a new clipping) | note: Note the byline.
Case 10 (Deaver 62): Keep as is (a new clipping) | note: Note the (AP) source. A wire service will typically only be credited on the first page of an article.
Case 11 (Deaver 66): Keep as is (a new clipping) | note: Note the byline.
Case 12 (Deaver 71): Keep as is (a new clipping) | note: Note the "Opinion" section, signaling this is the start of the Opinion section.
Case 13 (Deaver 79): Keep as is (a new clipping) | note: Note the byline
Case 14 (Deaver 82): Keep as is (a new clipping) | note: Note the byline
Case 15 (Deaver 119): Keep as is (a new clipping) | note: Note the (UPI) credit.
Case 16 (Deaver 121): Keep as is (starts a new document) | note: Note the (UPI) credit.
Case 17 (Deaver 144): Keep as is (a new clipping) | note: Note the byline
Case 18 (Deaver 146): Keep as is (a new clipping)
Case 19 (Herrnstein 21): Change to Cont (part of the document before)
Case 20 (Herrnstein 60): Keep as is (starts a new document) | note: Onion skin problem.
Case 21 (Herrnstein 72): Keep as is (starts a new document) | note: Onion skin problem
Case 22 (Herrnstein 113): Keep as is (starts a new document) | note: Onion skin problem
Case 23 (Herrnstein 127): Keep as is (starts a new document) | note: Onion skin problem
Case 24 (Herrnstein 136): Keep as is (starts a new document) | note: Onion skin problem
Case 25 (Herrnstein 159): Keep as is (starts a new document) | note: Onion skin problem
Case 26 (Herrnstein 175): Keep as is (starts a new document) | note: Onion skin problem
Case 27 (Herrnstein 192): Keep as is (starts a new document) | note: Onion skin problem
Case 28 (RG 165 51): Keep as is (starts a new document) | note: The "-2-" is from a page underneath the main page in this photo.
Case 29 (RG 165 106): Keep as is (starts a new document) | note: Onion skin problem
Case 30 (Stanton 121): Keep as is (a new clipping) | note: Not the (AP) credit.
Case 31 (Stanton 131): Keep as is (a new clipping) | note: Note the byline
Case 32 (Stanton 230): Keep as is (a new clipping) | note: Note the byline
Case 33 (Stanton 232): Keep as is (a new clipping) | note: Note the byline
Case 34 (Dean 23): Change to New (a new document)
Case 35 (Herrnstein 22): Change to New (a new document)
Case 36 (Herrnstein 25): Change to New (a new document)
Case 37 (RG 165 4): Change to New (a new document)
Case 38 (Stanton 102): Keep as is (part of the document before) | note: This is a scan of a full magazine (note the cover) that should not be treated as a clipping, I believe.
Case 39 (Herrnstein 64–65): Keep as is (64 is an empty folder at the end of the previous box) | note: Absolutely never change the order of photographs. Frequently there will be empty folders or empty boxes.
Case 40 (RG 165 41–42): Keep as is (two folder labels; 41 is an empty folder or a second photo of a label)
Case 41 (RG 165 91–93): Keep as is (91, 92 and 93 are all box labels)
Case 42 (RG 165 107–113): Keep as is (seven box labels) | note: Empty box photos signal that the box was examined but nothing was deemd worthwhile to photograph.
```

**Herrnstein 19–20 (owner, 2026-10-05):** "Herrnstein file 19 is a folder. Herrnstein File 20 is the start of a
letter." Applied: 19 Cont→Folder, 20 Folder→New (same backup folder). The ground-truth check is complete.

