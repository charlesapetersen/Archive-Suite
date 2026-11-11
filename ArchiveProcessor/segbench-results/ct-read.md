# Container labels and folder trees: the routes scored per field (W47.ct-read)

Written by `scripts/segbench/ct_read.py report`. The truth is W47.ct-truth-final's (`ct-truth-final.md`): 195 box and folder marker photos (its 196 less the one the owner's third-sheet note drops). Label values stay in the cache; this page gives counts only.

## The routes

- **Apple Vision + parser:** the app's Vision settings (accurate, language correction), the truth build's lines on the upright photo, and a pattern parser written in `ct_read.py` from the plan's list of label forms. The marker's colour gives the kind (the companions' Box or Folder button). The parser was written before its first score and is scored as written.
- **Gemma 3 12B, 4-bit MLX** on this Mac, which drafted none of the truth, read blind with the final reading rules and a prompt whose every example is invented. Scored on every cell.
- **The truth's three drafters** (Qwen3-VL 8B, Qwen3.5 4B, Gemini 3.7 Flash) are scored only on the owner's own cells, less their prompt's example fields (FLD-9). Those are the cells the three disagreed on, so the figures are on the hard cells, not a fair whole-set score.
- **Not run:** the corpus PDFs' text layer (owner, 2026-10-30: no arm takes the ABBYY text as input; the item, filed on 2026-10-21, named it) and any plan route (root CLAUDE.md). The gateway arm is W47.ct-read-paid.

Cells scored: 838 the owner's, 1705 the three readers' unanimous, 159 settled by the owner's rules (reported apart, P11-7). Out of every score: 9 carried, 4 cut off, 14 the blurred photo, 1 unanswered or open.

## Per field: the two routes that drafted nothing

On the owner's and the unanimous cells. Accuracy with its 95% interval and the cell count; then, of the cells with a value, how many were read right, and of the empty ones, how many the route filled. The gap is Gemma 3 12B, 4-bit MLX less Vision on the same cells, with a 95% bootstrap interval over photos; an interval across zero is a tie.

| field | Vision + parser | right of filled | filled when empty | Gemma 3 12B, 4-bit MLX | right of filled | filled when empty | gap |
|---|---|---|---|---|---|---|---|
| What the photo is | 99% (96–100), n 194 | 192/194 | 0/0 | 78% (72–84), n 194 | 152/194 | 0/0 | -20 (-26 to -14) |
| Repository | 74% (67–79), n 189 | 33/78 | 5/111 | 80% (74–86), n 189 | 49/78 | 8/111 | +7 (+1 to +13) |
| Collection title | 55% (48–63), n 175 | 26/102 | 2/73 | 71% (64–77), n 175 | 54/102 | 3/73 | +16 (+9 to +22) |
| Collection subtitle | 97% (94–99), n 156 | 0/4 | 0/152 | 89% (83–93), n 156 | 0/4 | 13/152 | -8 (-13 to -4) |
| Collection number | 71% (65–77), n 189 | 31/85 | 0/104 | 82% (76–87), n 189 | 53/85 | 2/104 | +11 (+4 to +18) |
| Accession | 95% (91–97), n 191 | 2/12 | 0/179 | 89% (84–93), n 191 | 3/12 | 12/179 | -6 (-10 to -2) |
| Series | 92% (88–95), n 194 | 14/29 | 0/165 | 93% (89–96), n 194 | 17/29 | 1/165 | +1 (-2 to +4) |
| Series title | 97% (93–98), n 188 | 9/14 | 1/174 | 97% (94–99), n 188 | 13/14 | 4/174 | +0 (-3 to +4) |
| Container (box, carton…) | 79% (73–84), n 194 | 98/137 | 2/57 | 82% (76–87), n 194 | 103/137 | 1/57 | +3 (-3 to +9) |
| Box title | 85% (78–90), n 157 | 0/24 | 0/133 | 69% (61–76), n 157 | 4/24 | 29/133 | -16 (-22 to -9) |
| Folder number | 87% (81–91), n 194 | 27/50 | 3/144 | 82% (76–87), n 194 | 22/50 | 7/144 | -4 (-10 to +2) |
| Folder title | 56% (48–62), n 182 | 14/87 | 8/95 | 60% (53–67), n 182 | 18/87 | 4/95 | +4 (-2 to +10) |
| Date or time period | 72% (66–78), n 188 | 44/80 | 16/108 | 80% (74–85), n 188 | 52/80 | 9/108 | +8 (+2 to +14) |
| Other identifying marks | 75% (68–81), n 152 | 0/38 | 0/114 | 49% (42–57), n 152 | 12/38 | 51/114 | -26 (-36 to -17) |

### On the rule-settled cells, apart

| field | Vision + parser | Gemma 3 12B, 4-bit MLX |
|---|---|---|
| Collection title | 100% (80–100), n 15 | 100% (80–100), n 15 |
| Collection subtitle | 100% (91–100), n 38 | 90% (76–96), n 38 |
| Collection number | 100% (57–100), n 5 | 100% (57–100), n 5 |
| Accession | 100% (44–100), n 3 | 100% (44–100), n 3 |
| Series title | 100% (61–100), n 6 | 67% (30–90), n 6 |
| Box title | 100% (91–100), n 37 | 70% (54–82), n 37 |
| Folder title | 100% (68–100), n 8 | 88% (53–98), n 8 |
| Date or time period | 83% (44–97), n 6 | 83% (44–97), n 6 |
| Other identifying marks | 100% (91–100), n 41 | 37% (24–52), n 41 |

## Per field: the owner's own cells, every route

The cells the three drafters split on, which the owner ruled: the hard cells. Every route on the same cells, less each row's prompt-example fields for the drafters.

| field | Apple Vision (accurate) + parser | Gemma 3 12B, 4-bit MLX | Qwen3-VL 8B, 4-bit MLX | Qwen3.5 4B, 4-bit MLX | Gemini 3.7 Flash (Stanford gateway, low reasoning) |
|---|---|---|---|---|---|
| What the photo is | 98% (92–100), n 64 | 52% (40–63), n 64 | 62% (50–73), n 64 | 23% (15–35), n 64 | 91% (81–96), n 64 |
| Repository | 34% (24–47), n 64 | 55% (43–66), n 64 | 39% (27–52), n 57 | 33% (22–46), n 57 | 93% (83–97), n 57 |
| Collection title | 41% (31–52), n 78 | 53% (42–63), n 78 | 64% (53–74), n 78 | 46% (36–57), n 78 | 73% (62–82), n 78 |
| Collection subtitle | 90% (74–96), n 30 | 60% (42–75), n 30 | 67% (49–81), n 30 | 43% (27–61), n 30 | 63% (46–78), n 30 |
| Collection number | 46% (34–57), n 68 | 65% (53–75), n 68 | 43% (32–55), n 65 | 65% (52–75), n 65 | 77% (65–86), n 65 |
| Accession | 74% (57–85), n 34 | 59% (42–74), n 34 | 74% (57–85), n 34 | 76% (60–88), n 34 | 91% (77–97), n 34 |
| Series | 69% (53–82), n 36 | 72% (56–84), n 36 | 74% (57–85), n 34 | 56% (40–71), n 34 | 76% (60–88), n 34 |
| Series title | 73% (43–90), n 11 | 91% (62–98), n 11 | 100% (68–100), n 8 | 25% (7–59), n 8 | 62% (31–86), n 8 |
| Container (box, carton…) | 62% (49–72), n 65 | 57% (45–68), n 65 | 56% (43–69), n 55 | 46% (33–58), n 55 | 84% (72–91), n 55 |
| Box title | 53% (39–67), n 47 | 43% (30–57), n 47 | 38% (25–52), n 45 | 24% (14–39), n 45 | 82% (69–91), n 45 |
| Folder number | 64% (51–75), n 58 | 50% (38–62), n 58 | 42% (29–56), n 50 | 36% (24–50), n 50 | 84% (72–92), n 50 |
| Folder title | 20% (13–29), n 92 | 24% (16–34), n 92 | 21% (14–30), n 92 | 10% (5–18), n 92 | 38% (29–48), n 92 |
| Date or time period | 47% (36–58), n 75 | 60% (49–70), n 75 | 49% (38–60), n 74 | 65% (54–75), n 74 | 86% (77–92), n 74 |
| Other identifying marks | 71% (62–78), n 116 | 41% (33–50), n 116 | 37% (29–46), n 114 | 22% (15–30), n 114 | 51% (42–60), n 114 |

Paired gaps on the owner's cells, each drafter less Gemma 3 12B, 4-bit MLX (95% bootstrap over photos):

| field | Qwen3-VL 8B, 4-bit MLX | Qwen3.5 4B, 4-bit MLX | Gemini 3.7 Flash (Stanford gateway, low reasoning) |
|---|---|---|---|
| What the photo is | +11 (-5 to +27) | -29 (-43 to -14) | +39 (+27 to +52) |
| Repository | -14 (-28 to -2) | -20 (-36 to -4) | +40 (+28 to +54) |
| Collection title | +12 (+0 to +22) | -6 (-21 to +8) | +20 (+9 to +32) |
| Collection subtitle | +7 (-13 to +27) | -17 (-45 to +10) | +3 (-17 to +23) |
| Collection number | -20 (-34 to -6) | +2 (-16 to +17) | +14 (-3 to +29) |
| Accession | +15 (-6 to +35) | +18 (+0 to +36) | +32 (+18 to +47) |
| Series | +3 (-6 to +12) | -15 (-33 to +0) | +6 (-9 to +21) |
| Series title | +12 (+0 to +38) | -71 (-100 to -43) | -25 (-62 to +25) |
| Container (box, carton…) | +0 (-11 to +11) | -11 (-24 to +2) | +28 (+13 to +43) |
| Box title | -4 (-20 to +11) | -18 (-39 to +2) | +40 (+24 to +56) |
| Folder number | -10 (-29 to +8) | -17 (-31 to -4) | +31 (+12 to +49) |
| Folder title | -3 (-13 to +6) | -14 (-23 to -7) | +14 (+2 to +26) |
| Date or time period | -11 (-26 to +5) | +4 (-11 to +19) | +27 (+16 to +38) |
| Other identifying marks | -4 (-15 to +9) | -20 (-30 to -10) | +10 (-3 to +23) |

Replies that did not parse: Apple Vision (accurate) + parser 0, Gemma 3 12B, 4-bit MLX 1, Qwen3-VL 8B, 4-bit MLX 0, Qwen3.5 4B, 4-bit MLX 1, Gemini 3.7 Flash (Stanford gateway, low reasoning) 0.

## Route B: the folder-tree name patterns

On the synthetic tree set (`ct_trees.json`, 36 trees, 180 files in the plan's naming conventions): the pre-filled level map was right for 36 of 36 trees, and per field:

| field | right | cells |
|---|---|---|
| Accession | 100% | 4 |
| Collection number | 100% | 118 |
| Collection title | 100% | 176 |
| Container (box, carton…) | 100% | 180 |
| Folder number | 100% | 152 |
| Folder title | 100% | 12 |
| Repository | 100% | 108 |
| Series | 100% | 22 |

That set was written to the conventions the patterns cover, and the patterns were written after its list of conventions was seen, so a perfect score says the patterns cover the conventions; it is not a measure on a stranger's tree. The owner's own tree is the real case. Its names are informal, so the patterns recognise little of it and the level map rests on the user's confirmation (the design's once-per-root sheet), as the plan expected:

- Level 1 (the tree as listed by W47.ct-truth on 2026-10-29), 40 names over 100,308 PDFs: repository 72,133, unrecognised 19,019, ignore (workflow) 9,156 PDFs (names: ignore 2, repository 18, unrecognised 20).
- Level 2, in PDFs: unrecognised 57,892, collection 27,080, collection, a collection number 10,823, unrecognised, a collection number 2,149, no level 2 1,246, repository 704, ignore 414.

## Carry-forward, on the corpus

Every single-colour marker in the corpus: 1,210 Red and 3,189 Purple in 298 directories (195 with a marker, 180 with a box photo); 1,186 and 3,151 have a paired JPEG original, which is what was read (Vision + parser, at the EXIF turn and then the other three until a number reads).

| what Vision read | photos |
|---|---|
| Purple: box | 188 |
| Purple: box, folder | 521 |
| Purple: no box | 1,782 |
| Purple: no box, folder | 660 |
| Red: box | 914 |
| Red: no box | 271 |
| Red: no box, folder | 1 |

From one box photo to the next in a directory, where both read a box number (724 steps):

| step | count | share |
|---|---|---|
| boxes skipped | 328 | 45% |
| lower number | 199 | 27% |
| next box | 149 | 21% |
| same box again | 48 | 7% |

A folder label that reads a box number (709 Purple photos), against the last box photo before it in its directory:

| folder's box | count | share |
|---|---|---|
| same box as the box photo before it | 417 | 59% |
| folder gives a box, no box photo before it in its directory | 141 | 20% |
| another box than the box photo before it | 112 | 16% |
| folder gives a box, the box photo before it unread | 39 | 6% |

How far a read box number can be trusted: on the truth set, where Vision + parser gives a container it is right on 70 of 71 box photos and 28 of 35 folder photos. A folder giving another box than the box photo before it is a box change with no box photo, or a misread of either photo. Boxes skipped are most likely boxes not requested, not missed photos. Box photos are so rarely misread that a lower number is, nearly always, a box photographed out of numeric order.

## What Purple marks

The truth sample's Purple photos as drawn (110, stratified by repository; the owner's rulings and the photos he took out, with his reason):

