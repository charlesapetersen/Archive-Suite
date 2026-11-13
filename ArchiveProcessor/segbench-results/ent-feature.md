# The entity feature's prompt, evidence check and gate (W46.ent-feature)

The Processor's entity feature (EntityExtractor.swift) sends the dedicated entity prompt with the sending-place rule on the first 3,000 characters, byte for byte the prompt of W46.ent-place-rule-paid's entity3k-place arm, so its figures here are those cached replies (Gemini 3.7 Flash, Vision text, 138 correspondence documents, 138 parsed) scored on the truth as it now stands. `python3 ArchiveProcessor/scripts/segbench/ent_feature.py report`.

## Scores (ed2 F1)

| arm | n | sender | recipient | place P / R / F1 | place by city |
|---|---|---|---|---|---|
| entity prompt | 138 | 0.69 | 0.88 | 0.83 / 0.76 / 0.80 | 0.88 |
| entity prompt behind the gate | 138 | 0.69 | 0.87 | 0.83 / 0.75 / 0.79 | 0.88 |

## The correspondence gate

The app has no correspondence classifier, so the feature runs where the tagging call's `format` is one of letter, memo, memorandum, telegram, cable, cablegram, postcard, telex. On the 138 the cached tagging replies (the app's reverted prompt) pass 134/138 (97%); formats {'letter': 88, 'memo': 45, 'telegram': 1, 'brochure': 1, 'newspaper article': 1, 'report': 1, 'leaflet': 1}. The documents it stops carry 3 named senders, which the gated row above counts as missed.

## The evidence check

Each name's quote is looked for in the document's own text (the 3,000 characters sent; whitespace folded, case ignored; at edit distance 2 when the quote has five letters or more). Right and wrong at ed2 against the truth's named entries; a name matching only a role- or correspondence-inferred truth entry is counted apart.

| field | class | right | wrong |
|---|---|---|---|
| sender | read, distance 0 | 85 | 27 |
| sender | read, distance 0 (truth inferred) | 1 | 0 |
| recipient | inferred: no quote (truth inferred) | 1 | 0 |
| recipient | read, distance 0 | 148 | 16 |
| recipient | read, distance 0 (truth inferred) | 2 | 0 |
| sending_place | read, distance 0 | 55 | 11 |

## The inside address

Places written: 66, of which 66 are read by the check. Quoted from the recipient's inside address (after a recipient's quote and before the salutation): 5, 5 right and 0 wrong against the truth.

## Non-correspondence

21 of the entity set's 21 non-correspondence documents read (Vision text from their JPEG originals, read for this item) and sent to both prompts, $0.0940. The tagging call's formats: {'memo': 4, 'newsletter': 3, 'newspaper article': 2, 'magazine article': 2, 'report': 2, 'minutes': 1, 'campaign material': 1, 'transcript': 1, 'speech': 1, 'pamphlet': 1, 'routing slip': 1, 'magazine': 1, 'diagram': 1}. The gate lets 4 through. Entity replies unparsed: 0.

| field | documents with a name, all | names read by the check, all | with a name, behind the gate | read, behind the gate |
|---|---|---|---|---|
| sender | 5 | 6 | 1 | 1 |
| recipient | 2 | 2 | 0 | 0 |
| sending_place | 2 | 3 | 0 | 0 |

## Reading

- **The prompt ships as measured.** The app's prompt is the entity3k-place prompt byte for byte (`report` asserts it
  for each of the 138, `test_ent_feature` against the Swift literal), so its figures are sender 0.69, recipient 0.88,
  place 0.80 and 0.88 by city. Against the tagging call with both November rules, the arm the old route row describes,
  every field is a tie (`ent-place-rule.md`: sender +0.04 [-0.00, +0.08] for the tagging call, recipient -0.06
  [-0.13, +0.00], place -0.07 [-0.17, +0.02], city +0.00); the rerun floor of this prompt is sender +0.00, recipient
  +0.01, place -0.03 [-0.22, +0.16] on 40.
