# 13. The solver's profile test cases

The plan's five user profiles (`00-plan.md` §"The user profiles") are not written up as recommendations; they are the
test cases the settings solver must pass when run on `settings-routes.json` with each profile's interview answers
(owner, 2026-11-06). Each stage note's section 9 gives the per-stage expectations with the row and figure that decide
them; this file collects the cross-stage cases, applies the owner's calls of 2026-11-06 (`14-owner-calls.md`), and adds
the router cases the integration plan's stage 4 asked for. `W46.settings-solver` turns each case into a test; a case
marked "pending" names the item whose figure it waits for and is a skipped test until then.

Conventions: answers are the general and collection interviews' (`12-settings-design.md` §3.1-3.2); the mix is the
owner's 96 (typewritten 50, printed 28, handwritten 16) unless named; ceiling none, hours 8, preference "best
measured", priorities reading, finding documents, dates, names unless named; ties under each stage's `noise.tie` go to
the cheaper route, judged against the best feasible route only, faster wins among equal cost, no chaining (note 04 call
7.7). For reading the tie is the floor alone (owner, 2026-11-11): the pair's paired gap in `ocr-pair-matrix.json` under
its floor (0.49 hosted or cluster, 0.00 between Mac routes, per kind 0.42, 0.24, 0.60), the interval shown but making
no tie; on the 895 a pick takes the stratum's leader. A pick names the row id in the stage note's section 4; a reading
pick also names its pair entry (W46.pairs-redecide).

## A. Skipped interviews (owner call 3)

Answers: none; the Mac's memory and the Keychain are read. Expected: the "Free, on this Mac" fill whatever keys are
detected; detected keys and plans listed on the sheet, none spent. Picks: as case B1 for the Mac's memory. Mixed
switch off; straighten on; the reading-copy and OCR-input rules of notes 01 and 02; no entity extraction on the Mac
until names are ranked.

## B. A laptop only, open weights

**B1. 16 GB, no key, no plan, no cluster, downloads allowed.**
- Reading (note 04 §9 profile 1, owner call 4): typewritten and printed `apple-vision` (92.18, 80.54 strict; about 1 s a
  page); handwritten `lightonocr-3-4b-mlx8` offered as a download (hands16 89.91; 6.4 GB peak, 23.8 s a page); a page
  Vision returns empty for is flagged. With downloads declined: handwritten pages flagged "needs a download or a key",
  never read at 60.
- Cascade: `casc-free-fail` only once a Mac escalation stage exists (pending the cascade rows' Mac memory per tier,
  note 10 §8); until then no cascade pick.
- Layout (note 03): `pp-doclayoutv3` regions on newspapers only (794 MB RSS); whole page elsewhere; never on
  handwriting or registers.
- Segmentation (note 07 §9): `seg-qwen3.5-2b-8bit` (80.3% pages exact unchecked, 78.8 checks per 100 pages, 4.4 GB
  peak), zero-shot card and the manuscript warning; review by its own level (no partner).
- Dating (note 08 §9): steps 1 and 4 `vision-2b-chooser-t3` (47.3 not in text, 89.9 in text), every propagated year
  Date Uncertain with its source document; step 2 `qwen3-vl-8b-image-mac` pending item 8.1.
- Entities (note 09 §9, owner call 11): nothing unless names are ranked; when ranked, `qwen3-vl-8b-mac` on typed and
  printed correspondence over Vision text, sender hidden; `none` on handwriting and non-correspondence.
- Placement (note 05): Vision's own lines on print; on handwriting kraken blla lines with alignment, gate 0.67, text
  page fallback; pending `W46.place-hands-cost` for the 16 GB fit, the hand route shows "memory unmeasured".
- Kit (note 12): no row.

**B2. 32 GB and 64 GB.** Identical picks to B1 until `W46.ocr-mac-27b`, `W46.date-mac-27b` and
`W46.ent-local-shipped-prompt` measure a 27B-class reader on a Mac; the solver must not borrow cluster rows' figures
for a Mac tier (note 08 §9).

**B3. 8 GB.** Reading as B1 with no download fitting (every Mac reader needs 8 GB plus headroom): Vision for typed and
printed, handwriting flagged. Segmentation `manual`. Dating `vision-rules-t3` (48.1, 85.7). Entities `none`.

**B4. B1 with "this batch stays on the Mac" on and a Gemini key present (owner call 2).** Every cloud and plan row
hollow with the reason "stays on the Mac"; picks as B1.

## C. Cheap API: an OpenRouter key, no Gemini key