| what it is | photos | share |
|---|---|---|
| folder label | 100 | 91% |
| taken out: "don't train on this" | 3 | 3% |
| taken out: "No Folder" sheet | 2 | 2% |
| taken out: "very unusual" | 1 | 1% |
| taken out: "just a document" | 1 | 1% |
| document page | 1 | 1% |
| taken out: early photo, taken a different way | 1 | 1% |
| folder label, unlabelled folder | 1 | 1% |

## Speed and the price of the corpus's markers

The corpus holds 4,399 single-colour markers.
- Vision + parser: the corpus's 4,337 paired markers at the EXIF turn in 12 minutes on this Mac, 0.17 s a photo, rendering the JPEG included; $0. Trying the other turns where no number read roughly doubled it.
- Gemma 3 12B, 4-bit MLX: median 14.93 s a photo (mean 15.06), peak 8.04 GB; the corpus's markers in about 18.4 hours; $0.
- Gemini 3.7 Flash through the gateway (the truth's third reader, for W47.ct-read-paid's price): $0.0023 a photo measured on the truth build's 215 calls, so about $10 for the corpus: over the $7 line, so a full backfill read asks the owner first.

Timings were taken inside an engine session, which macOS runs at background priority; such timings have measured several times slower than an interactive run, so read them as upper bounds.

