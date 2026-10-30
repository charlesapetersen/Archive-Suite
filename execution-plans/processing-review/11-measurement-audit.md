# Processing review: the measurement audit

Written 2026-10-30, after the owner saw that W47.item-fields-truth judged the app against a truth built by weaker
open models. The question: where else in the W46 processing review and the W47 item-field work does a result rest
on a measurement that cannot carry it, and what should the open queue do about it.

Method. Four read-only auditors (segmentation; OCR, handwriting and placement; dating, entities, kinds, containers
and item fields; enhancement, marks, layout, capture and compute) read the strand notes, the result summaries in
`ArchiveProcessor/segbench-results/`, `ArchiveOCRBench/`, the shipped entries in `SUITE_TODO_DONE.md` and the
commit bodies. A fifth, independent agent then tried to refute every finding against the cited files. No corpus
page, image or text was read by any of them (owner rule, 2026-10-30), nothing was run on a model and nothing was
spent. The checker refuted no finding; it corrected eleven figures or statements and softened four severities
(FLD-1, FLD-2, FLD-6, SEG-2), and those corrections are in the text below. The one new figure is a paired page bootstrap over the per-page score table `ocr-pages.csv` (scores only,
4,000 resamples), marked [B]. [I] marks an inference.

Each finding gives the result or item, what is wrong, the evidence, how much it changes the conclusion
(**overturned**, **weakened**, or **holds** with a caveat) and the fix. Section 6 is the queue rework.

---

## 1. Summary

The flaw the owner found is real and it is not alone, but most of the review stands.

**Overturned or left unsupported.** The item-field verdict "no field clears precision 0.90, so fill none" (FLD-1)
does not follow from its truth: two 4-bit 8-12B models, one of them ruling its own disputes, judging Gemini. On kind
and recipient place the answer is unknown; on byline and publication Gemini's 0.50-0.64 is too far below the bar for
truth error to explain, so "leave empty" there probably stands. The CREST ranking of cloud against open segmenters
(SEG-2) is unsupported: Gemini's errors sit at gaps the truth's own author marked ambiguous. "ATRIUM over-calls
mixed" (KND-2) is overturned: under the owner's own mixed cut ATRIUM is the closer of the two. The R8 dating route
"send only the class C and D residue to a strong model" (DAT-1) rests on classes defined by ABBYY text.

**Weakened (about 25).** The handwriting recommendation for API users rests on 16 pages whose truth Gemini 3.8
drafted (OCR-1). The top of the 96 ranking is set by how failures and retries are scored, not by reading (OCR-2).
No OCR rerun-noise figure exists, yet choices are made at 1-2 points (OCR-3). Phase 4 would decide segmentation on
the old 363 typed-letter pages, because nothing scores a route on the three boxes locked today (SEG-8), and the
largest of those test boxes, Stanton, still carries the retired full-magazine rule (SEG-7). The students' "97.6%"
is agreement with the teacher on gaps the teacher already agreed on (SEG-5). "No crop or dewarp helps OCR" is
true of loose sheets and untested on curled ones (ENH-1, OCR-8). The placement truth's typed lines are Apple
Vision's, and Vision is scored on them (OCR-10). The shipped hand placer was chosen on a metric the owner ruled out
hours later (OCR-11). The marks set is being built to be circular with the detectors it will score (MRK-1). The
capture tags that four items slice by agree with a blind retag at kappa 0.14-0.47 (CAP-1).

**What stands.** In-text years are read by every route. One-shot dating beats the staged pipeline. Windows beat
single-page segmentation prompts, and the Lincoln drop belongs to the open models. Gemini is far ahead of the open
routes on the public pages. Small newspaper readers need a layout stage. Loop recovery works. No content-removing
enhancement for Vision, PP-OCRv6 or Gemini. DocRes dewarp harms every reader. DocLayout-YOLO in the app's setup
drops handwriting. The 96's typed-page truth is fit for ranking (the owner's blind check: 1.8% wrong where a third
family disagreed). Section 5 lists them all.

**The common causes.** (1) A truth drafted by models that are scored on it, or by relatives of the routes it
judges, with no check of the agreed part. (2) Sets chosen by a route under test or by ABBYY text. (3) Differences
of one to three points, or two to six discordant documents, reported as findings with no noise figure. (4) Failures
and retries handled differently between arms. (5) A verdict written as general ("no dewarp", "needs no change",
"fill none") from a sample that lacks the condition it rules on.

---

## 2. When a truth set needs the owner

The rule, for every truth set from now on. A session that builds or relies on a truth applies it and says which
case applies in the item's report.

**The owner's reading is needed when any of these holds:**

1. **Only he knows the answer.** His own collections' conventions, what counts as one document in a box, his
   segmentation principles (the article-within-issue rule), his own tags, or what a page shows that a model cannot
   check against anything (text under a sticky note, a neighbour sheet in the frame).
2. **The drafters are not clearly stronger than every route being judged, or a drafter or a close relative is
   itself scored.** Agreement between two drafters is then not truth for that route: their shared errors are
   invisible, and the drafter is scored against itself.
3. **The verdict sets an app default or route, or closes a line of work, and its margin is within the truth's
   likely error.** A precision bar of 0.90 cannot be judged against a truth that may be 5-10% wrong.

**A strong model through the gateway is enough when all of these hold:** the truth is something a frontier model
reads reliably (printed text, explicit fields, box geometry against visible ink); two different families draft it
blind and are both stronger than every scored route; neither drafter is scored, or a drafter is scored only on
owner-ruled items; and the result is a relative comparison with a margin well above the truth's error, or a
nice-to-have. Gemini 3.7 Flash through the Stanford gateway is the first drafter (owner, 2026-10-30), GPT 5.6 Luna
the usual second family. No Claude subagent reads corpus data.

**Never:** a truth that is the drafters' agreement with a drafter then scored as a route; a set chosen by a scored
route's own labels; ABBYY text as an input or a selector; one model ruling its own disputes without the count of
self-rulings reported.

**When a drafter's family is itself scored** (Gemini drafting while Gemini 3.8 is a route), agreement cannot be
taken on trust for that route: its rows are ranked first on owner-checked items, and the agreed controls are drawn
where that route agrees with the truth.

**The smallest owner pass that makes a truth reliable** is two parts: the disputed items that can decide a verdict
(the ones near a bar, or where the scored routes split), and about 20 randomly drawn agreed items as controls, so
the truth's own error rate is measured and reported beside every figure. Boxes on the image point at each place
(owner, 2026-10-21). Every pass states its size and an estimate of his minutes.