- Reading: `qwen3.8-flash` ($0.60; 95.11 answered) over `qwen3.6-27b` (95.38, $1.94), a tie by the 0.49 floor
  (−0.08 [−1.62, +1.64], n 91, owner96/all/answered), cheaper wins; its 3 refusals go to the cascade row that escalates
  to `qwen3.6-27b`. Handwritten: `qwen3.6-27b` (hands16 92.61); `mistral-large4` ties it (−0.42 [−1.45, +0.68], n 16,
  owner96/hands16/strict, floor 0.60) at $2.69, dearer, and every other OpenRouter route without Gemini trails beyond
  the floor (note 04 §9 profile 2). Not pending: every OpenRouter route has a hands16 figure.
- Segmentation: `glm5.3-flash` (80.6%, $1.16) ties the 2B (80.3%) and the 2B wins on cost when the Mac has 16 GB;
  GLM when it does not.
- Dating: steps 1 and 4 `gemini3.7-flash-trace-neigh` only if the key reaches Gemini, else the Mac route of B1 (no
  trace row for an OpenRouter-only model; pending `W46.date-route-pipeline`).
- Entities: `qwen3.6-27b` (sender 0.62) on correspondence, extracted always on a cloud route, shown when names rank;
  where the Mac's 8B fits (16 GB, downloads allowed) it ties the 27B (0.58, ENT-1) and is free, so the 8B
  (W46.settings-solver).

## D. Premium API or plans