## What it recommends, per field (for W47.ct-design-ok)

Free routes only; W47.ct-read-paid adds the gateway arm before the design review. On the hard cells the owner ruled, Gemini 3.7 Flash is ahead of every free route on almost every field, but those are the cells where the drafters split, and choosing them favours the strongest drafter rather than handicapping it. The paid arm (W47.ct-read-paid) confirms it on the owner's cells (FLD-9), not on the whole set: Gemini 3.7 co-drafted the 1,705 unanimous cells, so a whole-set figure for it would be agreement with itself.

- **What the photo is:** the marker's colour (the Box or Folder button), right on 192 of 194; no reader is needed, and Gemma's own call is worse.
- **Container and folder number:** Vision + parser. It ties Gemma on both, takes a fraction of the time, and on a box photo the box number it gives is right 70 of 71 times. It misses about a quarter of the box numbers that are there, so the capture card asks when it reads none.
- **Repository, collection title, collection number, date:** Gemma 3 12B, ahead of Vision + parser on each with an interval above zero, but still wrong or empty on a third to a half of the filled cells: proposed values the user confirms once per run, not facts.
- **Series, series title:** Vision + parser; they are anchored by their keyword, and Gemma's difference is a tie.
- **Accession:** not a tie: Gemma less Vision is -6 (-10 to -2), an interval clear of zero. But Vision's lead comes from leaving the field empty: it reads 2 of the 12 accessions present, the same pattern as the fields below, while Gemma fills an accession where there is none (12 of 179).
- **Collection subtitle, box title, other identifying marks, folder title:** no free route reads them. Vision's high accuracy on the first three comes from leaving them empty, and Gemma fills them where there is nothing. Leave them to the user, or to the paid arm if it reads them.
- **Route B:** the name patterns cover every convention the plan names; the owner's informal names need the once-per-root level-map sheet, as designed.
- **Carry-forward:** box photos come in no fixed order. 27% of the steps between box photos go to a lower number, and box photos are rarely misread, so the plan's warning "a box number goes backwards" would fire on about one step in four; it should not be a warning. Nor is a folder label that names its box a check on the run as measured: Vision's box read on folder photos is right on 28 of 35 on the truth set (5 another number, 2 a box where there is none), 7 wrong with a Wilson interval of 0.10 to 0.36. Only 529 folder reads can be compared with a box photo before them, so about 106 misreads (53 to 190) are expected among them, against 112 disagreements observed: a flag on disagreement would mostly fire on misreads.
- **Purple:** a folder label for nearly all of the drawn photos; two were "No Folder" sheets and one a document page. Purple can be taken as a folder start, with "No Folder" sheets recognised by their text.
- **The corpus's markers:** Vision + parser reads them all in minutes for $0, Gemma in most of a day for $0; Gemini would cost about $10, over the $7 line.