**How a session asks him.** An unattended session builds the sheet, estimates the minutes, judges the timing under
the owner-review rule (no known defect in the way, no queued work about to change what he reviews), then blocks the
scoring item on an owner gate whose text names the sheet, its size, its minutes and what it decides, and adds a
Daemon Report line (no decision). The gate reaches him at the next walkthrough, where he says whether he has the
time and when. An interactive session asks directly with the same four facts and the alternative without him (a
gateway-only truth, with the verdict labelled provisional).

**Truth sets in the review, judged by this rule:**

| truth set | drafted by | owner needed? | smallest pass |
|---|---|---|---|
| The 96, typed pages (OCR) | Claude Opus 5.5 + Gemini 3.8 Flash; owner ruled 606 disputed words; blind third-family check 1.8% wrong | **yes, small** (case 2: Gemini 3.8 drafted and is scored; the blind check judged 55 words, only where Qwen3.6-27B differed, so it is not a random control of the agreed words) | about 20 random agreed passages as controls, on the handwriting sheet, about 5 min more |
| The 96, the 16 handwritten pages | the same drafters; no hand page agreed word for word | **yes** (case 2: Gemini 3.8 is scored and leads) | blind sheet where third-family readers differ from the truth, about 15 min |
| The 895 public pages | the sources' published transcriptions | no | — |
| Placement, typed lines | Apple Vision's lines, Claude subagents redrew and audited | **yes** (case 2: Vision is scored on its own lines; case 3: sets the reading copy) | an open-model line cross-check, then a sheet of the disagreements plus 5 hand pages, about 20 min |
| Five original segmentation boxes | the owner's spring truth and checks | one run: Stanton's magazine under the new rule (case 1) | part of the segmentation sheet |
| CREST and Lincoln | catalogue starts plus one Codex agent's rulings, about 10 marked ambiguous | **yes** for the ambiguous gaps (case 1: what counts as a document) | part of the segmentation sheet |
| Sasha, Illustrated Review | owner-ruled blind: Sasha 177 of 178 gaps (one unsure), the Illustrated Review 134 of 146 (12 repeat photos drafted without him) | no | — |
| SC0122 | tags + the Qwen3.5 27B teacher; owner ruled only the 37 disputes | **yes** (case 2: the teacher and its students are scored) | 60 of the 162 agreed gaps, stratified, as controls; with the above about 30 min |
| Item fields (W47) | Qwen3-VL 8B + Gemma 3 12B, Gemma ruled | **yes** (cases 2 and 3; the re-truth's drafter Gemini 3.7 is a close relative of the scored Gemini 3.8) | gateway re-truth, then about 85 disputed fields + 30 agreed controls drawn where Gemini 3.8 agrees with the truth, about 50 min |
| Entities (W46.fix-ent-truth) | GPT 5.6 Luna + Claude Sonnet 5, Sonnet ruled | optional | 20 Sonnet-sided rulings, about 10 min, folded into the item-field sheet |
| Containers (W47.ct-truth) | Qwen3-VL 8B + Qwen3.5 4B; owner sees the disputes | already an owner gate | add Gemini as a third reader so agreement means three families |
| Marks set | Qwen3.6-27B pre-flag, open-model drafts; owner core of 40 pages | already an owner gate (6-7 h) | change what the core is drawn from (MRK-1), not its size |
| Capture tags | Claude subagents, kappa 0.14-0.47 against a blind retag | no: replace the geometry tags with measured signals, drop the optical tags from routing | — |
| Dating | the owner's own year tags | no | — |
| Kinds (the 144) | partly a session's labels, old mixed definition | no: use the owner's 170 mixed-def answers | — |

---

## 3. Findings: item fields, dating, entities, kinds, containers

### FLD-1 · W47.item-fields-truth · the truth is weaker than the routes it judges, and circular — overturned

- Every truth value is Qwen3-VL 8B's reading on the 78 agreed documents or Gemma 3 12B's ruling on the rest
  (`ArchiveProcessor/scripts/segbench/item_fields.py` `truth_of`). Both ran 4-bit on the Mac, on the first page at
  896 px and the first 3,000 characters (`TEXT_CAP`, `image_of`).
- The judge is reader B (`JUDGE = "gemma3-12b"`); it ruled for itself 62 times and for A 45
  (`item-fields.json` counts). There was no owner pass and no audit, although STATE's Phase 2 decision 2 says model
  drafts are "audited".
- The scored routes include Gemini 3.8 Flash and Qwen3.6 27B, both stronger than either drafter, and Qwen3-VL 8B,
  which is drafter A.
- The drafters, scored as reader rows against their own agreement, sit highest on byline, kind, recipient place and
  title (0.86-0.97, `item-fields.md`). They score lower on publication and publication date only because their rows
  are scored without `by_definition`, which the truth gets.
- The item's own check found truth errors ("the publication row is a floor").
- **Effect:** wherever the truth is wrong and Gemini right, Gemini is marked wrong, so the verdict "fill none" does
  not follow from this truth. Field by field it differs: Gemini's precision on byline, publication and recipient
  place is 0.50-0.64, which a 5-10% truth error cannot lift to 0.90, so "leave empty" there probably survives a
  better truth; kind is close enough that it may not. Overturned as a verdict, unsettled per field.
- **Fix:** W47.item-fields-retruth (section 6.2).

### FLD-2 · kind · Gemini's 0.87 sits inside the truth's own disagreement with a stronger truth — unsettled

- On 156 documents this truth's kind disagrees with W46.fix-ent-truth's correspondence ruling on 14 (8 + 6). That
  ruling was made by two frontier families with first and last pages, and was used here only as a check.
- Gemini's kind is 126 of 145, a Wilson interval of about 0.80-0.91, which contains the 0.90 bar before any truth
  error is allowed for. The item itself called kind "too close to call"; the verdict "leave it empty" is what does
  not follow.
- [I] The app's bare "article" maps to clipping and then to newspaper article, so a Gemini "article" on a magazine
  piece is wrong by the mapping.
- **Fix:** use the W46 ruling for correspondence kind in the re-truth; fix the mapping before scoring.

### FLD-3 · selection · the set was chosen by the scored route's labels and by ABBYY text cues — weakened

- The 60 added articles and reports (59 in the set) were drawn by the cached Gemini 3.8 reply's `format`; the 159 W46 documents by
  Gemini's format plus ABBYY-text cues (`ent-truth.md`). The pool needs ABBYY text and a year tag, which leaves out
  handwritten letters and undated documents.
- **Fix:** add a draw made without any scored route's label, and about 20 handwritten letters; report the three
  parts separately.

### FLD-4 · inputs · the truth, the extractor and the scored app replies ran on ABBYY text — weakened

- The readers' "OCR text" is `date_tagging.page_text`, ABBYY's layer. The build commit (b964a304, 10:29) landed
  after the owner's ban (2beecccd, 08:41); the readings ran before it. The report says "OCR text" and never names
  ABBYY.
- The cached app replies scored as "what the app gives now" were made from ABBYY text, an input the app never sends.
- **Fix:** Apple Vision text and the JPEG originals throughout the re-truth; rerun the app's call on Vision text.

### FLD-5 · coverage · page one and 3,000 characters — weakened

- Recipient places on envelopes or later pages and bylines at the end of reports are missed by the truth, and a
  route that finds them is charged with "filled when empty".
- **Fix:** the full document (cap the first 8 and last 2 pages).

### FLD-6 · publication date · the app's field is a different field — weakened

- The truth is the printed issue date; the app gives the document date. 15 of 65 printed pieces count wrong only
  because no issue date is printed. The owner's own year and month tags, which the Zotero `issued` field would carry,
  were not used. On the 50 pieces that do print a date Gemini is right on 26 (0.52), so the field stays weak either
  way; what does not follow is a verdict about the date the export would fill.
- **Fix:** score publication date against the owner's date tags as well as the printed issue date.

### FLD-7 · the bar · a point estimate on 34-145 documents, no allowance for truth error — holds, with a caveat

- **Fix:** fill a field when the Wilson lower bound is at least 0.85 and the point at least 0.90, on at least 40
  documents with a true value, after the truth's error is measured from the owner's controls. Otherwise the verdict is
  "too close", not "leave empty".

### FLD-8 · W47.item-fields-build · stale dependency, and a measurement inside a Tier-2 build — re-scope

- It waits on W47.item-fields-truth, which is done, and on W47.ct-design-ok and W46.review-done, which are open; once
  those two are answered it would build on the unsafe verdict. Its first step
  (test an image-reading prompt against a truth image readers made) is a measurement and is circular.
- **Fix:** it waits on the re-truth's score item; the prompt test moves there, scored only on owner-checked fields
  when the candidate shares a family with a drafter.

### FLD-9 · W47.ct-truth · two weak readers' agreement taken as truth; the drafters are likely W47.ct-read routes — weakened

- Qwen3-VL 8B and Qwen3.5 4B drafted; agreed fields (agreed-empty included) go in unchecked; the owner sees only the
  536 disputed fields (`ct-truth.md`). W47.ct-read will score "one or two open vision models on the Mac".
- **Fix:** in the pending JPEG rebuild (W47.ct-truth-jpeg), add Gemini 3.7 as a third blind reader (about $0.70);
  the owner sees fields where the three are not unanimous plus 20 unanimous controls; W47.ct-read scores a drafter
  only on owner-ruled fields.

### FLD-10 · stale spending text — minor

- `execution-plans/containers/00-plan.md` and W47.ct-backfill still say $3. The rule is $7 (owner, 2026-10-28).

### DAT-1 · the 131 "unprinted-year" documents and classes A-D were defined by ABBYY text — weakened

- They are the documents "whose owner year is not in the text sent", ABBYY's first 3,000 characters
  (`date-tagging.md`). On Vision text 24 of the 131 print their year (e069a728). The owner found 14 of the 33 strict A
  cases and 15 of the 21 D cases dated on their own page (`date-truth-sets.md`). With images Gemini finds the owner's
  year on the page for 56 of 122 (`date-image.md`).
- So for class D, "needs inference from context" is mostly "the OCR missed the date"; class C was never owner-checked,
  and over all 122 Gemini finds the date on the page for 46%. `10-gap-audit.md` still routes "only the class C and D
  residue (56 of 131)" to strong models; date-traceable-paid had already shown that staging loses to one shot
  (49.6 against 61.8%), so the residue design was already in doubt.
- **Fix:** Phase 4 restates the dating route as an image pass first, then neighbour estimation on what is left;
  "unprinted" is redefined from the image pass; the class tables are marked ABBYY-defined.

### DAT-2 · "few dates are handwritten, so no handwritten-date reader" — weakened

- It rests on 9 of 55 dates in a pool that needs ABBYY text, which mostly excludes handwriting; about a third of the
  bulk draw is mixed under the owner's cut.
- **Fix:** nice-to-have: the handwritten-date share on a draw from the JPEG mirror (about $0.30 on the gateway).

### DAT-3 · W46.date-image-paid · "Gemini reads a little more off the page than the 27B" — holds as a tie

- 52 against 48 exact; the discordant pairs are 6 against 2, a sign-test p of about 0.29 (4257ca11). On the owner's
  27 own-page cases, 21 against 20. The two are tied; the commit subject overstates it.

### DAT-4 · the typeface probe "dates nothing" on 12 crops — holds

- 11 of 12 ranges contain the year, median width 50 years. Enough to reject "typeface dates a document".

### DAT-5 · enclosure verdicts rest on 3 owner-confirmed enclosures; an 80-cover public set sits unused — holds, with a caveat

- W46.date-iitcdip built 80 checked cover/attachment pairs and 40 negatives (64ddc6ee); nothing has scored on them.
- **Fix:** nice-to-have.

### DAT-6 · the app's dating headline is unweighted, and undated documents were never tested — weakened

- 79.6% exact (199 of 250) is pooled over a 120/80/50 sample that does not match the pool; weighted to the pool's
  agreed counts it is 89.2% [computed from the strata in `date-tagging.md`]. The app gave a year on 300 of 300 replies; its false-year rate on the 425 undated agreed
  documents is unmeasured.
- **Fix:** W46.date-undated (section 6.2): the app's call on about 100 undated documents, on Vision text, through the
  gateway, about $0.40. Report pool-weighted figures beside the per-stratum ones.

### DAT-7 · Date Uncertain scored against the owner's tag measures a definitional mismatch — holds, with a caveat

- The prompt's test is "cannot be determined from the document itself"; the owner knows the box. "Gemini flags 69.8%
  of owner-certain unprinted years uncertain" is largely that mismatch, on the ABBYY-defined set.
- **Fix:** score Date Uncertain against "a date is on the document's own pages", from the image pass. Folded into
  W46.date-undated.

### DAT-8 · subgroup claims in W46.date-traceable-paid — holds, with a caveat

- "Neighbour dates hurt C+D (44.6 to 39.3%)" is 3 documents of 56; "five examples add nothing" is one document. The
  main verdict (staging loses, 49.6 against 61.8%, 16 documents of 131) holds.

### DAT-9 · "52 with no dating year on the page" came from weaker readers — weakened

- Qwen3.5 4B on the first page, then Qwen3-VL 8B on all pages; the 8B finds the year where the 27B and Gemini do
  about two thirds as often. Only matters if the stratified 200 is used again.

### DAT-10 to DAT-12 — minor

- Per-class intervals of 12-20 points behind the "82% to 52%" split; the date-image arms differ in resolution and
  quantisation (stated); a Claude subagent's eye check of 24 page dates in date-image (cf5b3132), now against the
  2026-10-30 rule. No figure changes.

### ENT-1 to ENT-5 · entities — hold, with caveats

- The entity truth is the strongest model-built truth in the review: two frontier families, first and last pages,
  neither scored by W46.ent-score. Sonnet, also reader B, ruled 86 documents (B 51, A 18). The pool needs ABBYY text,
  so there are 5 handwritten letters. The app replies scored were made from ABBYY text. Close ranks (the 27B 0.60
  against the 8B 0.56 on senders, n 82) are noise. W46.ent-robust measures consistency against the 27B's own names,
  and says so.
- **Fix:** W46.ent-score-paid uses Vision text and adds the 56 documents; an optional 20-field owner control on
  Sonnet-sided rulings goes on the item-field sheet.

### KND-1 · the "144 owner-labelled pages" were partly labelled by a session, not blind — weakened

- `kind-classifier.md` Limits: one reader looking at contact sheets. The shipped weights (off by default) are fitted
  on them.

### KND-2 · "ATRIUM over-calls mixed" — overturned

- Under the owner's cut (any handwriting, a signature included) about 33% of the bulk draw is mixed
  (`mixed-def-score.md`). ATRIUM's 28.1% is closer than Qwen's 8.2% (`mixed-def.md`). The classifier's 139/144 and
  every mixed figure on the 144 use the old definition.
- **Fix:** W46.kind-atrium scores mixed against the owner's 170 sheet answers and scores only
  typed/printed/handwritten on the 144.

### KND-3 · the 33% mixed share rests on 3 of 20 controls — holds, with a caveat

- About 27-46% once the stratum's interval is carried through. Matters only to W46.mixed-route-bands' cost estimate;
  report the interval.

---

## 4. Findings: segmentation; OCR, handwriting and placement; enhancement, marks, layout, capture

### Segmentation

**SEG-1 · SC0122 · 162 of 199 gaps are tag and teacher agreement, never seen by the owner — weakened (no score yet).**
The box was drafted from tags plus the Qwen3.5 27B teacher; only the 37 gaps where they disagree went to the owner
(`seg-boxes.md`). On the other 162 the teacher cannot be wrong, and it is a scored route and the students' source.
The owner's own checkpack measured 5.3% wrong among exactly such agreed labels (W41.seg-label-clean-fu1; about 3
errors in 49 judged), which puts the hidden errors at about 8, anywhere from about 2 to 26: up to as many as a cloud
route's whole error count on a box. **Fix:** before any route is scored on SC0122,
the owner rules 60 of the 162 agreed gaps blind as controls, and SC0122 is scored on the 97 owner-ruled gaps with the
agreed stratum weighted; or SC0122 reports only its 37 ruled gaps and excludes the teacher and students.