**D1. A Gemini key.** Reading `gemini3.8-flash` ($3.22, batch $1.61; 96.47) over `gemini3.1-pro` (96.85, $21.92), a
tie, cheaper wins; handwritten `gemini3.8-flash` labelled "conditional on the truth" (OCR-1). Segmentation
`gemini3.8-flash` (88.8%, $3.61; 25.3 checks per 100 pages; 100.0% after checking; prompt g2, every figure Gemini
3.7's g2 answers, W46.seg-magazine-rule-app) with the card showing Gemini 3.7's figures labelled as 3.7's (owner call 8). Dating step 1 `gemini3.8-flash-oneshot`, step 2 `gemini3.7-flash-image`
on documents with no year in the text ($2.75 per 1,000, 5.3 s), step 4 `gemini3.7-flash-trace-neigh`. Entities
`gemini-tagging-place`'s successor, the entity feature's own prompt (owner call 10), extracted always, shown when
ranked. Cascade: picked only if a cascade row beats `gemini3.8-flash` within the limits (none does at this ceiling).

**D2. A Gemini key, ceiling $1 for 1,000 pages, hours 24 (batch prices).** Reading `gemini3.8-flash` at the batch price
($1.61) is over the ceiling; two Gemini rows fit, `gemini3.5-flash-lite` ($0.79 batch; 95.17 answered) and
`gemini3.1-flash-lite` ($0.58; 94.59). The best feasible is `gemini3.5-flash-lite`; `gemini3.1-flash-lite` minus it is
−0.56 [−2.77, +1.09] (n 92, owner96/all/answered; strict −1.57 [−4.67, +0.78], n 95), over the 0.49 floor, so no tie
and `gemini3.5-flash-lite` is picked. The card's "What a better figure would need" names `gemini3.8-flash` (96.47) and
the $0.61 shortfall. Segmentation the 2B or `manual`.

**D3. The Claude plan only.** Reading `claude-sonnet5.5` (96.48, no money, the plan's window share by `usage.md`);
handwritten 92.50 labelled a drafter family. Segmentation `claude-sonnet5.5` (85.5%, 10.2 checks). Dating and entities:
no plan rows (the Claude arms were dropped, owner 2026-10-30), so the Mac route of B1 with the card saying why.

**D4. The ChatGPT plan only.** Reading: no measured row; the sheet says so and falls to B1. Segmentation
`chatgpt-only` as the app's table carries it. **Both plans:** segmentation `mix-claude-chatgpt` (90.9%, 10.2 checks)
over Claude alone, beyond the floor.

**D5. A Claude plan and a Gemini key, preference "cheapest within a point".** Segmentation: 85.5 against 88.8 is 3.3 points,
just beyond the 3.2 floor, so `gemini3.8-flash` wins (W46.seg-magazine-rule-app; on g1's 87.3 it was a tie and the plan
route won on money).

## E. A cluster (Sherlock), no key

- Reading: `qwen3.6-27b-farmshare` (95.31; 1,054.7 pages an hour), which ties the best, `qwen3.5-27b-farmshare`
  (95.38; 1,025.6), at −0.07 [−0.71, +0.47] (n 95, owner96/all/answered) and is the faster. `qwen3.5-9b-sherlock` does
  not tie either 27B (−0.76 [−1.53, −0.09] and −0.66 [−1.36, −0.04], n 93), nor does `qwen3.6-35b-a3b-farmshare`
  (−0.83 [−2.00, +0.06], n 95). Handwritten `infinity-parser2-pro-sherlock` (L1-L3 89.3; two GPUs), the pooled L1-L3
  leader over every other cluster route (+3.09 to +13.37, n 240, public895/L1-L3/strict). Newspapers
  `qwen3.5-27b-farmshare` (L9 95.84, the leader of public895/L9; descriptive, 15 pages, P13-7) read on
  `pp-doclayoutv3` regions for small readers (kind rule), whole page for 27B-class readers. Forms
  `qwen3.5-27b-farmshare` (L4 69.98, the leader of public895/L4; its rivals' intervals hold 0, which makes no tie).
  N6 `xiaomi-ocr-0-sherlock`; L5-L8, N1, N3, N4 `churro-3b-farmshare` (note 04 §9 profile 4).
- Segmentation: `seg-qwen3.5-2b-bf16-cluster` (80.3%; the fastest of three ties); review rule disagreement with the
  teacher as partner.
- Dating: steps 1 and 4 `qwen3.6-27b-trace-neigh-vision` (56.5 not in text, 93.3 in text), step 2 `qwen3.6-27b-image`.
- Entities: `qwen3.6-27b` (sender 0.62) on correspondence; never from Vision text on handwriting.
- Placement: the hand line detector setting visible (owner section 2, placement); PP-OCRv6 det offered as the
  cluster-side detector.

## F. Any profile plus a coding agent (fine-tuning answer)

- "No": no kit row anywhere.
- "With a coding agent": the handwriting fine-tune `kit-hands-ppocrv6-ft` shown as an after-training point on the
  handwritten kind where the reading pick is kraken, hidden below 80 corrected lines, target 160 (+2.50 at 160 on one
  hand; owner call 7); `kit-seg-lora-mac` shown as not offered ("not measured to fit").
- "On a cluster": `kit-seg-student-tags` shown when the corpus has tags or per-document folders (Sasha 89.1% gap
  accuracy, the TABME++ caveat); `kit-seg-lora-continue` shown once 200 corrected gaps of one material exist (box 2
  errors 17.2 to 4.9 per 100 gaps, flagging kept on); neither selectable until a manifest past the gate sits beside the
  Mac build (`W46.kit-mac-build`); before that, "needs the Mac build step".

## G. The router cases from integration stage 4

1. **No key, nothing downloaded, 8 GB:** every stage has a free pick or `manual`, and no card is empty (B3).
2. **"Stays on the Mac" with keys present:** no network route is picked and each hollow row says why (B4).
3. **A ceiling that only partly fits:** the solver spends on the stage with the highest weight first and the card of
   each stage that gave way names the better route and the shortfall (D2).
4. **Hours that nothing meets** (a 10,000-page batch on a 16 GB Mac in 1 hour): the sheet falls back to the cheapest
   feasible per stage and says which limit to relax and by how much (the prototype's fallback; `12-settings-design.md`
   §3.3).
5. **A tie chain:** the rows restricted to `qwen3.5-397b` (94.06, $2.02), `qwen3-vl-235b` (94.01, $1.22) and
   `qwen3.5-9b` (93.38, $0.25), all answered. Qwen3.5 397B minus Qwen3-VL 235B is +0.05 and Qwen3-VL 235B minus
   Qwen3.5 9B +0.47, both under the 0.49 floor, but Qwen3.5 397B minus Qwen3.5 9B is +0.53 (owner96/all/answered):
   judged against the best feasible route only, the pick is `qwen3-vl-235b`, never `qwen3.5-9b`. (The earlier chain,
   Gemini 3.8 Flash through Qwen3.6 27B to Qwen3.8 Flash, is not a chain under the matrix: Gemini 3.8 Flash minus
   Qwen3.6 27B is +1.00 [−1.26, +2.95], and Qwen3.8 Flash minus Gemini 3.8 Flash −1.11 [−3.08, +1.13], both over the
   floor.)
6. **A kind with no figure for the chosen route** (forms on an OpenRouter-only key): the card shows "no figure" for that
   kind and the row's overall figure, never a borrowed one.

## Pending figures that skip tests

`W46.place-hands-cost` (B1 hand placement fit), `W46.ocr-mac-27b` and `W46.date-mac-27b` (B2), the cascade rows' Mac
memory per tier (B1 cascade), `W46.date-route-pipeline` (C and D dating rows measured end to end). No
reading figure is pending: C's OpenRouter hands pick and E's Infinity-Parser2-Pro pair are decided (W46.pairs-redecide).
