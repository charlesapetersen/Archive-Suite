# Container labels: the truth set's two-reader draft (W47.ct-truth)

Written by `scripts/segbench/ct_truth.py compare`. 240 marker photos from the corpus (read-only; pages copied as JPEG at 1280 px), stratified by repository (floor 2, then by the square root of each repository's marker count, round-robin across collection directories, seed 4701). Each was read blind into the nine fields of `execution-plans/containers/00-plan.md` plus what the photo is, by Qwen3-VL 8B, 4-bit MLX and Qwen3.5 4B, 4-bit MLX (this Mac, temperature 0, $0, no plan route). A field is agreed when both readings match after case, punctuation and "Box No." spellings are normalised; both empty counts as agreed. Agreement is not truth: two readers can make the same miss, and the owner sees only the disputes.

Drafted by both: 240; a reply that did not parse: 0. Apple Vision lines for the sheet's boxes: 237 photos.

## Strata in the sample

A stratum is the repository's directory, except under a workflow folder, where the level below it is a priority folder or Re-OCR and the corpus has no repository level (marked *workflow*).

| stratum | box (Red) | folder (Purple) |
|---|---|---|
| 5 Priority 5 (*workflow*) | 4 | 4 |
| American Jewish Committee Archives | 1 | 1 |
| Babbage | 6 | 5 |
| Bancroft Library | 2 | 2 |
| Cambridge | 1 | 2 |
| Center for Jewish History | 2 | 2 |
| Chicago, University of, Archives | 5 | 5 |
| Columbia University | 2 | 2 |
| Computer History Museum | 4 | 4 |
| HBS | 5 | 6 |
| Harvard Law School | 2 | 2 |
| Harvard University Archives | 12 | 15 |
| Hoover Institute | 11 | 7 |
| Huntington Library | 4 | 4 |
| London School of Economics | 2 | 0 |
| NARA | 3 | 2 |
| NYPL | 3 | 2 |
| Northwestern | 2 | 2 |
| Othmer | 3 | 2 |
| Re-OCR (*workflow*) | 1 | 2 |
| San Jose State | 2 | 2 |
| Stanford University Archives | 9 | 8 |
| Stanford University Archives — Tech | 11 | 16 |
| Swarthmore Archives | 2 | 2 |
| UC Santa Cruz | 2 | 2 |
| UIUC | 2 | 2 |
| UNLV | 2 | 2 |
| USC | 11 | 10 |
| Wisconsin Historical Society | 4 | 5 |

## Agreement per field

Disputed / with a value from both readers agreed / both empty, out of the photos both drafted.

| field | box: disputed | box: agreed, a value | box: agreed, empty | folder: disputed | folder: agreed, a value | folder: agreed, empty |
|---|---|---|---|---|---|---|
| What the photo is | 12 | 108 | 0 | 14 | 106 | 0 |
| Repository | 25 | 77 | 18 | 39 | 13 | 68 |
| Place | 18 | 9 | 93 | 32 | 0 | 88 |
| Collection title | 32 | 75 | 13 | 47 | 4 | 69 |
| Collection number | 32 | 48 | 40 | 39 | 7 | 74 |
| Accession | 20 | 7 | 93 | 22 | 0 | 98 |
| Series | 17 | 18 | 85 | 20 | 7 | 93 |
| Container (box, carton…) | 14 | 98 | 8 | 26 | 27 | 67 |
| Folder number | 8 | 1 | 111 | 34 | 19 | 67 |
| Folder title | 18 | 5 | 97 | 67 | 30 | 23 |

## What the photos are, where both readers agree

| reading | box (Red) | folder (Purple) |
|---|---|---|
| box label | 98 | 5 |
| folder label | 6 | 91 |
| divider or other | 0 | 4 |
| document page | 4 | 6 |
| no answer | 0 | 0 |
| disputed | 12 | 14 |

## The owner's sheet

176 photos carry at least one dispute, 536 disputed fields in all, 64 photos fully agreed. Boxes on the sheet (fields other than what the photo is): 313 drawn from the Vision lines matching a reading, 150 from a reader's label region, 47 with no box (the sheet says so). The sheet is `pool/sheet/index.html` in the cache (private: corpus images); its answers fold into `pool/truth.jsonl` with `ct_truth.py fold`.

## Cost

Qwen3-VL 8B, 4-bit MLX: 240 photos, 9.7 s a photo on average, 39 min in all. Qwen3.5 4B, 4-bit MLX: 240 photos, 6.5 s a photo on average, 26 min in all. $0.