**SEG-2 · CREST · "the cloud models are below the open models" — unsupported as a ranking.** CREST's internal starts
are one Codex agent's rulings, and it names pages 46 (unheaded approval jottings), 88 (a seal page), 94 and 111 as
ambiguous continuations (`public-segmentation.md`). Gemini's only two CREST errors are gaps 45/46 and 87/88; fixing
87/88 alone moves pages-exact from 85.9% to 96.9% (`seg-adapt-fewshot.md`), between the teacher's 95.3% and the 4B's
98.4%. Claude's 84.4% (3 false splits on handwritten notes and an emblem page) is not shown to sit at ambiguous gaps.
So the ranking is not reversed; it is not supported either. **Fix:** the owner rules the agent's
ambiguous CREST and Lincoln gaps (about ten) blind, and every cached answer is rescored at no cost. Until then CREST
is reported as boundary errors with the ambiguous gaps marked.

**SEG-3 · Lincoln · the drop holds, the comparisons among cloud arms do not — holds (the drop), weakened (the rest).**
Cloud 87-90% against open 34.9-46.7% is far larger than the truth's doubt. But two of Claude's three misses are at the
agent's ambiguous wrapper pages 77 and 231, and Gemini's few-shot "new false merge" is at 76/77. **Fix:** as SEG-2;
score Lincoln with those gaps marked unsure.

