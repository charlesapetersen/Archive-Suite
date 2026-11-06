# Item fields: the second owner sheet, a random draw from the image prompt (W47.item-fields-more-checks)

Built by `ArchiveProcessor/scripts/segbench/item_fields_more.py sheet`, offline and $0. The sheet and its key stay in the bench cache (`item-fields-retruth/sheet2/`); this page has counts only.

195 questions on 94 documents (base 71, clippings 23, handwritten 0), about 70 minutes. 0 pages are shown turned upright. The not-asked line carries the entity truth on 41 documents and the owner's date tags on 86.

| field | owner-checked with a true value now | eligible, the image prompt filled | eligible, empty | drawn filled | drawn empty |
|---|---|---|---|---|---|
| kind | 38 | 254 | 0 | 3 | 0 |
| title | 20 | 133 | 130 | 25 | 10 |
| byline | 15 | 72 | 32 | 32 | 10 |
| publication | 21 | 70 | 191 | 24 | 10 |
| publication_date | 17 | 74 | 30 | 29 | 10 |
| recipient_place | 15 | 46 | 84 | 32 | 10 |

A field draws ceil((40 - n) / 0.8) of its filled pairs, so that some wrong readings and "can't tell" answers still leave 40, and 10 empty pairs for recall (kind is always filled).

## Measurement card

- **Truth**: the owner's answers, when he gives them; until then the questions carry the folded truth (W47.item-fields-retruth-score) in the key, for the score item only.
- **Selection**: one seeded shuffle of the documents (seed 4750); each field takes the first eligible documents in it, a uniform draw from that field's pairs the owner has not settled, split by whether the image prompt (Gemini 3.7, drafter A) gave a value. No other route and no ABBYY text chose them. Documents with a page read sideways are out, as in the score.
- **Comparison**: none yet; the score item folds both sheets and scores every route on the same pairs.
- **Noise**: the filled draw alone is about 25-32 a field, so its precision is reported with its Wilson interval. The floor of 40 counts the first sheet's checked pairs too, but those lean to the hard cases, so the fill verdict weighs each part at its share (a stratified precision, measurement review pass 11, P11-2; W47.item-fields-more-score), not the pooled count; kind's 3 drawn pairs cannot carry its pool, so a third sheet continues the draw.
- **Scope**: the draw is over the image prompt's readings, so it measures that route's precision directly; the other routes gain owner-checked pairs but not a draw over their own values. The first sheet's pairs lean to the hard cases; the score item should report the random draw apart as well.
