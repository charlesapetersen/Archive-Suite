# W46.ocr-regions-cells — a frozen field pilot, and its two-page Sherlock result

Prepared 2026-10-25; run on Sherlock 2026-10-28 (owner batch 20261028-210354), scored on the Mac 2026-10-29.
Results: §"Capability pilot results" below; score file `regions-cells-score-20261029.json`.
Parent comparison: `regions-20261021.md`, final `787f291f`; crop-validation baseline `ce0aa207`.
The handoff, necessity review and commands are in
`execution-plans/items/W46.ocr-regions-cells.md` (deleted when the item shipped; see `git log`). The committed JSON beside this file
records selection, image hashes and the private truth/protocol hashes without owner transcriptions.

## What this pilot can answer

Whether the same reader can recover selected table fields better from a table region or
an individual field than from a whole page, given oracle locations. GLM-OCR and
Qwen3.6-27B receive the same structured extraction instruction on all three arms.
That instruction differs from the parent's native OCR prompts. New whole-page controls
are therefore essential; this experiment's field accuracy is not the parent's page NES.
GLM may not support this instruction at all. A two-page capability/timing pilot must
settle that before an expanded run is considered. Failure to follow coordinates or JSON
is a protocol limitation, not evidence that cropping harms native OCR.

This is an upper-bound experiment using selected logical fields/subfields, not a detector,
a complete table grid, a structure-recognition benchmark or an accuracy estimate for all L4.
No app routing recommendation changes on this pilot.

## Inputs and eligibility

Four prior deterministic L4 seeds, one from each of the 20-page Smithsonian project
slices, were inspected. Three contain actual tables and remain; the source 63356 seed
`si__NMAAHC-007630087_00354` is paired prose and is excluded without replacement.
The positive seeds represent projects 63359, 63442 and 63444. This is a deliberately small,
pre-inference selection of legible fields and blanks, not a random field sample.

All twelve owner table-tagged candidates were inspected. Front-side tables occur on
p024,p057,p058,p065,p066; p064 is a code-to-label schedule, retained as such. The
other six (p025,p059,p060,p061,p062,p063) have no front-side table. Bleed-through and
page labels must not be treated as cell geometry. The parent's twelve-page labelled
subgroup remains a historical result, not a claim of twelve confirmed front-side tables.

| set | retained pages | fields | headings | entries | verified blanks | writing medium |
|---|---:|---:|---:|---:|---:|---|
| L4 | 3 | 27 | 11 | 16 | 7 | all handwritten, including headings |
| owner96 | 6 | 45 | 18 | 27 | 1 | print, including typewriting |

Every original JPEG matches the parent `pages.jsonl` checksum. L4 uses the exact
2,400-pixel parent copies, not the larger permanent frozen originals. Public volunteer
transcriptions expand abbreviations and omit empty cells, so they were not substituted
for direct pixel truth. The primary inspected the originals and every field crop; an
independent pixel pass inspected all 72 crops, agreed with text and blank labels and
requested wider margins on three crops before freeze. Handwritten date punctuation
remains less certain than numbers. There are no unknown values in these selected fields;
the scorer nevertheless tests null-unknown exclusion separately from verified blanks.

## Frozen protocol and scoring

The frozen bank is 9 pages, 9 regions and 72 fields. Only `_00447` and p024 are scheduled
for the initial pilot: 16 fields, including 2 blanks, across one L4 and one owner page.
For each reader: 2 whole-page requests, 2 table requests and 16 cell requests. Total 40.
The larger bank would require 180 requests for two readers; it is **not submitted**.

`regions_cells.py freeze` stores source-image hashes, truth and code hashes, the
instruction, routes, 4,096-token cap and 90-second stream timeout. It encodes crop JPEGs
once at quality 95 with no padding/minimum-side expansion, then hashes their actual bytes.
Sherlock sends those bytes unchanged; the Mac scores the same bytes, without re-encoding.
Field coordinates use the rounded pixel boxes. Requests contain arbitrary field IDs and
boxes, never transcriptions, roles, medium, type or blank indicators. Runtime receipts
record the resolved weight revision, actual versions, model arguments and Slurm job.

