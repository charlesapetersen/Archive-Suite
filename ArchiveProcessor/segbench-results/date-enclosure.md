# Dating: the enclosure marker and a relation classifier (W46.date-enclosure)

Written by `scripts/segbench/date_enclosure.py score`. The first measurement of the app's `[enclosure]` marker (10-gap-audit.md §5 item 15, B-dating.md §3). All arms $0: local models on this Mac and Qwen3.6-27B on FarmShare; no plan route (CLAUDE.md, "Plan routes wait for the gateway"); the Gemini arm is W46.date-enclosure-paid. The set and the replies stay private in the bench cache (`date-tagging/enclosure/`); this page carries counts only.

## The set

225 document starts of the agreed pool whose previous segment is a document (a relation never crosses a box or folder label):

- **owner** 15: the owner's relation truth (`date-truth-sets.md`), 3 sent with the previous document and 12 not. Two (a05, d10) are pages of one bound magazine issue, scored also without them.
- **A** 60 and **A'** 45: the strict and chained classes of the owner's 300 and of the pool's stratified 200, outside the owner's 15. Their year matches the document before, but the owner's answers refuted the strict class as covers (2 of 33), so a firing rate here is a structural proxy, not recall.
- **neg** 105: matched non-enclosure starts, one per A/A' candidate, documents printing their own year where the owner gave the document before a different one; 79 from the same collection as their match. A proposal here writes a Sent With the owner did not use.

## Against the owner's truth

| arm | TP | FP | FN | TN | no reply | precision | recall | recall without the bound issues |
|---|---|---|---|---|---|---|---|---|
| cue words in the cover's last 600 characters (rule) | 0 | 1 | 3 | 11 | 0 | 0 of 1 | 0 of 3 | 0 of 2 |
| cue words anywhere in the cover (rule) | 0 | 1 | 3 | 11 | 0 | 0 of 1 | 0 of 3 | 0 of 2 |

## The structural proxy: how often each arm proposes a relation

Rates with Wilson 95% intervals. A good relation detector fires more on A and A' than on the matched negatives; how much more is the most this set can show without more owner truth.

| arm | A | A' | neg | AUC, A and A' against neg | seconds a document |
|---|---|---|---|---|---|
| cue words in the cover's last 600 characters (rule) | 1 of 60 (1.7%, 0-9) | 3 of 45 (6.7%, 2-18) | 4 of 105 (3.8%, 2-9) | 0.5 | – |
| cue words anywhere in the cover (rule) | 8 of 60 (13.3%, 7-24) | 6 of 45 (13.3%, 6-26) | 25 of 105 (23.8%, 17-33) | 0.448 | – |

## Propagation

For each proposal, whether the cover prints a year (the rule pick of `date_traceable.py`) and whether that year, which the app would write as Sent With and as the Year tag with Date Uncertain, is the owner's year.

| arm | proposals on A, A' and owner | cover dated | year right | proposals on neg | year right on neg | neg proposals whose cover announces anything |
|---|---|---|---|---|---|---|
| cue words in the cover's last 600 characters (rule) | 5 | 2 | 1 | 4 | 0 | 4 of 4 |
| cue words anywhere in the cover (rule) | 15 | 10 | 7 | 25 | 0 | 4 of 25 |
