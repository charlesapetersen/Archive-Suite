# A dated folder photo dates the undated documents inside it (W47.ct-folder-date)

The owner's rule, from his notes on the page-date sheet (2026-10-31, D06, D14, D18): *"A date is given, so all the
documents inside can be assumed to come from this date if otherwise undated."* Measured before it goes into the
container inheritance, at $0: no call, no upload, no ABBYY text. Script: `scripts/segbench/folder_date.py`;
figures: `folder-date.json`.

A folder run is SPEC/containers.md's: a Purple photo starts it, and it covers the files after it in the directory
until the next Purple or a Red. The folder's date is read two ways:
- **Vision + parser** (`ct_read.vision_read`'s `date`) on the cached Vision lines of every folder photo, which costs
  nothing. It is not the route the design reads dates with.
- **The owner-checked label truth** (W47.ct-truth-final's `date` cell) on the 60 folder photos in these runs that are
  in that truth. This is what a confirmed run date would be.

## What the rule would date

| | Count |
|---|---|
| Agreed undated documents (W46.date-undated's 425) | 425 |
| in a folder run | 280 (66%) |
| in a run whose folder photo Vision + parser reads a year or range | **135 (32%)** |
| Folder photos over an undated document | 160 |
| of which Vision + parser reads a date | 58 (57 a year or range, 1 a misread "1684") |
| The 57 dates: one year / a span of ten years or less / over ten years | 34 / 18 / 5 |

Across all 1,840 folder photos in the labelled folders, Vision + parser reads a year or range on 791 (43%). The design
reads the date with GPT 5.6 Luna, which scored 86% on label dates against Vision + parser's 72% (ct-read.md), so it
would date more folders than this.

## Does the folder's date hold for what is inside?

The documents in the same runs that the owner did date are the check: is his year inside the folder's date?

| Folder date from | Documents | Inside the date | Within a year | One-year dates | Ranges | Folders: all inside / none |
|---|---|---|---|---|---|---|
| **Owner-checked label truth** | 56 (17 folders) | **49 (88%, 76–94)** | 52 (93%) | 13 of 14 (14 within a year) | 36 of 42 | 14 / 0 |
| Vision + parser, same 17 folders | 48 | 36 (75%, 61–85) | 46 (96%) | 12 of 23 (21 within a year) | 24 of 25 | 11 / 3 |
| Vision + parser, every dated folder | 1,763 (481 folders) | 1,079 (61%, 59–63) | 1,241 (70%) | 458 of 1,034 (44%; 587 within a year) | 621 of 729 (85%) | 301 / 106 |

The intervals are Wilson 95% by document. Documents in one folder are not independent: the truth row rests on 17
folders, and one folder of 10 documents holds 5 of its 7 misses. Resampling the 17 folders (10,000 draws, every
document of a drawn folder kept) gives 73–100% for inside the date.

## What the rule writes, scored by its form (W46.p17-folder-date-forms)

"Inside the date" is not what the shipped rule writes. The owner's rule (`ContainerFolderDate.inherited`,
SPEC/containers.md §The folder-date rule) writes a single year as it is, the mid-point year for a span of 2 to 7
years (an even span the earlier middle year), the decade for 8 to 19, and nothing from 20. Each form scored against
the owner's Year tag (exact: the written year is his year; for a decade, his year is in it):

| Folder date from | Form written | Documents | Inside the date | Written value exact | Within a year |
|---|---|---|---|---|---|
| **Owner-checked label truth** | single year | 14 | 13 | **13** | 14 |
| | mid-point year | 42 | 36 | **20 (48%)** | 33 (79%) |
| | · span 2 / 3 / 5 / 6 / 7 | 19 / 5 / 2 / 13 / 3 | 13 / 5 / 2 / 13 / 3 | 11 / 5 / 1 / 0 / 3 | 15 / 5 / 2 / 8 / 3 |
| | decade (8–19 years) | 0 | | unmeasured | |
| | every written year | 56 | 49 | **33 (59%)** | 47 |
| Vision + parser, every dated folder | single year | 1,034 | 458 | 458 (44%) | 587 |
| | mid-point year | 416 | 350 | 128 (31%) | 325 |
| | decade | 225 | 186 | 88 (39%) | |
| | nothing (20 years or more) | 88 | 85 | | |

Clustered by folder (10,000 draws over the 17 folders), the truth row's written value is exact for 34–89%.

**The mid-point year is exact for about half the documents it dates, within a year for four in five.** The single year
is right 13 of 14. The 13 documents under one six-year folder (1978-1983) take 1980 and none is 1980 (4 are 1979, 4 are 1981, 5
are 1982); all 13 are inside the span. The decade form has no document in the truth runs, so it is unmeasured on owner truth.

**The even-span middle.** On the 32 truth documents under an even span (7 folders) the earlier middle year, which
the rule writes, is exact for 11 and within a year for 23; the later middle would be exact for 6 and within a year
for 22. Vision + parser's 288 (79 folders): 99 against 98 exact. The earlier middle does no worse here; 7 folders do
not settle it.

**The folder's real date holds.** Where the date is the one the owner checked, 88% of the dated documents fall inside
it and 93% within a year, and no folder's date is wrong for all its documents.

**Vision + parser's single year is often not the folder's date.** Inside the read single year: 44%. The 106 folders
where no dated document falls inside the date are mostly of three kinds:
- a later processing or library year (Intel Publications 2015, 2016 and 2018 over documents from 1971 to 1984,
  Seabury 2013 and 2019);
- a year from the folder's title or another mark (Academic Council 1973 over 1947 to 1968, Cuthbertson 1935 over
  1965);
- the first date on a slip or form, not the span (10/11/1904 over 1905 and 1906).

A range read is right 85% of the time. So a date read off the photo by Vision cannot date documents unconfirmed.

**Decade-tagged documents** in dated folders overlap the folder's date 46 of 76 times (Vision + parser's date).