**SEG-4 · the stated letter cue "cuts Lincoln's review load 22.6 to 7.3" (f83d67d9) — weakened.** One box, one run,
two transports; pages-exact unchanged on all four boxes; the effect reverses on Deaver (10.7 to 14.8). No default was
changed by it. **Fix:** record c2 as "no measured effect".

**SEG-5 · the students' "97.6% on held-out gaps" is not accuracy — weakened.** (Also: the Illustrated Review and
SC0122 are wholly in the students' training split, and the owner ruled on 2026-10-29 that student scores on them are
reported as trained-on; Sasha is the only new box held out.) It is scored only on the 5,668 holdout
gaps where tag and teacher agree, with the teacher scoring 100% by construction (`seg-students.md`). A-segmentation and
the gap audit cite it as evidence for the kit. The test-box figures (78.8-79.1%) are the honest ones. **Fix:** relabel
it "agreement with the teacher on agreed gaps"; measure the students' held-out accuracy on the owner's checkpack and
on Sasha only, in W46.kit-gate; the published model card (W41.app-local-seg-publish) does not quote it.

**SEG-6 · the checkpack's measured label noise was never written up — holds, with a caveat.** 5.3% for the agree rule
and 9.5% for start-trust; `label-clean.md` still says the noise "takes a fresh sample". **Fix:** in W46.kit-gate.

