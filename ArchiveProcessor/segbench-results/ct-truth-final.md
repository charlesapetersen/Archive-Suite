# Container labels: the truth finished from the owner's second sheet (W47.ct-truth-final)

Written by `scripts/segbench/ct_truth.py --final finish`. The owner answered the second sheet (`ct-truth-revised.md`) on 2026-11-05: 411 of its 417 questions, with notes on 32 photos. This build applies the notes' rules and rereads the photos that were read at the wrong turn. Label values stay in the cache: this page gives counts and photo ids only.

## What each rule changed

| rule | cells or photos |
|---|---|
| photos taken out ("exclude this from training", "just a document", "very unusual") | 4 |
| "other" pressed with nothing typed, asked again | 2 |
| Place cells dropped (open) | 12 |
| Place cells dropped (readers) | 157 |
| Place cells dropped (rule) | 4 |
| Place cells dropped (sheet) | 16 |
| Place cells dropped (sheet2) | 7 |
| carried from the boxes before | 9 |
| container number's leading zero dropped ("Box 9", not "Box 09") | 2 |
| corrected from the second sheet's notes | 4 |
| fields flagged illegible | 1 |
| left unanswered on the second sheet, kept out | 1 |
| owner value repeating another field word for word, asked again | 12 |
| owner value the internal-mark rule would drop, asked again | 2 |
| photos flagged illegible | 1 |
| reader value with internal marks left out (rule) | 1 |
| reading only repeats settled text (rule) | 17 |
| reread photos | 15 |
| reread photos, a reply did not parse | 1 |
| reread: open | 17 |
| reread: the three readers unanimous | 116 |
| rule cell judged again after a correction | 2 |
| titles flagged cut off | 4 |
| to carry, but the boxes before give no value: asked | 2 |
| typed with the button not pressed, taken as typed | 1 |

196 photos remain: 94 box (Red), 102 folder (Purple), 13 fields and the kind.

- **Place** is not a field for boxes and folders (the owner's note); it is gone from the fields, the prompt and the truth, and W47.ct-read does not score it.
- **Internal marks** are not identifying marks: text beside a serial number, "Archival Media", location and shelf-location notes, the archive's logos, barcodes and notes about the box itself. They are in the prompt the reread used; reader values have them left out; an owner value the rule would change is asked once more rather than dropped (on the third sheet, marked "check again").
- **Cut off and illegible.** A cut-off title is flagged (`cut_off`) and its visible text kept apart (`cut_text`), not given as the value; a title that cannot be read is flagged `illegible`; the blurred photo has every field flagged `illegible` (`illegible_photo`), which is itself what the user needs to know, not an empty label. The folder with no label is `unlabelled`: its empty fields are true empties.
- **Carried.** On the five photos the owner marked "fill in per last few boxes", a field he answered "other" with nothing typed takes the most common owner value of the 4 box photos before it on the sheet in its directory (a strict majority), with `src` `carried` and the photos it came from in `carried`. A carried cell is not a reading: W47.ct-read leaves carried cells out of every reading score and never uses them to score carry-forward.
- **"Other" pressed with nothing typed** elsewhere is not "not on the label" (the second fold read it so); it is asked again. A value typed with no button pressed is taken as typed. The third sheet's fold does both, and its turn button records the turn in the answers.

## The reread

15 photos were read at the wrong turn: the 13 the owner turned on the second sheet, one his note gave the turn for, and one he said needs turning with no direction (Gemini 3.7 Flash picked among the three turns it had not been shown at). All three readers read them again at that turn with the final prompt. Gemini's upright pick among all four turns of each rendered photo, as a check: 6 of 15 as they are, 0 upside down, 9 a quarter turn off. Every quarter-turn pick undoes the owner's own turn and none is a half turn, so the turn arithmetic is not reversed: Gemini disagrees with the owner on these photos, as its first pick did (the reason they were on the second sheet). The owner's turn stands. The photo turned by Gemini's pick alone is asked which way up on the third sheet.

## Where each settled cell came from

| source | cells |
|---|---|
| the owner, first sheet | 321 |
| the owner's first-sheet notes | 113 |
| the owner, second sheet | 358 |
| the owner's second-sheet notes | 4 |
| the owner's rules, applied to the readers' readings (reported apart; no owner check but the third sheet's controls) | 169 |
| carried from the boxes before | 9 |
| the three readers, unanimous | 1715 |

Flagged: 4 cut off, 14 illegible, 1 the owner could not read. Of the second sheet's 6 unanswered cells, 4 were on photos now out, one was typed with its button not pressed (taken as typed) and 1 stays out of the truth, unasked (`unanswered`). 173 of 196 photos are complete.

## The third sheet

36 cells stay open, so a short third sheet asks 47 questions on 31 photos: the 36 open cells, 10 rule-settled cells as controls (drawn at random with a fixed seed, unmarked) and 1 which-way-up question. 10 of the open cells are on the reread photo where one reader's reply did not parse (a repetition loop, which a rerun at temperature 0 repeats): two readers settle nothing, so those cells are asked with the two readings. It follows the sheet rule: a notes box per photo, every unasked truth listed with its value, the photos upright with a turn button that is saved. `pool-jpeg/final/sheet/index.html` in the cache (private); `ct_truth.py --final fold ANSWERS.json` folds it into `final/truth.jsonl`.

| field | open |
|---|---|
| What the photo is | 2 |
| Repository | 5 |
| Collection title | 1 |
| Collection subtitle | 3 |
| Collection number | 4 |
| Accession | 1 |
| Series | 3 |
| Series title | 1 |
| Container (box, carton…) | 2 |
| Box title | 3 |
| Folder number | 2 |
| Date or time period | 3 |
| Other identifying marks | 6 |

## Cost

Gateway (Gemini 3.7 Flash, real money on the Stanford PTA): 16 upright calls (the one pick and the check) and 15 reader calls, $0.109 of this item's $0.50 cap. The two open models ran on this Mac, $0.

## Measurement card

- **Truth:** the owner's answers on two sheets and his notes, his rules applied to the readers' readings, values carried from the boxes before, and for the rest the three readers unanimous. `ruled` lists the owner's own cells; `by_rule` the rule-settled ones, reported apart, whose only check is the third sheet's 10 controls; carried cells are marked and are no reader's reading. The drafters are scored only on `ruled` (FLD-9); `prompt_example` cells are left out of their scores.
- **Selection:** the first build's stratified draw by repository, less the photos the owner took out (now 22). The pairing cut's lean stands (54 photos left out, 43 Red, toward little-changed PDFs); W47.ct-read reports it beside every figure.
- **Comparison:** the reread photos were read by the same three readers, at the right turn, with the final prompt (the second-sheet prompt less Place, plus the internal-mark rule); the other photos' reader cells are from the second-sheet prompt, whose difference the rules applied here cover.
- **Noise:** one pass at temperature 0; no rerun floor.
- **Scope:** a truth. Says nothing about which reader is right; that is W47.ct-read.