## The undated documents' own page years

Of the 135 undated documents in a dated run, W46.date-undated sampled 27. The image pass found a year of the
document's own on 11, and 8 fall inside the folder's (Vision + parser) date. The owner's sheet ruled on 4 of them:
- D02 1971 (the folder: 1971-1973) and D04 1978 (1978): inside.
- D03 1962 (1950-1969): inside.
- D18 1970 (1971-1972): outside. D18 is itself a folder photo, dated Feb. 1970, inside an earlier folder's run.

The rule applies only where the document has no date of its own, so these show the folder date agreeing with a page
date, not a case the rule would change.

## Folder photos not marked Purple

Four of the 20 documents the owner judged on the sheet were photos of folders, not documents: D06, D13, D14 and D18.
D13's folder carries no date. The rule follows the Purple marker (Route A) or a Folder directory (Route B), so an
unmarked folder photo dates nothing. The sheet's 20 were chosen for false years, so 4 in 20 is not the corpus's rate.

## Questions for the owner (W47.ct-folder-date-owner-ok)

1. **The tag a range becomes.** A folder dated 1965-1967 holds an undated document. The tags hold one Year or one
   Decade, so "both years" needs a SPEC change. Options:
   - the decade, where the range lies inside one (1960s); a range across decades has no decade;
   - the first year with Date Uncertain;
   - both years, as a new range value (a SPEC and Reader change).
   18 of the 57 dated folders here span up to ten years, and 5 span more.
2. **Date Uncertain on an inherited date.** The folder's checked date holds for 88% of the dated documents inside,
   and 12% fall outside it.
3. **The month.** D18's "Feb. 1970": fill the Month from the folder, or the year alone?

The figures add one point for the design: only a run date the user has confirmed should date documents. Vision +
parser's own read is right for 44% of single years.

## Measurement card

- **Truth.** The owner's Year tags on the dated documents in the same runs (his own tagging, not made for this
  item). The label truth's dates are W47.ct-truth-final's, drafted by Qwen3-VL 8B, Qwen3.5 4B and Gemini 3.7 Flash
  and checked by the owner. The page years of the undated documents are Gemini 3.7 Flash's image pass (W46.date-
  undated), with the owner's sheet rulings where they exist.
- **Selection.** Every folder run in corpus_pairs' labelled folders and every agreed document in it. Nothing was
  chosen by a route's reply or by ABBYY text. The label-truth photos are the 60 in these runs, out of the 196 chosen
  for W47.ct-truth.
- **Comparison.** Vision + parser and the label truth on the same 17 folders: the truth row against the Vision row
  above it. The folder run rule is the SPEC's, applied to filenames in capture order.
- **Noise.** Wilson 95% by document, with folder counts beside them; for the truth row also a bootstrap over its 17
  folders (10,000 draws, seed 17): inside 73–100%, the written value exact 34–89%. The truth row's n is small (56
  documents, 17 folders; one folder of 10 documents holds 5 of the 7 misses), so a by-form gap under that width is a
  tie.
- **Scope.** It does not measure Luna's or Gemma's date read on these photos (only the label truth and Vision). It
  does not say how often a folder's date holds for undated documents, since those have no truth year; the dated
  neighbours stand in for them. It does not count unmarked folder photos in the corpus. Not on the bench page:
  this is a container rule's check, not an OCR or segmentation route.