**SEG-7 · Stanton (250 of the 363 test pages) still carries the full-magazine rule — weakened.** Its case 38 is a whole
magazine kept as one document; the owner re-ruled magazines article-within-issue on 2026-10-29. Every test-box figure
(options.md's five app figures, seg-teacher, seg-students, seg-context, seg-window-modality, seg-adapt-curve) is on it.
W46.seg-magazine-rule-redo, which would fix it, waits on W46.review-done, after the decisions. How many pages the
magazine run covers is not recorded [I]. **Fix:** split the redo: the Stanton re-rule and the rescore of cached
answers go on the segmentation sheet before Phase 4; the prompt and app changes stay after W46.review-done.

**SEG-8 · no route is scored on the three boxes locked today — weakened (every Phase 4 segmentation decision).** The
boxes exist because 363 pages of typed letters cannot carry the segmentation decisions (gap audit row 36), yet no open
item scores a route on Sasha, the Illustrated Review or SC0122, and Phase 4 does not wait for one. **Fix:**
W46.seg-boxes-score, a blocker of Phase 4.

**SEG-9 · Gemini 3.8 and 3.7 are mixed across comparisons — holds, with a caveat.** Every owner-box Gemini figure is
3.8 (direct key); every public-box and gateway figure is 3.7. W46.seg-window-modality-paid would compare new 3.7 arms
against a cached 3.8 baseline. **Fix:** add a K=7 Gemini 3.7 control on the same pages.

**SEG-10 · the five options.md figures are within rerun noise — holds, with a caveat (the file says so).** Rerun noise
measured later is 1.4-3.2 points a box; the figures are user-facing. **Fix:** W46.seg-boxes-score reruns the shipped
cloud route at two window offsets on the 363 pages, so the figures can be shown as ranges.

**SEG-11 to SEG-15 — minor, hold.** Owner-box truth corrections were found only where models disagreed with the
truth, which moves truth toward the models slightly; the 2B's text-only verdict is off its training shape; "the 8-bit
2B is the most accurate build" is within noise (still the right pick on memory and speed); the Illustrated Review
draft was read by Claude subagents (now against the rule; every gap was owner-ruled, so the truth stands);
doc-split-v1 was rejected outside its input conditions (the margin is 30-80 points).

### OCR, handwriting and placement

**OCR-1 · "Gemini 3.8 Flash for API hands" — weakened.** Gemini 3.8 drafted the 96's truth with Claude Opus; no hand
page agreed word for word; the owner's picks on disputed words favoured Gemini's draft (68.5% against 50.2% of
adjudicated words, `ocr-truth-bias.md`). The blind check drew 20 pages from the whole 96, about 3 of them hands [I].
[B] Gemini 3.8 minus Sonnet 5.5 on the 16 hand pages is +3.5 (+0.3 to +7.7). **Fix:** a blind owner sheet on the hand
pages where third-family readers (Qwen3.6-27B, LightOnOCR-3) differ from the truth, about 15 minutes; until then the
16-page hand chart is labelled "agreement with the drafters"; public L1-L2 and the HHTR gold (W46.ocr-new-open-gold)
rank hands on independent truth.

**OCR-2 · the top of the 96 ranking is set by failures and retries — weakened.** "Highest on the 96: Claude Sonnet 5.5
(96.47)" counts failures as 0, and Claude's harness retried an empty answer once while the OpenRouter routes had no
retries; Gemini 3.1 Pro's two failures are provider refusals on reprinted text. (The `claude -p` harness retries only a
harness error or timeout, and the Sonnet run logged none, so retries did not shape its 96.47.) [B] On pages both answered, Sonnet
minus Gemini 3.1 Pro is -0.28 (-1.22 to +0.49). The same artefact makes "Gemini 3.7 96.7 against 3.8 94.5" (on pages
both read, +0.42, -0.26 to +1.22) and Qwen3.5-27B 81.8 on SiliconFlow against 95.3 on FarmShare. **Fix:** headline
the answered-only score with the failure rate beside it, split provider failures from model failures, one retry rule
for every route, paired intervals on the bench page; correct R3 and R4 in the gap audit.

**OCR-3 · no OCR rerun-noise figure exists — weakened (the method).** Every panel reads each page once; the only
evidence is incidental (a byte-identical resend at temperature 0 changed answers, c15d35bb). Choices are still made at
1-2 points ("within 1.5 points", "3.7 interchangeable with 3.8 within about a point"). **Fix:** W46.ocr-rerun-noise.

**OCR-4 · the truth-bias verdict holds for typed pages — holds, with a caveat.** p081, which the owner said he cannot
correct, was dropped from the check but still counts in the accuracy table; reading order was never judged; the check
only finds errors where Qwen3.6-27B differs. **Fix:** report p081 apart.

**OCR-5 · C-ocr's "within 0.6" is 1.59 — minor.** The later blind check reached the conclusion soundly.

