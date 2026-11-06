# Sending places: the owner sheet on what the place rule keeps and empties (W46.place-rule-sheet)

Built by `ArchiveProcessor/scripts/segbench/ent_place_sheet.py sheet`, offline and $0. The sheet and its key stay in the bench cache (`ent-truth/place-sheet/`); this page has counts only. Measurement review 2026-11-05 pass 11, P11-3; W46.place-rule-fold folds the answers once the gate W46.place-rule-fold-owner-ok is ticked.

20 questions on 20 documents, about 11 minutes by the sheets' usual allowance (20 s a document, 12 s a question; one place a document, so likely less). 0 pages are shown turned upright; the owner's date tags are listed on 20.

| class | documents in the pool | drawn | drawn with a box on the page |
|---|---|---|---|
| kept, in a heading or address | 49 | 12 | 11 |
| emptied by the rule | 26 | 8 | 4 |

The emptied pool by what `place_kind` found: inferred 24, institution name 2; drawn: heading or address 12, inferred 7, institution name 1.

## Measurement card

- **Truth**: the owner's answers, when he gives them; the key carries the truth as it stands (his first answers and the rule) beside each question, for the fold only.
- **Selection**: a seeded shuffle of each pool (seed 4651), the first 12 kept and 8 emptied; the places the owner settled or left open are in neither pool. No route's reading and no ABBYY text chose them; the class is `place_kind`'s, the heuristic being measured.
- **Comparison**: none yet; the fold restates the tagging and entity arms of `ent-place-rule.md` on the owner-checked rows and on the rest.
- **Noise**: 12 and 8 documents give each class's error with a wide Wilson interval (one wrong in 12 is 1% to 35%); enough to tell a class that is mostly right from one that is not, not to rank routes.
- **Scope**: one place a document (the first kept heading-or-address place, or the first emptied one); the other places of a document and the dateline and image classes are not drawn. The 138 correspondence documents of W46.fix-ent-truth only.
