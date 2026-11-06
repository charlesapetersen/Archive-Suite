# Container labels: the truth revised from the owner's sheet notes (W47.ct-truth-revise)

Written by `scripts/segbench/ct_truth.py --rev revise`. The owner answered the first sheet (`ct-truth.md`) on 2026-11-05 and left notes on 127 photos. Those notes changed the field list and the reading rules, took photos out and showed that 36 were shown turned; this build carries all of it. Label values stay in the cache: this page gives counts only.

## What changed

- **Fields.** 14 fields, up from 9: added collection subtitle, series title, box title, date or time period, other identifying marks. The owner records these on many labels.
- **Rules** (in the prompt and in the truth): nothing inferred; Series and Accession only when the label says so ("ACCN" counts), otherwise the text is an other identifying mark; the container is the box number alone; a folder mark like "5-9" or "8.5" is box 5 folder 9, box 8 folder 5; no folder title is read off a box label; a cut-off title is flagged. The scoring compares values case-folded, so title case is not part of the truth; title case and the user's standard names for repositories and collections are Processor features (W47.ct-normalise).
- **Photos taken out:** 18 (8 early photo, taken a different way, 3 "don't train on this", 2 volume spine, 2 "No Folder" sheet, 1 request slip, 1 a loose folder standing for its box, 1 temporary box), leaving 200: 96 box (Red), 104 folder (Purple).

## Upright

The first build turned each JPEG to match its PDF, and those PDFs are not always upright. Apple Vision's text scores at the four turns (`ocr_orient.swift`) gave no clear win on any of the 218 photos: the labels are short or handwritten, and Vision reads upside-down text too. So the turn is Gemini 3.7 Flash's pick among the four turns shown side by side (in an order shuffled per photo), measured against the owner's notes.

| | photos | as the notes say |
|---|---|---|
| the owner called it turned | 33 | 24 turned |
| ... and gave the direction | 4 | 4 turned that way |
| the owner did not flag it | 167 | 157 left as they were |

The 19 photos where the pick and the notes disagree (10 turned, the owner did not flag it, 9 left as it was, the owner flagged it) are asked on the second sheet; the readers read them at the pick's turn, and a photo the owner turns further is reread (its reader-settled fields go back to open at the fold). An unflagged photo the pick turned may also be one the owner saw turned and did not note, so the second row is a floor on the pick's agreement, not an error count.

## Where each settled field came from

| source | fields |
|---|---|
| the owner's ruling on the first sheet | 351 |
| a value the owner's notes give | 122 |
| the owner's rules (no folder title on a box label; text already settled is not a second field; a date inside a title is the date too) | 166 |
| the three readers, unanimous on the revised prompt | 1982 |

**Prompt examples.** 44 settled fields (20 of them the owner's) hold a value that is also one of the prompt's examples, and several examples were taken from the owner's notes, so the drafters may have copied them; each truth row lists them as `prompt_example`, and W47.ct-read leaves them out when it scores the drafters. A route W47.ct-read tests reads with invented examples.

Fields left out of scoring because the owner could not read them: 1. Titles the owner marked cut off: 2.

The first build's agreed fields that the owner did not rule, read again on the revised prompt (a measure of how much the new fields and rules moved the readers):

- date inside a settled title, taken as the date (rule): 7
- first build agreed, unruled, now open or the owner's: 198
- first build agreed, unruled, same value again: 1346
- first build agreed, unruled, unanimous again: 1354
- reading only repeats settled text, not on the label (rule): 151
- repeated readings dropped from a question still asked: 31

## Open, per field (the second sheet)

| field | open on box photos | open on folder photos | settled by the readers |
|---|---|---|---|
| What the photo is | 0 | 45 | 133 |
| Repository | 19 | 0 | 133 |
| Place | 7 | 0 | 173 |
| Collection title | 15 | 14 | 107 |
| Collection subtitle | 21 | 8 | 133 |
| Collection number | 13 | 7 | 128 |
| Accession | 3 | 1 | 167 |
| Series | 3 | 3 | 167 |
| Series title | 2 | 2 | 186 |
| Container (box, carton…) | 10 | 7 | 134 |
| Box title | 21 | 10 | 121 |
| Folder number | 3 | 11 | 144 |
| Folder title | 1 | 21 | 97 |
| Date or time period | 16 | 12 | 121 |
| Other identifying marks | 50 | 53 | 38 |

The second sheet asks 417 questions on 161 photos: 378 open fields, 20 controls (unanimous reader fields, unmarked) and 19 which-way-up questions. It is `pool-jpeg/rev2/sheet/index.html` in the cache (private: corpus images); `ct_truth.py --rev fold ANSWERS.json` folds it into `rev2/truth.jsonl`.

## Cost

Upright check: 200 calls, $0.75. Readers on the gateway: 200 calls, $0.46 (the gateway's own figure $0.4563 on 200 of 200 calls, 1.00 times the estimate on them). Item total $1.20 of its $2.00 cap, real money on the Stanford gateway. Qwen3-VL 8B, 4-bit MLX: 36 min on this Mac, $0. Qwen3.5 4B, 4-bit MLX: 21 min on this Mac, $0.

## Measurement card

- **Truth:** the owner's rulings on the first sheet and the values his notes give, his reading rules, and, for the rest, the three readers' unanimous reading on the revised prompt (agreement, not truth, checked by 20 controls on the second sheet). The readers are the truth's drafters: W47.ct-read scores any of them only on the owner's fields (`ruled`), and reports the rest as agreement (FLD-9). The note values were transcribed from his notes by this session, field by field; long typed titles go back to him on the second sheet to check. Fields whose value is a prompt example are marked and not scored against the drafters.
- **Selection:** the first build's stratified draw by repository from the Finder tags, less the photos the owner took out. The pairing cut's lean stands: 54 photos (43 of the 120 Red) were left out at correlation under 0.65, and the ones checked were true pairs whose PDF was cropped or deskewed, so the set leans to little-changed PDFs. They were not recovered here; W47.ct-read reports the lean beside every figure.
- **Comparison:** the same upright JPEG, prompt and settings for all three readers.
- **Noise:** one pass at temperature 0; no rerun floor.
- **Scope:** a truth under construction. Settles which fields W47.ct-read can score now; says nothing about which reader is right.