**OCR-6 · the region and tile losses on the 96 are scored with an order-sensitive metric on a truth with no order —
weakened (the size).** -11.9 for Gemini 3.7 on PP-DocLayoutV3 regions and -5.7 for tiles are character Levenshtein in
order, and `regions-20261021.md` says reading order is unscorable on the 96. Order alone cost Qwen 0.71 points on
whole pages. The order-free scorer (bowF1 and NewsBench's gap) exists and was never run on these arms. On hands,
regions lose content outright, which probably stands. **Fix:** W46.ocr-rescore-offline.

**OCR-7 · arms that alter the image are judged against a truth drafted from the unaltered image by the same family —
holds, with a caveat.** Text an arm reveals that the drafters missed is charged as added. **Fix:** phrase such verdicts
as "no gain measurable against a truth drafted from the unaltered image", and check arm effects on the public strata
before closing a line of work.

**OCR-8 / ENH-1 · "no crop or dewarp helps OCR" — weakened as a closed line of work, holds as the default for loose
sheets.** Only 10 of the 63 originals are tagged curl and 18 perspective; their intervals run from about -10 to +10
(Vision curl UVDoc +1.9, -0.7 to +4.8; Gemini perspective quad +2.0, -1.0 to +6.9). Our own UVDoc install on
genuinely warped photographs took Tesseract CER from 0.380 to 0.065 (`enh-dewarp-uvdoc-bench.md`). The 895 variants
were skipped on the strength of the 96. W46.place-geom takes the verdict as settled. **Fix:** reword to "no dewarp by
default on box photographs of loose sheets; strongly curled or bound pages untested", and score the dewarp arms on
Real5's Warping folder and the capture ladder's tilt images, which are already staged.

**OCR-9 · models scored on only one set — holds, with a caveat (incomplete).** Most hosted routes predate the
both-sets rule and are held for W43.sweep. Gemini 3.7 Flash, the gateway default, came after the rule and has not
read the 895 (1baafbe7); about $3.8. Gemini 3.8 Flash and Qwen3-VL 235B cover 440 of the 895. Qwen3.6-35B-A3B read the
two sets with different settings (OpenRouter fp8 against FarmShare bf16). **Fix:** W46.ocr-gemini37-895-paid; mark the
96-only rows on the bench page.

**OCR-10 · the placement truth's typed lines are Apple Vision's, and Vision is scored on them — weakened.** 10,539 of
14,124 typed word boxes are Vision's, trimmed; lines follow Vision's lines (`place_truth.py`); Claude subagents
audited; the owner never checked (`place-truth.md`). Vision reaches 0.930 baseline F on typed pages and 0.733 on hands,
where lines were drawn independently. Since 2026-10-29 the line pass rate on these lines decides the reading copy and
ranks W46.place-print and W46.place-geom. **Fix:** W46.fix-place-truth-lines: an open-model line cross-check (blla or
PP-OCRv6 det) and an owner sheet of the disagreements, before those two rank anything.

**OCR-11 · the shipped hand placer and its 0.67 gate were chosen on per-word Find — weakened.** Chosen 2026-10-29 00:54
(717e4db7); at 07:34 the owner ruled that per-word scores are no evidence of selection (c096de18). The gate was fitted
on 20 pages, and the per-page matcher pick it sits on reverses on Bentham for LightOnOCR-3. Its input reading is a truth drafter. **Fix:** W46.place-hands-lines rescores it
on the line pass rate with a non-drafter reading as input.

**OCR-12 · the postcorrect verdict compares unlike builds — holds, with a caveat.** The direct 27B reading was
OpenRouter fp8, the corrector Sherlock vLLM FP8; the band was chosen by NES against the truth. A Gemini corrector on
the 96 would be pulled toward the drafter truth. **Fix:** W46.ocr-postcorrect-paid moves behind W46.nice-to-have (the
owner-material verdict is already "no stage").

**OCR-13 to OCR-16 — minor.** The loop-fallback order was chosen on the 895 and reverses on the 96's 18 caps
(01104a8a); 18 of the 96 truth images are still FineReader-processed PDF images; Gemini's lead on the public set may
include training exposure through CHURRO-DS (unlabelled for hosted rows); Gemini 3.7 and the 13 FarmShare runs are
missing from `ocr-pages.csv`, against the bench page's completeness rule. No ABBYY text is an OCR or placement input.

### Enhancement, marks, layout, capture

**ENH-2 · the whole-96 rows mix in 33 ABBYY-processed PDF images — holds, with a caveat.** UVDoc costs -3.8 to -4.4 on
them and less on originals. **Fix:** quote the 63 originals as the headline for image-preparation arms.

**ENH-3 · "no enhancement for any reader" is underpowered for the small readers — holds, with a caveat.** Tight and
null-to-negative for Vision and Gemini; about ±5 NES for Qwen3-VL 8B, the laptop reader expected to benefit. **Fix:**
state the minimum detectable effect beside the null.

**ENH-4 · the edge-loss counts (44 and 429 truth words) may include neighbour-sheet text — weakened (that figure).**
W46.place-geom now treats them as forbidden losses. **Fix:** split the lost words into own-sheet and neighbour text
from Vision's word boxes before place-geom uses them.

**CAP-1 · capture tags — weakened for any per-tag claim.** Claude subagents drafted them from corpus images; presence
kappa against a blind retag is 0.14 (low light), 0.24 (glare), 0.33 (shadow), 0.39 (edge cut), 0.43 (defocus), 0.47
(perspective) (`capture-tags.md`); no owner check. Four items slice by them. The aggregate material-and-framing losses
(edge cut, colour) are consistent across 26-27 of 29 routes and hold. **Fix:** replace the geometry tags with the
measured signals in `enh-dewarp.json` (baseline-angle residual, UVDoc bend, quad area); drop the optical tags from
routing decisions.

**MRK-1 · the marks set is being built to be circular with what it will score — weakened, cheap to fix now.** Pages
are picked from a Qwen3.6-27B pre-flag; open models draft the boxes; 110 of the 150 pages are model-audited only;
W46.marks-detect then ranks Qwen3.6-27B boxes against the set; W46.mixed-route scores Vision's per-line kind against
the Azure flags that were a drafting aid; W46.mixed-route-bands' bands come from Qwen's own band guess. Qwen's earlier
mixed label was 8.2% where the owner's cut gives about 33%, so its misses are under-sampled. **Fix:** draw at least 40
pages of the 150 from the 1,014 scanned independently of the flag, with inclusion probabilities recorded; draw the
40-page owner core across flagged and unflagged pages; draft with two families (Gemini 3.7 through the gateway and an
open model); rank detectors on the owner core only, and never rank a drafting model on pages it drafted; per-line
kind truth for mixed-route from the owner core.

**MRK-2 · the marks item's next steps tell a session to look at pages by eye and to run a model audit — process.**
Under the 2026-10-30 rule those become a Gemini or open-model pass or an owner sample.

**LAY-1 · "the app's region sort needs no change" rests on 5 multi-column pages plus 15 newspaper pages — holds, with
a caveat.** The other 10 failed because YOLO found no body region. **Fix:** reword to "best geometric rule on print
where the detector finds regions"; the owner-page verdict waits for W46.layout-order-marks.

**LAY-2 · W46.layout-photo checkpoint 2 confirms its premise and weakens two later designs.** In the app's setup
DocLayout-YOLO leaves nothing to read on 72 of 80 L1 pages and 10 of the 96's 16 hands, because it labels the ink
"picture" and the app's filter drops pictures, so part of the loss is the filter. If W46.layout-order-marks or
W46.mixed-route hold detection fixed on YOLO, marginal marks are dropped before scoring. **Fix:** both hold detection
fixed per detector (PP-DocLayoutV3, Vision, and YOLO with picture regions kept). W46.layout-photo is claimed by a
running session and is not edited; Phase 4 reads this note.

**LAY-3 · Mac seconds in `layout-photo-hands.md` and the enh-ocr-input entry were likely taken at background QoS —
holds, with a caveat.** YOLO 1.77 s a page here against 0.51 s in the gap audit. **Fix:** any Mac-seconds figure that
enters a route decision is re-timed in an interactive session.

---

## 5. Results that still stand

- **Dating.** Every route reads the year when it is in the text (Gemini 97.5% on 119). One shot beats the staged
  pipeline (61.8 against 49.6%, n 131). An image pass finds the date on the page for 43-46% of ABBYY-unprinted
  documents. The look-alike retrieval route is worse than position. The `[enclosure]` marker is inert. The trained
  2B and 4B are not dating defaults.
- **Entities.** Gemini leads the local routes; the evidence rule (a quote, or marked inferred) stands; GLiNER and
  NLTagger cannot replace the LLM; entities survive Vision text on typed pages and not on hands.
- **Kinds and mixed pages.** The classifier separates typed, printed and handwritten pages on the old definition. The
  owner's mixed cut is the definition.
- **Segmentation.** Windows beat single-page prompts. The Lincoln drop is the open models'. Students' confidence does
  not rank their errors. Disagreement with a strong second model is the better review rule. doc-split-v1 is not the
  laptop segmenter. The collection block has no effect beyond noise. Self-voting and few-shot buy nothing. The whole
  folder is not a route for the 2B. Sasha is the cleanest truth in the bench.
- **OCR.** Gemini is far ahead of the open routes on the hard public strata (+18.7, 16.1 to 21.5 on the 440). Small
  newspaper readers need layout. Loops come first, and another reader recovers capped pages. Log-probabilities flag a
  reader's own errors but do not choose escalations. Image-grounded correction beats text-only. The 96's typed-page
  truth carries little error. 4-bit costs Qwen3-VL 8B little on pages it answers. Gemini 3.7 equals 3.8 on pages both
  answer. Placement detectors beat Vision on hands, and placement is ranked on F1 at the centre.
- **Enhancement, layout, capture.** No content-removing enhancement as OCR input for Vision, PP-OCRv6 or Gemini. DocRes
  dewarp harms every reader. The 2048 px, q 0.85 encoder is fine. UVDoc is not a default for loose sheets. Region
  order on public print is solved by geometry when regions exist. DocLayout-YOLO in the app's setup drops handwriting.
  Framing and material defects cost more than optics.
- **Containers.** The W47.ct-truth sampler, its strata and the Route B tree set. Title is never filled by the app
  because the prompt never asks for one.

---

## 6. The queue rework

The owner's calls on this section are recorded in section 7. Item detail lives in `SUITE_TODO.md`; the plan carries
the dependencies. `plan-edit.sh` gained `depend` and `undepend` for this rework: `block` always files a new owner gate,
and an item moved behind W46.nice-to-have while W46.review-phase4 still waited on it would have deadlocked both
(W46.nice-to-have waits on W46.review-phase4).

### 6.1 Re-scoped (detail added to each SUITE_TODO entry)

| item | change | finding |
|---|---|---|
| W47.item-fields-build | waits on W47.item-fields-retruth-score; the image-prompt test moves there | FLD-8 |
| W47.ct-truth-jpeg | Gemini 3.7 as a third blind reader (about $0.70); the owner sees non-unanimous fields plus 20 controls; names the drafters W47.ct-read may not score | FLD-9 |
| W47.ct-read, W47.ct-read-paid | a drafter is scored only on owner-ruled fields | FLD-9 |
| W47.ct-backfill | the $3 text becomes $7 | FLD-10 |
| W46.fix-marks-set-draft | a flag-independent draw, an owner core across flagged and unflagged pages, two drafting families, no Claude eye check or audit | MRK-1, MRK-2 |
| W46.fix-marks-set-score | the freeze records each page's sampling stratum and drafting models | MRK-1 |
| W46.marks-detect | ranks on the owner core; no model ranked on pages it drafted | MRK-1 |
| W46.mixed-route | per-line kind truth from the owner core, not the Azure flags; detection per detector, YOLO with pictures kept | MRK-1, LAY-2 |
| W46.mixed-route-bands | bands from owner-core labels; the mixed share with its interval | MRK-1, KND-3 |
| W46.layout-order-marks | detection held fixed per detector, scored on the owner core | LAY-2 |
| W46.place-print | waits on W46.fix-place-truth-lines; Vision rows reported on drawn and Vision-derived pages apart | OCR-10 |
| W46.place-geom | waits on W46.fix-place-truth-lines; pages chosen by measured geometry; edge loss split | OCR-8, OCR-10, ENH-4, CAP-1 |
| W46.capture-ladder | no slicing by the optical tags; dewarp arms on the tilt images; bowF1 beside NES | ENH-1, CAP-1, OCR-6 |
| W46.ocr-new-open (+ -sherlock) | answered-only and strict NES, paired intervals, provider and model failures apart, the same settings on both sets, bowF1 | OCR-2, OCR-3, OCR-6, OCR-9 |
| W46.ocr-ppocrv6-hands (+ -paid) | hands ranked on public L1-L3; owner-hand results labelled agreement with the drafters until the hand sheet is answered | OCR-1 |
| W46.seg-window-modality-paid | a K=7 Gemini 3.7 control on the same pages | SEG-9 |
| W46.seg-magazine-rule-redo | the Stanton re-rule and rescore move to the segmentation sheet; prompts and app stay here | SEG-7 |
| W46.kit-gate | the checkpack write-up; students scored on owner-ruled gaps (checkpack, Sasha), not agreed labels | SEG-5, SEG-6 |
| W46.kind-atrium | mixed scored against the owner's 170 answers; the over-call premise dropped | KND-1, KND-2 |
| W46.ent-score-paid | Vision text, not ABBYY; the 56 added documents | ENT-3 |
| W41.app-local-seg-publish | the model card does not quote the 97.6% | SEG-5 |
| W46.review-phase4 | reads this note; waits on the new useful-now items below | all |

### 6.2 New items

| item | what | cost | owner time | Phase 4 waits? |
|---|---|---|---|---|
| W47.item-fields-retruth | gateway re-truth on full documents, JPEG originals and Vision text: Gemini 3.7 and GPT 5.6 Luna draft blind, Gemini rules, W46's ruling for correspondence kind; about 300 documents (the 219, 60 printed pieces drawn without a route's label, 20 handwritten letters); the app call rerun on Vision text; builds the owner sheet | about $5.3 ceiling | — | no (W47) |
| W47.item-fields-owner-ok (gate) | the sheet: about 85 disputed fields and 30 agreed controls, plus 20 entity controls | — | about 50-60 min | — |
| W47.item-fields-retruth-score | fold the answers, measure the truth's error, score every route, the Wilson rule, the image-prompt test | $0 | — | no |
| W46.seg-truth-sheet | one segmentation sheet: Stanton's magazine run under the article rule, the ~10 ambiguous CREST and Lincoln gaps, 60 of SC0122's 162 agreed gaps | $0 | — | — |
| W46.seg-truth-owner-ok (gate) | that sheet answered | — | about 30 min | — |
| W46.seg-truth-rescore | rescore every cached answer on Stanton, CREST and Lincoln; options.md, the bench page | $0 | — | yes |
| W46.seg-boxes-score | the cloud windows (Gemini 3.7, the gateway), the 2B on the Mac, the teacher and 4B on Sherlock, on Sasha, the Illustrated Review and SC0122 (students reported as trained-on on the last two; Sasha is the only held-out new box); two window offsets of the shipped route on the 363; shares W46.kit-gate's teacher arm rather than rerunning it | about $4.50 | — | yes |
| W46.ocr-rerun-noise | the 96 read twice more by Gemini 3.7 (gateway) and one Mac MLX route; the per-route rerun spread on the bench page | about $0.80 | — | yes |
| W46.ocr-rescore-offline | bowF1, NewsBench's gap and word rates for every regions, tiles and cells arm; answered-only headline, failure split, paired intervals, p081 apart, 96-only rows marked, Gemini 3.7 and the FarmShare runs into `ocr-pages.csv` | $0 | — | yes |
| W46.ocr-gemini37-895-paid | Gemini 3.7 Flash on the 895, the default route on the public set | about $3.80 | — | yes |
| W46.ocr-hands-sheet | the blind hand sheet where third-family readers differ from the truth | $0 | — | — |
| W46.ocr-hands-owner-ok (gate) | that sheet answered, with 20 random agreed typed passages as controls | — | about 20 min | — |
| W46.ocr-hands-rescore | fold the answers, correct the hand truth, rescore the hand charts and C-ocr's hand route, report the typed controls' error rate | $0 | — | yes |
| W46.fix-place-truth-lines | an open-model line cross-check of the typed truth pages and an owner sheet of the disagreements plus 5 hand pages | $0 | — | — |
| W46.place-lines-owner-ok (gate) | that sheet answered | — | about 20 min | via place-print and place-geom |
| W46.place-hands-lines | rescore the shipped hand placer and its gate on the line pass rate, with a non-drafter reading as input | $0 | — | yes |
| W46.date-undated | the app's false-year and Date Uncertain rates on about 100 undated documents, Vision text, the gateway; pool-weighted dating figures | about $0.40 | — | yes |

