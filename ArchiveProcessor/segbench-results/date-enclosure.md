# Dating: the enclosure marker and a relation classifier (W46.date-enclosure)

Written by `scripts/segbench/date_enclosure.py score`. The first measurement of the app's `[enclosure]` marker (10-gap-audit.md §5 item 15, B-dating.md §3). All arms $0: local models on this Mac and Qwen3.6-27B on Sherlock; no plan route (CLAUDE.md, "Plan routes wait for the gateway"); the Gemini arm is W46.date-enclosure-paid. The set and the replies stay private in the bench cache (`date-tagging/enclosure/`); this page carries counts only.

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
| [enclosure] marker, app OCR prompt, Qwen3-VL 8B, 4-bit MLX | 0 | 0 | 3 | 12 | 0 | – | 0 of 3 | 0 of 2 |
| relation classifier, the trained 2B date model, 8-bit MLX | 0 | 0 | 3 | 12 | 0 | – | 0 of 3 | 0 of 2 |
| relation classifier, Qwen3.6-27B, thinking off (Sherlock, one L40S) | 1 | 1 | 2 | 11 | 0 | 1 of 2 | 1 of 3 | 1 of 2 |

## The structural proxy: how often each arm proposes a relation

Rates with Wilson 95% intervals. A good relation detector fires more on A and A' than on the matched negatives; how much more is the most this set can show without more owner truth.

| arm | A | A' | neg | AUC, A and A' against neg | seconds a document |
|---|---|---|---|---|---|
| cue words in the cover's last 600 characters (rule) | 1 of 60 (1.7%, 0-9) | 3 of 45 (6.7%, 2-18) | 4 of 105 (3.8%, 2-9) | 0.5 | – |
| cue words anywhere in the cover (rule) | 8 of 60 (13.3%, 7-24) | 6 of 45 (13.3%, 6-26) | 25 of 105 (23.8%, 17-33) | 0.448 | – |
| [enclosure] marker, app OCR prompt, Qwen3-VL 8B, 4-bit MLX | 0 of 60 (0.0%, 0-6) | 0 of 45 (0.0%, 0-8) | 0 of 105 (0.0%, 0-4) | 0.5 | 9.63 |
| relation classifier, the trained 2B date model, 8-bit MLX | 0 of 60 (0.0%, 0-6) | 0 of 45 (0.0%, 0-8) | 0 of 105 (0.0%, 0-4) | 0.48 | 1.57 |
| relation classifier, Qwen3.6-27B, thinking off (Sherlock, one L40S) | 2 of 60 (3.3%, 1-11) | 1 of 45 (2.2%, 0-12) | 1 of 105 (1.0%, 0-5) | 0.674 | – |

## Propagation

For each proposal, whether the cover prints a year (the rule pick of `date_traceable.py`) and whether that year, which the app would write as Sent With and as the Year tag with Date Uncertain, is the owner's year.

| arm | proposals on A, A' and owner | cover dated | year right | proposals on neg | year right on neg | neg proposals whose cover announces anything |
|---|---|---|---|---|---|---|
| cue words in the cover's last 600 characters (rule) | 5 | 2 | 1 | 4 | 0 | 4 of 4 |
| cue words anywhere in the cover (rule) | 15 | 10 | 7 | 25 | 0 | 4 of 25 |
| [enclosure] marker, app OCR prompt, Qwen3-VL 8B, 4-bit MLX | 0 | 0 | 0 | 0 | 0 | – |
| relation classifier, the trained 2B date model, 8-bit MLX | 0 | 0 | 0 | 0 | 0 | – |
| relation classifier, Qwen3.6-27B, thinking off (Sherlock, one L40S) | 5 | 4 | 4 | 1 | 0 | 0 of 1 |

## Replies

- [enclosure] marker, app OCR prompt, Qwen3-VL 8B, 4-bit MLX: line 1 classified as document_continuation 53, document_start 171, folder_label 1.
- relation classifier, Qwen3.6-27B, thinking off (Sherlock, one L40S): a cue quoted on 6 of 6 yes replies; the quote found in the documents as sent on 5 of 6.

## Findings

- The marker, on the local route: Qwen3-VL 8B 4-bit, given the app's exact OCR prompt (compiled from `OCRPrompt.swift`), wrote `[enclosure]` on none of the 225 pages, including none of the owner's 3 confirmed enclosures. On the Mac route the app therefore proposes no relation at all: recall 0 of 3, precision undefined. It also called 53 of the 225 tag-rule document starts continuations (owner 8 of 15, A 19 of 60, A' 12 of 45, negatives 14 of 105), and the marker can only stand on a start; one of the 3 enclosures (a10) was among them.
- The trained 2B as a relation classifier answered false on all 225, with an AUC of 0.48 for its confidence on A and A' against the negatives: no signal. Its cue is often a sentence of the prompt rather than of either document. It was trained to date documents, not to relate them, so this measures the shipped model's reach, not what a small model could learn (R7's fine-tune on the A-D truth).
- Cue words are not a relation signal on this material. Read in the cover's last 600 characters they fire on 1.7% of A, 6.7% of A' and 3.8% of the negatives; read anywhere in the cover, 13.3%, 13.3% and 23.8%, more on the negatives than on A and A' (AUC 0.45). None of the owner's 3 enclosures is announced in its cover's tail. This fits the owner's answers: most strict-class documents are not enclosures (date-truth-sets.md), so a cover that says "I enclose" is usually followed by something other than what it enclosed, or by nothing.
- Qwen3.6-27B (FP8, thinking off, one L40S on Sherlock, job 49088017; 225 pairs in 151 s at 32 at a time, after 201 s to start the server) is the only free arm that proposes a relation, and it does so rarely: 2 of 60 A, 1 of 45 A' and 1 of 105 negatives, AUC 0.67 for its confidence. On the owner's 15 it found 1 of the 3 enclosures (a22, quoting the enclosed document's own heading) and wrote one false Sent With (a25, a reply that discusses the draft it answers rather than enclosing it); precision 1 of 2 is a count, not a rate. Every yes quoted a cue, and the cue was in the documents on 5 of 6. Of its 5 proposals on A, A' and the owner's set, 4 covers print a year and all 4 are the owner's year; its one negative proposal would have written a wrong year. 43 of its 225 replies quoted two cues unjoined (not valid JSON); all were false verdicts, and `parse_relate` reads their verdict rather than counting them as no reply.
- The limit is the truth, not the arms: 3 owner-confirmed enclosures cannot give a precision for any arm that fires, and the structural classes are not relation truth. Still to run: the Gemini arm with images (W46.date-enclosure-paid). For the app now: on local routes the marker is inert, so `Sent With` is never proposed there, and nothing the free arms showed argues for proposing it by rule instead. A 27B relation pass is conservative enough not to hurt (one wrong Sent With among the 105 negatives and one among the owner's 12 noes) but finds too little to be worth a stage of its own on a laptop route, where it cannot run anyway.