## Measurement card

- **Truth:** W47.ct-truth-final's: the owner's answers on three sheets and his notes, his rules applied to the readers' readings (reported apart), and for the rest the three drafters unanimous. Drafters are scored only on the owner's cells, less prompt examples; the routes that drafted nothing on every cell. The truth's checks: 0 of 20 reader-unanimous controls overturned on the second sheet (upper bound about 16%) and 0 of 10 rule-settled ones on the third (about 28%).
- **Selection:** the truth build's stratified draw by repository (square-root allocation, a floor of two), less the photos the owner took out. The pairing cut's lean stands beside every figure here (P10-6): 54 photos left out, 43 of them Red, toward little-changed PDFs. The sample is not weighted to the corpus, so a figure is the sample's.
- **Comparison:** every route on the same upright photos; Vision lines are the truth build's (the reread photos' own lines for the 15 reread). Same cells for every paired gap.
- **Noise:** one pass at temperature 0; Wilson intervals on each figure, bootstrap intervals over photos on each gap; no rerun floor was measured, so a gap near zero is a tie.
- **Scope:** the routes on this sample of one researcher's photos; the tree patterns on a synthetic set and the owner's names; carry-forward measured with Vision's own misreads mixed in. It settles no design: that is W47.ct-design-ok. The carry-forward's 70 of 71 box-number precision is on the truth set's upright photos, while 60 of the 916 Red reads on the corpus came from another turn than the EXIF one, which the truth set does not test.

The Vision parser's score is its first pass (`score-vision-firstpass.json` in the cache).