New gateway spend if all of it runs: about $15.60 across six items, each under $7, against the gateway's $50 a month:
W47.item-fields-retruth $5.30 (the derivation: about 4.4M input and 0.46M output tokens at the repo's ceiling price,
$0.75 and $3.75 a million, `gateway_gemini.py`; Luna at $0.20 and $1.20), W47.ct-truth-jpeg's third reader $0.70,
W46.seg-boxes-score $4.50 (527 box pages and 726 offset pages at $3.61 a thousand), W46.ocr-gemini37-895-paid $3.80
(895 at $0.0042), W46.ocr-rerun-noise $0.80, W46.date-undated $0.40. The owner approved the W47 spend and the W46
items on 2026-10-30 (section 7). Owner time if every sheet is taken: about 2 hours 20 minutes, in four sittings.

### 6.3 Moved behind W46.nice-to-have

- W46.ocr-postcorrect-paid: the owner-material verdict is already "no stage", and a Gemini corrector on the 96 would
  be scored against a Gemini-drafted truth (OCR-12).
- W46.ent-robust-paid: Gemini's names on the route already match the truth-text names at 0.96; it would not change a
  decision.

Not filed, listed for the nice-to-have opening: enclosure scoring on the IIT-CDIP 120 (DAT-5); the handwritten-date
share on a non-ABBYY draw (DAT-2); about 40 more mixed-page controls if W46.mixed-route-bands' cost depends on the share
(KND-3).

