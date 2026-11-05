# Container labels: the truth set's three-reader draft, on the JPEG originals (W47.ct-truth-jpeg)

Written by `scripts/segbench/ct_truth.py compare`. 218 marker photos (Red for a box, Purple for a folder), each the JPEG original of a corpus PDF, upright, at 1280 px. Read blind into the nine fields of `execution-plans/containers/00-plan.md` plus what the photo is, by Qwen3-VL 8B, 4-bit MLX, Qwen3.5 4B, 4-bit MLX, Gemini 3.7 Flash (Stanford gateway, low reasoning); temperature 0, the same image and prompt for each. A field is agreed when all three readings match after case, punctuation and "Box No." spellings are normalised; all empty counts as agreed. Agreement is not truth: three readers can make the same miss, which is what the sheet's controls measure.

The first build read the corpus PDFs; it stays beside this one (`ct-truth-pdf.md`, and `pool/` in the cache) and is compared below.

## The sample: the PDF build's 240, on their JPEG originals

Each of the PDF build's 240 markers was paired through `corpus_pairs.py`'s pairs.tsv and confirmed by `ocr_truth.orient_like_pdf` (grey thumbnails at four turns, correlation at least 0.65), whose best turn makes the JPEG upright like the PDF. A marker left out was refilled from its stratum and colour (a fresh draw, seed 4701, over the corpus's current markers, each confirmed the same way). The corpus now holds 4399 single-colour markers; some of the 240 have moved since.

| | box (Red) | folder (Purple) |
|---|---|---|
| in the PDF build | 120 | 120 |
| left out: JPEG not the same photo | 43 | 11 |
| left out: no JPEG paired | 5 | 6 |
| left out: no longer a marker in the corpus | 5 | 6 |
| refilled from the stratum | 41 | 13 |
| short (a stratum with no confirmed marker left) | 12 | 10 |
| in this build | 108 | 110 |

Turned to match the PDF: 34 of 218 (18 by 90°, 4 by 180°, 12 by 270°). Correlation of the kept pairs 0.66–1.00, median 0.90.

**The cut is conservative on label photos.** The 54 pairs under the cut ran -0.03 to 0.645 in an unbroken spread, not the two clusters the cut was set on (true document pages 0.69–0.98, mismatches 0.16–0.48). An eye check of eight Red rejects spread across that range (−0.03 to 0.645) found all eight the same photo as their PDF: the PDF had been cropped, deskewed or straightened (one PDF is upside down), which lowers a whole-image correlation. So most of the "not the same photo" left-outs are true pairs, and the refills lean toward markers whose PDF was little changed. The cut was kept, as the item asks; a label-photo confirmation that tolerates cropping (text overlap, feature matching) would recover them.

## Strata in the sample

A stratum is the repository's directory, except under a workflow folder, where the level below it is a priority folder or Re-OCR and the corpus has no repository level (marked *workflow*).

| stratum | box (Red) | folder (Purple) | of them refilled |
|---|---|---|---|
| American Jewish Committee Archives | 1 | 1 | 0 |
| Babbage | 6 | 5 | 4 |
| Bancroft Library | 2 | 2 | 0 |
| Cambridge | 1 | 2 | 0 |
| Center for Jewish History | 2 | 2 | 1 |
| Chicago, University of, Archives | 5 | 5 | 1 |
| Columbia University | 2 | 2 | 0 |
| Computer History Museum | 4 | 4 | 3 |
| HBS | 5 | 6 | 5 |
| Harvard Law School | 2 | 2 | 0 |
| Harvard University Archives | 12 | 15 | 5 |
| Hoover Institute | 11 | 7 | 10 |
| Huntington Library | 4 | 4 | 1 |
| London School of Economics | 2 | 0 | 0 |
| NARA | 3 | 2 | 2 |
| NYPL | 3 | 2 | 3 |
| Northwestern | 2 | 2 | 1 |
| Othmer | 3 | 2 | 0 |
| San Jose State | 0 | 2 | 2 |
| Stanford University Archives | 9 | 8 | 4 |
| Stanford University Archives — Tech | 11 | 16 | 7 |
| Swarthmore Archives | 2 | 2 | 0 |
| UIUC | 2 | 0 | 2 |
| UNLV | 2 | 2 | 0 |
| USC | 11 | 10 | 2 |
| Wisconsin Historical Society | 1 | 5 | 1 |

Drafted by all three: 218; a reply that did not parse: 0. Apple Vision lines for the sheet's boxes: 214 photos.

## Agreement per field

Not unanimous / unanimous with a value / unanimous empty, out of the photos all three drafted; then which reader was the odd one out where the other two agreed.

| field | box: split | box: agreed, a value | box: agreed, empty | folder: split | folder: agreed, a value | folder: agreed, empty | odd one out: Qwen3-VL 8B / Qwen3.5 4B / Gemini 3.7 Flash / no two agree |
|---|---|---|---|---|---|---|---|
| What the photo is | 13 | 95 | 0 | 16 | 94 | 0 | 9 / 4 / 9 / 7 |
| Repository | 45 | 41 | 22 | 19 | 6 | 85 | 3 / 23 / 33 / 5 |
| Place | 23 | 0 | 85 | 9 | 0 | 101 | 0 / 22 / 3 / 7 |
| Collection title | 37 | 57 | 14 | 26 | 5 | 79 | 14 / 28 / 14 / 7 |
| Collection number | 36 | 37 | 35 | 26 | 8 | 76 | 13 / 21 / 24 / 4 |
| Accession | 20 | 6 | 82 | 8 | 0 | 102 | 6 / 9 / 8 / 5 |
| Series | 24 | 12 | 72 | 12 | 5 | 93 | 6 / 9 / 19 / 2 |
| Container (box, carton…) | 18 | 84 | 6 | 20 | 24 | 66 | 4 / 16 / 15 / 3 |
| Folder number | 7 | 1 | 100 | 38 | 20 | 52 | 10 / 3 / 22 / 10 |
| Folder title | 18 | 0 | 90 | 73 | 20 | 17 | 20 / 9 / 23 / 39 |

## What the photos are, where all three agree

| reading | box (Red) | folder (Purple) |
|---|---|---|
| box label | 90 | 0 |
| folder label | 4 | 89 |
| divider or other | 0 | 1 |
| document page | 1 | 4 |
| no answer | 0 | 0 |
| disputed | 13 | 16 |

## The owner's sheet

184 photos carry at least one split field, 488 split fields in all; 34 photos are unanimous on every field. The sheet adds 20 unanimous fields as unmarked controls (10 with a value, 10 agreed empty), so it asks 508 fields on 188 photos. Boxes (fields other than what the photo is): 366 from the Vision lines matching a reading, 106 from a reader's label region, 3 with no box (the sheet says so). The sheet is `pool-jpeg/sheet/index.html` in the cache (private: corpus images); its answers fold into `pool-jpeg/truth.jsonl` with `ct_truth.py fold`, which records the fields the owner ruled and how many controls the owner overturned.

## Beside the PDF build

On the 164 markers both builds read: Qwen3-VL 8B gave the same reading from the JPEG as from the PDF on 1559 of 1640 fields (95%). Of the 1259 fields the two Qwen readers agreed on from the PDFs, 1104 are unanimous among the three readers on the JPEGs, 1099 with the same value; the rest now go to the owner.

## The drafters W47.ct-read may not score

Qwen3-VL 8B, 4-bit MLX, Qwen3.5 4B, 4-bit MLX, Gemini 3.7 Flash (Stanford gateway, low reasoning) drafted this truth. W47.ct-read scores any of them only on the fields the owner ruled (the fold's `ruled`: the split fields and the controls answered); on the rest a figure is agreement with the drafters, and is reported as that (measurement audit FLD-9).

## Cost

Qwen3-VL 8B, 4-bit MLX: 218 photos, 9.2 s a photo on average, 33 min in all. Qwen3.5 4B, 4-bit MLX: 218 photos, 6.3 s a photo on average, 23 min in all. $0.

Gemini 3.7 Flash (Stanford gateway, low reasoning): 218 calls, $0.44 real money on the Stanford gateway (the gateway's own figure $0.4365 on 218 of 218 calls, 1.00 times the estimate on them), against the owner's approval of about $0.70.

## Measurement card

- **Truth:** none yet. This is a draft for the owner's sheet: unanimous fields go in unchecked except the 20 controls, split fields wait for the owner's ruling. The three drafters are named above.
- **Selection:** the PDF build's stratified draw by repository from the Finder tags (no tested route, no ABBYY text), less the markers with no confirmed JPEG; refills come from the same strata. The cut's losses are not random (see the sample), and they fall mostly on Red.
- **Comparison:** the same JPEG, prompt and settings for all three readers.
- **Noise:** a single pass at temperature 0; no rerun floor. The counts above describe this sample, not the corpus.
- **Scope:** reports agreement only; says nothing about which reader is right until the sheet is answered and W47.ct-read scores it.