Field accuracy is whitespace/case-normalized exact match. Formatted and discrete fields
have their own accuracy; free text has pooled WER/CER with reference/edit totals. Headings,
entries, medium and type are separate axes; `printed_headings` is their intersection,
so the eleven handwritten L4 headings never enter that split. Null truth is excluded;
failed/missing replies remain in known-field denominators, including blanks. The blank
fabrication rate measures only invented text on verified blanks, accompanied by response
coverage and missing counts; it is not the forms paper's broader hallucination rate.
All arms pool the same fields, never averages of unequal per-request ratios.

A collected pack must have every expected receipt. Caps, malformed JSON and transport
errors remain visible outcomes; they do not silently remove fields or stop the remaining
arms. Empty JSON objects cannot pass capability coverage. Even complete schemas require
raw-reply/accuracy review before expansion: returning blanks everywhere is not capability.

## Verification and cost

45 tests pass: 27 existing region tests, 15 frozen-field tests and 3 submission tests.
Checks include unequal arm grouping, missing and unknown truth, blank fabrication,
resume under another job ID, mixed runtime rejection, interrupted publication, frozen
JPEG/code drift, and a local submission dry-run at paths containing spaces.
An independent review found no remaining material blocker. No app code changed, so no
Xcode build, app launch or paid pipeline smoke was used. No cluster was contacted and
no money was spent.

## Capability pilot results (2026-10-29)

All 40 receipts came back (3 Slurm jobs COMPLETED: stage 50068532, GLM-OCR 50068534, Qwen 50068536).
`regions_cells.py score` accepted the pack (truth `acb6b5c5…`, runtime receipts consistent per route).
Field accuracy is case/whitespace-normalized exact match over the 8 known fields per page (1 verified blank each).

**GLM-OCR cannot do this protocol.** 0 of 20 replies parse as field values. Whole-page and cell replies return the
coordinate boxes back as JSON (`{"f01":[0.0,0.0,1.0,1.0]}`); table replies are its native page transcription.
That is a prompt-capability limit, not a crop result. The arm is stopped here: comparing GLM's crops would need
its own native text prompt on cell crops, a different design.

**Qwen3.6-27B follows the boxes and the schema:** 20 of 20 replies valid, no extra keys, every known field answered.

| set (page) | fields | whole page | table region | single cell |
|---|---:|---:|---:|---:|
| L4 handwritten (`_00447`) | 8 | 2/8 | **4/8** | 0/8 |
| — headings | 2 | 2/2 | 2/2 | 0/2 (CER 14/24) |
| — entries, incl. blank | 6 | 0/6 | 2/6 | 0/6 |
| owner print (p024) | 8 | 7/8 | 7/8 | **8/8** |
| verified blank left empty | 2 | 0/2 | 0/2 | 1/2 |

L4 replies (public Smithsonian page; owner text is not published):

| field | truth | whole | table | cell |
|---|---|---|---|---|
| f01 heading | 1st East Street | 1st East Street | 1st East Street | 104 East 12th |
| f02 heading | Continued | Continued | Continued | Carlina |
| f03 date (blank) | *(empty)* | a sentence from the row | 162 | 1990 |
| f04 type | Quarters | 2 months | 2 months | Pruitt |
| f05 type | Quarters | 2 months | 2 months | 2auth |
| f06 date | Aug 28. | Aug 28, | Aug 28. | Aug 28, |
| f07 type | Residence | Residences | Residences | Решение |
| f08 date | Sept 23. | Apr 23. | Sept 23. | №123. |

What it shows, on 16 fields and two pages, so as direction only:
- On handwriting, a single-cell crop is the worst input: the cells here are 45–98 pixels high and the reader
  loses the row and column context, producing confident inventions (Cyrillic, a wrong street). The table region
  is the best of the three; the whole page misreads entries the table crop gets.
- On clean print every arm reads the text; only the cell crop left the verified blank empty. Whole and table
  requests both filled it from a neighbouring cell, so blank fabrication is a page-context effect here.
- Neither result supports a per-cell route. The table-region signal on handwritten registers is the one worth
  confirming, on the rest of the frozen bank (filed as `W46.ocr-regions-cells-bank`).

**Timing.** GPU job elapsed, startup included: GLM 2 min 10 s, Qwen 4 min 53 s (0.12 GPU-hours together, against
the 2 GPU-hour ceiling). Request time sums are 7.6 s and 13.4 s, so model startup dominates. A Qwen-only run of
the whole frozen bank (9 pages, 90 requests) should take one GPU job of roughly 6–8 minutes (estimate).
