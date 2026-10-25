# W46.ocr-regions-cells — a frozen field pilot, awaiting Sherlock

Prepared 2026-10-25. **No reader has run on this pack and no crop gain is measured.**
Parent comparison: `regions-20261021.md`, final `787f291f`; crop-validation baseline `ce0aa207`.
The handoff, necessity review and commands are in
`execution-plans/items/W46.ocr-regions-cells.md`. The committed JSON beside this file
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
No app routing recommendation changes while it is pending.

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
no money was spent. No new OCR result is added to ArchiveOCRBench before collection.