### 6.4 Retired

- W46.seg-context-more: it was conditional on the collection block helping, and it did not beyond rerun noise on the
  owner boxes (`seg-context.md`). It did move Lincoln by about 3 points beyond noise; that is what W46.seg-context-paid,
  behind W46.nice-to-have, still tests.

### 6.5 Not changed

W46.layout-photo (claimed; its premise is confirmed, LAY-2), W46.layout-order-train, W46.layout-order-paid,
W46.marks-detect-paid, W46.mixed-route-paid, W46.capture-ladder-paid and -sherlock, W46.enh-ocr-input-marks,
W46.enh-ocr-input-ppocr, W46.ocr-new-open-gold, W46.kit-mac-lora, W46.r6-spot, W46.r1-foundation, W46.truth-jpeg-rest,
W46.seg-tabme and -paid, W46.seg-openpss and -paid, W46.seg-context-paid, W46.seg-adapt-lora, and the W47 container
build items (W47.ct-spec, W47.ct-infer, W47.ct-reader-view, W47.ct-reader-edit, W47.ct-processor-capture,
W47.ct-processor-intake, W47.ct-zotero; W47.ct-zotero takes `issued` from the owner's or the app's date, not from the
item-field publication date, FLD-6). Their designs do not rest on a flawed measurement, or the flaw is already carried by an item above.
Several name prerequisites that are done; a done prerequisite is satisfied, so they need no edit.

---

## 7. The owner's calls (2026-10-30, interactive)

| question | the owner's call |
|---|---|
| Apply the queue rework in section 6 | apply all, the retirement included |
| W47 gateway spend (outside the W46 release): the item-field re-truth (about $5.30) and Gemini as the third label reader (about $0.70) | approve both |
| Which owner sheets to file | all four: item fields (about 50-60 min), segmentation (about 30 min), handwriting OCR (about 20 min), placement lines (about 20 min) |
| SC0122's 162 agreed gaps | 60 of them as controls, on the segmentation sheet |

Each sheet reaches him as a HOLD QUEUE gate that waits on the item building it; the building session judges the
timing under the owner-review rule.