- **The sender convention.** Owner call 10 left it to this prompt: "a person, or the issuing organisation when no
  person is named", the truth's own convention. On non-correspondence it rarely fires: across the 21 documents the
  entity prompt names a sender on 5, and on the 4 the gate lets through (all called "memo" by the tagging call) on 1.
- **The gate.** With no correspondence classifier in the app, the tagging call's `format` decides: 134 of the 138
  correspondence documents pass, the 4 it stops carry 3 named senders, and the gated scores move by at most 0.01. It
  lets 4 of 21 non-correspondence documents through.
- **Evidence.** Every name the prompt returned on the 138 carried a quote the check finds exactly in the text; none
  needed the edit-distance allowance and none was inferred. Read names are right 85 of 112 times on the sender, 148
  of 164 on the recipient and 55 of 66 on the place: a quote proves the words are on the page, not that they are the
  sender (each of the 27 wrong senders is written on the page, but is not the one the truth takes). The inferred path is exercised by the app's test and
  by the earlier arms' unquoted names (`ent-score.md`: 38 of Gemini's 56 unquoted names confirmed by the truth).
- **The inside address.** 5 of the 66 written places are quoted from a recipient's inside address block, and all 5
  are right (0 of 5 wrong, Wilson 0% to 43%): on this set "an address" in the place rule does not pull in the
  recipient's address as the sending place. The bound is loose because the case is rare.
- **Non-correspondence dates.** The entity prompt asks for no date, and the tagging prompt is back to its pre-November
  name lines (W46.tagging-prompt-revert), so the open point about dates under the new lines no longer applies.
- **Cost.** The feature is one more call per correspondence document: $2.37 per 1,000 at Gemini 3.7 Flash's list
  price (the 138 calls' metered tokens), about 58% of the tagging call's $4.07; median 5.1 s through the gateway. Owner
  call 11's "extracted always on a cloud route" was made when the fields came with the tagging call at no cost.

## Measurement card

**Truth.** `ent_truth.load_truth()`: W46.fix-ent-truth (GPT 5.6 Luna and Claude Sonnet 5 drafting, Sonnet ruling 86 documents) with
the owner's answers and the sending-place rule; 138 correspondence documents, 72 named places. The owner overturned 3
of 7 asked rulings (P11-5), so about 2-3% of the fields are wrong in the truth; the 18 rule-emptied places nobody
checked are the weakest rows. No Gemini drafted or ruled, so no scored route is a drafter or a relative of one (as in
`ent-score-paid.md` and `ent-place-rule.md`). The non-correspondence documents have no name truth: their figures are counts, not accuracy.

**Selection.** The entity truth set (W46.fix-ent-truth's 300-document sample and its stratified top-up), chosen before
any route here; never by a tested route or ABBYY text. The 21 non-correspondence documents are that set's own.

**Comparison.** The same Vision text (macOS 27.2) and the first 3,000 characters for every arm; Gemini 3.7 Flash,
temperature 0, 8,192 tokens, through the Stanford gateway; replies keyed by prompt hash and settings. The 21's Vision
text was read for this item from their JPEG originals (or the PDF's image where no pair exists) with the same
`ocr.swift`, without W46.ent-score-paid's pair check by ABBYY words.

**Noise.** n 138 (21 for the non-correspondence counts). Paired 95% bootstrap intervals are `ent-place-rule.md`'s; the
rerun floor of this prompt on 40: sender +0.00, recipient +0.01, place -0.03 [-0.22, +0.16]. The gate's changes (at
most 0.01) are inside that floor.

**Scope.** Gemini 3.7 Flash, not the app's 3.8; Vision text, while on Vision text the app withholds the sender (rule
ent-vision-hands), so the sender figure applies to text a model read, which was not measured here. Not the Mac or
cluster models on this prompt (W46.ent-local-shipped-prompt). Handwritten letters are 5 of the 138. The inside-address
bound rests on 5 cases. Spent $0.094 (42 calls on the 21); the 138's replies were W46.ent-place-rule-paid's.
