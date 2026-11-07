# 10. Page kinds, mixed pages, the cascade and routing by kind (draft rule note)

## 1. Stage and question

The stage labels each page's kind on the Mac before it is read, measures the collection's mix from a sample, and sends
a page to a reader by its kind. The user chooses one switch (read handwriting on typed pages); the classifier is a rule.
The failure cascade is a reading route like any other, owned by note 04 (owner call 5); this note keeps only the
app's cascade mechanics that bear on routing.

## 2. Is there a choice?

Rules and one switch. The kind classifier is not a choice: the shipped one (Vision signals and the feature print, a
logistic regression for the hand and one for forms) beats ATRIUM on the owner's 141 typed, printed and handwritten
pages, 137 against 121 (paired p 0.000855), and on the 895 public pages, 723 against 638 [M, `kind-atrium.md` §1, §4].
The switch: `mixed-route` (W46.mixed-route-setting, label as filed "Read handwriting on typed pages (signatures,
dates, notes in the margin)", default off, owner call 3). The cascade has no switch of its own: each measured cascade
is a route row in `04-reading.md` §4, and the solver picks it like any route (owner call 5). Today the app's
`OCRCascade.off` has no escalation route and `onDisagreement` false [M, `OCRCascade.swift` header].

## 3. The rule for the settings layer

Sheet text, kind: "Your sample's mix, measured on this Mac: handwritten, typewritten, printed, forms and tables (N pages
sampled). Correct it if it is wrong. Clippings, newspapers and registers are not measured; tell us if you have them."
Kinds not measured are asked in the interview, labelled "not measured" (section 2 pick, call 4). Cascade text: note
04's. Sheet text, mixed: "Read handwriting on typed pages (signatures, dates, notes in the margin). Measured level on
typed pages, not measured on mixed pages." with Mac time "figure pending" (section 2 pick, call 1).

- Comparison metric. Classifier: pages right per kind on the owner's 141 and the public 895, and NES lost when the 96
  are routed by its calls against routing by the labels; tie when the paired bootstrap intervals overlap, as ours +1.00
  (-0.02 to +3.04) and ATRIUM's +1.18 (+0.03 to +3.32) do [M, `kind-atrium.md` §3]. Cascade rows are ranked by
  note 04's metric and tie rule, on their split-half figure [M, `difficulty.md` §4].
- Kind rules. A page goes to its kind's pick from the reading stage, which note 04 owns per profile (its §9 and
  Owner's calls); this note does not pick readers. What the app ships today is `ocr-page-guidance.json` (measured
  2026-10-15, before the hands rescore): handwritten and typewritten to Gemini 3.8 Flash (96.0, 98.7), printed to
  Claude Sonnet 5.5 (96.3), forms to Qwen3.6 27B (96.2, 4 pages, "a hint"); Gemini 3.8's handwritten 96.0 is 95.81 on
  the corrected truth (`ocr-hands-rescore.json`, OCR-1). The settings build replaces it with 04's rows. A page whose
  top class is under 0.8 keeps the run's model [M, K-kinds §5 citing W41.app-page-kind]. No low-resolution flag: neither image size nor text height catches the pages that fall [M,
  `kind-classifier.md` §6]. Mixed pages have no class: the learned rows count them as handwriting [M, `kind-classifier.md`
  §1], so a mixed page goes to the handwritten pick. Clippings and newspapers take their kind from layout, not hand
  (`03-layout.md`) [I, K-kinds §6.1].
- Kind routing is worth most on cheap routes: on the 96, routing by the true kinds reads 97.26 against 96.47 for the best
  single reader, and by our classifier 96.26 [M, `kind-classifier.md` §4]. On R4 and R5 the solver may show kind routing
  as worth under a point [I, K-kinds §5].
- Cascade mechanics (rows in note 04). Failure is the only trigger, the Vision word-count trigger opt-in (owner call
  5); the two-reader disagreement trigger is not offered (`difficulty.md` proposed rule, step 3: "wants a larger
  test"). A breaker caps escalation after 20 pages at 25% of the run's pages; a page the escalation route also fails is `CascadeExhausted` and is not auto-retried [M, `OCRCascade.swift`].
- Must not run. Classifier: when the bundled weights fail to load, every page keeps the run's model [M,
  `PageKindClassifier.swift`]. Cascade: never on a remote gateway, the Local Agent, Apple Vision as first reader or the
  Tools diagnostics [M, `OCRCascade.swift`].

## 4. Table rows

```json
[
{"id":"kind-vision-lr","name":"Vision signals + feature print, LR (shipped)","family":"mac","app_route":null,"status":"shipped","needs":{"key":[],"plan":[],"cluster":false,"mac_gb":null,"gpus":0},"figures":{"handwritten":{"value":33,"n":34,"truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out)","attribute":"§1 handwritten","value":"33/34"}},"typewritten":{"value":70,"n":72,"truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out)","attribute":"§1 typewritten","value":"70/72"}},"printed":{"value":34,"n":35,"truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out)","attribute":"§1 printed","value":"34/35"}},"owner-all":{"value":137,"n":141,"interval":"93-99% (Wilson)","truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out)","attribute":"§1 right","value":"137/141 (93–99%)"}},"forms":{"value":13,"n":14,"false_calls":2,"truth":"owner-144 forms","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier, LR (leave-one-folder-out)","attribute":"§2 forms found, false calls","value":"13/14, 2"}},"public-895":{"value":723,"n":895,"interval":"78-83% (Wilson)","truth":"public-895 strata","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier (bundled weights)","attribute":"§4 right","value":"723/895 (78–83%)"}},"mixed-flag":{"value":null,"precision_full_call":"36.65-42.99% (hand not mixed; 36.65-90.50% unrestricted)","recall_full_call":"12.44-14.29% (hand not mixed)","covered_frame":"recall 12.44%, precision 79.41%, conditional on the 1,881-page covered frame","n":221,"truth":"owner cut","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier handwritten","attribute":"§5 full-call point-completion sensitivity","value":"36.65%–42.99%"}}},"cost":{"usd_1000_list":0.0,"source":null},"time":{"per_unit_s":0.6,"measured":true,"measured_on":"M3 Pro 18 GB; 0.60 s a page on the 895","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"Shipped classifier (bundled weights)","attribute":"§7 Vision signals on the 895","value":"538 s (0.60 s a page)"}},"memory":{"peak_gb":null,"measured_on":"OS models, not measured apart","source":null},"caveats":["labels partly a session's and fitted on (KND-1)","fails L5 21/80 and N4 7/40; N6 14/40 (kind-atrium.md §4)","no mixed, clipping, newspaper or register class","mixed-flag precision: the full-call range is the figure (P4-1); the covered 79.41% is conditional"],"kind_rules":["a page whose top class is under 0.8 keeps the run's model","a mixed page counts as handwriting (kind-classifier.md §1)"],"fallback":"run's model","conditions":["off by default in the app (K-kinds §9)"]},
{"id":"atrium-zero-shot","name":"ATRIUM vit-historical-page v4.3, hand-only","family":"mac","app_route":null,"status":"measured","needs":{"key":[],"plan":[],"cluster":false,"mac_gb":null,"gpus":0},"figures":{"handwritten":{"value":34,"n":34,"truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"ATRIUM zero-shot, hand-only (top of its six text classes)","attribute":"§1 handwritten","value":"34/34"}},"typewritten":{"value":56,"n":72,"truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"ATRIUM zero-shot, hand-only (top of its six text classes)","attribute":"§1 typewritten","value":"56/72"}},"printed":{"value":31,"n":35,"truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"ATRIUM zero-shot, hand-only (top of its six text classes)","attribute":"§1 printed","value":"31/35"}},"owner-all":{"value":121,"n":141,"interval":"79-91% (Wilson)","truth":"owner-141 (KND-1)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"ATRIUM zero-shot, hand-only (top of its six text classes)","attribute":"§1 right","value":"121/141 (79–91%)"}},"forms":{"value":14,"n":14,"false_calls":24,"truth":"owner-144 forms","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"ATRIUM zero-shot, hand-only top class LINE_*","attribute":"§2 forms found, false calls","value":"14/14, 24"}},"public-895":{"value":638,"n":895,"interval":"68-74% (Wilson)","truth":"public-895 strata","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"ATRIUM zero-shot, hand-only","attribute":"§4 right","value":"638/895 (68–74%)"}},"mixed-flag":{"value":null,"precision_full_call":"69.82-69.82%","recall_full_call":"51.06-60.39% (unrestricted)","covered_frame":"recall 60.39%, precision 69.82%","n":563,"truth":"owner cut","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"ATRIUM TEXT (its top class)","attribute":"§5 full-call point-completion sensitivity","value":"51.06%–60.39%"}}},"cost":{"usd_1000_list":0.0,"source":null},"time":{"per_unit_s":0.11,"measured":true,"measured_on":"M3 Pro 18 GB, MPS, all in on the 895 (0.063-0.110 across sets)","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"the 895","attribute":"§7 s a page, all in","value":"0.110"}},"memory":{"peak_gb":1.48,"measured_on":"M3 Pro 18 GB, process peak; MPS driver 4.8 GB","source":{"file":"ArchiveProcessor/segbench-results/kind-atrium.md","route":"","attribute":"§7 peak resident memory","value":"1.48 GB"}},"caveats":["323 MB download","weights licence unsettled: CC BY-NC (kind-atrium.md §7) against MIT (K-kinds §8); item 'look up ATRIUM's weight licence'","right where ours is wrong on 3 pages, the reverse on 19 (p 0.000855)"],"kind_rules":[],"fallback":"run's model","conditions":["not offered while the shipped classifier is kept"]}
]
```

Cascade rows: none here; they are `04-reading.md` §4's (`casc-free-fail`, `casc-1-fail`, `casc-5-fail` and the
rest), with the split half in `value`, chosen from 18,538 candidates on 96 pages [M, `difficulty.md` §4].

The mixed switch's readers (body NES on the 96's 78 typed and printed pages against Vision 88.0): LightOnOCR-3 4B +1.8 (-2.2 to +5.9), 14 pages worse, $0; GLM-OCR +4.3 (+0.4 to +8.8), 20
worse, $0; Qwen3.6-27B hosted +7.3 (+2.6 to +12.3), 6 worse, $0.0019 a page; Gemini 3.7 Flash +9.4, $0.0039, not
ranked (a drafter's relative) [M, `mixed-route-bands.md`]. Their time rows are `measured: false` (P11-4).

Fields used beyond 00-index.md's schema: figure keys `owner-all`, `public-895`, `mixed-flag`; figure fields
`interval`, `false_calls`, `precision_full_call`, `recall_full_call`, `covered_frame`; `value` null on `mixed-flag`.

## 5. Caveats carried

- KND-1: the 144's labels are partly a session's, not blind, and the shipped weights were fitted on them; every owner-set
  row says so and is leave-one-folder-out.
- KND-2 (overturned "ATRIUM over-calls mixed"): the 139/144 that `kind-classifier.md` and `12-settings-design.md` §3.2
  quote uses the old mixed definition; this note uses the corrected 137/141 on the typed, printed and handwritten pages
  [M, `kind-atrium.md` §1]. Mixed is scored only against the owner's 170 answers.
- KND-3: the 33.02% mixed share [M, `mixed-def-score.md`] is shown with its interval, 33.0% (24.2-44.2%), signature-only
  8.7% (4.0-16.7%) [M, `mixed-route-bands.md`, interval made for KND-3].
- P4-1 (corrected by W46.kind-mixed-support): mixed-filter precision and recall are covered-frame estimates on 1,881 of
  2,000 pages with full-call sensitivity ranges (Qwen 90.91-99.39%), not confidence intervals; no mixed filter is
  established, so no rule pre-flags mixed pages [M, `kind-atrium.md` §5].
- P3-3: the marks core's weights are approximate; band figures are descriptive, never corpus-weighted routing benefit.
- P10-2 / MRK-1: Qwen3.6-27B pre-flagged the pages with 30 of 35 marks; it is not ranked on marks, and no switch row
  rests on its marks figures.
- P10-3: Gemini on mixed pages (W46.mixed-route-paid) was retired by the owner 2026-11-05; Gemini has no mixed row.
- P11-4: the "about 19 times" Mac time ratio compares a Vision batch wall with launch (1.31 s) against a LightOnOCR
  per-page wall without model load (24.4 s); the bench's 0.21 s Vision row would make it nearer 100 times. The sheet may
  not show a ratio until the like-for-like timing is made; "level" is said of typed pages only; mixed pages are unmeasured
  (2 pages, -12.1, -20.7 to -3.6) [M, `mixed-route-bands.md`, SUITE_TODO W46.mixed-route-setting].
- P11-1: a whole-page reader misses marks a box pass reads (union LightOnOCR 24, GLM-OCR 21 of 35 against 16 and 13); the
  two-pass question belongs to `06-marks.md`, and W46.marks-detect-own was reopened behind nice-to-have (owner
  2026-11-06, SUITE_TODO). The only cascade here is the OCR cascade.
- P8-3: the 96 were drawn through a 20-word Vision filter, so every cascade figure using Vision as second reader is on
  pages Vision could read (W46.ocr-96-vision-filter done). P8-2: on macOS 27.2 Vision returns nothing on 15 L7 pages;
  `difficulty.md` was regenerated 2026-11-04 after W46.vision-27-swap [I, file date and the swap's DONE entry].
- R-3: per-kind noise rests on 2-50 pages; the 2 mixed pages moving 9 points is anecdote. P6-2: the owner hand table is
  the 16 scored hand pages and 2 mixed pages.
- FLD-2: document kind (letter, article, clipping) is a tagging field, not this page-kind stage; the app maps a bare
  "article" to clipping then newspaper article, which FLD-2 says to fix before scoring. No clipping rule rests on it.

## 6. What would change the rule

- A classifier that beats 137/141 on the owner pages and 723/895 on the public set with a paired test, or fixes L5, N4
  and N6 (21/80, 7/40, 14/40 today) [M, `kind-atrium.md` §4].
- A mixed pre-flag with a measured full-frame recall and precision (today ATRIUM TEXT 51.06-60.39% recall, 69.82%
  precision; finite bounds 18-95%) would let the mixed switch act on flagged pages only.
- A body-text figure on mixed pages for the Mac handwriting reader at or above Vision; a like-for-like timing.
- The cascade's triggers: note 04 §6.
- A document prior: 16 of the 28 pages that differ from their document's majority hand are under the 0.8 floor, against
  78 of 848 pages overall; 24 of 193 multi-page documents hold more than one hand [M, `kind-churn.md`].

## 7. Owner calls

All five are decided (section "Owner's calls (2026-11-06)").

1. The mixed switch's form: one switch on every typed or printed page, off by default (owner call 3; section 2 pick).
   Evidence: the pre-flag guessed the band on 7 of 14 pages [M, `mixed-route-bands.md`]; no pre-flag is established
   (P4-1).
2. The cascade's default and trigger: owner call 5, owned by note 04 (its 7.2); this note's "no default beyond off" is
   superseded.
3. The mix shown and correctable: yes, with sample size, the classifier's error and unsure pages (section 2). Correct
   the design's "139 of 144, 0.2 s a page" to 137/141 and about 0.6 s a page [M, `kind-classifier.md` §6].
4. Kinds not measured (mixed, clippings, newspapers: 12 of 2,000 called by the lab sorter [M, `mixed-def.md`],
   registers: L4 called handwritten 80/80, low resolution) are asked in the interview, labelled "not measured".
5. ATRIUM's weight licence is a checkable fact, not a call: an item in section 8.

## 8. Items to file

- W46.mixed-route-setting (filed, S): add the like-for-like timing (per page, model load apart, both readers in one run
  outside an engine session) as its first step. Waits on Phase 4.
- Mixed-page body truth (M): a body-text score on mixed pages for Vision and the Mac and hosted handwriting readers,
  drawn at random under the owner's cut, not by a pre-flag. Done: a paired interval on at least the mixed pages of a
  fresh draw. Waits on owner sheet time.
- Settings design figures (XS): §3.2's 139/144 and 0.2 s a page corrected. Waits on nothing.
- OCRCascade comment drift (XS): it quotes AUC 0.78-0.89 for Vision's word count; `difficulty.md` §5 now gives 0.76 to
  0.88 [M, both files]. Waits on nothing.
- Gaps for the table (§3.9): classifier memory; kind figures for clippings, newspapers, registers. The cascade's gaps
  (the 895, the cluster profile, Mac memory per tier) are note 04's.
- Look up ATRIUM's weight licence (XS · $0): read the `ufal/vit-historical-page` model card and the repository
  licence file; K-kinds §8 says MIT, `kind-atrium.md` §7 says CC BY-NC [?]. Done when one licence is recorded with its
  source in `kind-atrium.md`. Waits on nothing; needed before any route bundles ATRIUM.
- Document prior below the floor (S): measure on the five boxes whether it fixes any of the 16 under-floor minority
  pages (needs per-page kind truth). Waits on nothing; priority is the owner's.

## 9. Profile test expectations

Every profile: the classifier is `kind-vision-lr` (137/141, 723/895); a page under 0.8 keeps the run's model; the
reader per kind is note 04's pick for the profile (its §9), not `ocr-page-guidance.json`'s. The mixed switch is off
unless the user turns it on (owner call 3); cascade picks are note 04's.

- Laptop, 16, 32, 64 GB: mixed switch reader LightOnOCR-3 4B (+1.8, a tie), time "figure pending".
- Cheap API: mixed switch reader Qwen3.6-27B hosted ($0.0019 a page, +7.3).
- Premium APIs or plans: the mixed switch has no premium reader row (Gemini retired); whole page [I].
- Cluster: mixed switch reader GLM-OCR (+4.3, $0); classifier still on the Mac.
- Plus a coding agent: as the base profile; this stage has no kit row.

## Owner's calls (2026-11-06)

From `14-owner-calls.md`; section 3 is amended where a call changes it.

- **Call 3.** A user who skips both interviews gets "Free, on this Mac", the mixed switch off until its time cost is
  measured like for like (P11-4).
- **Call 5, the failure cascade (this note's call 2; note 04 call 7.2).** A route like any other: each measured cascade
  is a row with its own figures on the reading chart, picked by the solver when it beats the single routes within the
  user's limits; no on/off default; failure the only trigger; word count opt-in. Note 04 owns the rows; this note's
  cascade rows and recommendation are withdrawn.
- **Section 2's kinds picks (calls 1, 3-5; owner may veto).** One mixed switch on every typed or printed page, its
  wording and "figure pending" time as in section 3, off by default; the mix shown with sample size, the classifier's
  error (137 of 141; 723 of 895) and pages under 0.8 as unsure; unmeasured kinds asked, labelled "not measured";
  ATRIUM's licence noted, moot while ours is kept (section 8).

Files read: execution-plans/processing-review/00-plan.md (1-105), 13-stage-rules/00-index.md (worktree), K-kinds.md
§5, 6, 8, 9, 11-measurement-audit.md (FLD-2, KND-1 to 3), 12-settings-design.md (§3.2, 3.4, 3.9 lines), measure-reviews
(R-3, P3-3, P4-1, P6-2, P8-1 to 3, P10-2, P10-3, P10-10, P11-1, P11-4, P11-8); segbench-results kind-classifier.md,
kind-atrium.md, kind-churn.md, mixed-def.md, mixed-def-score.md, mixed-route.md, mixed-route-bands.md,
ocr-page-guidance.json; ArchiveOCRBench/difficulty.md §4, 5 and rule; OCRCascade.swift and PageKindClassifier.swift
headers; SUITE_TODO.md (W46.mixed-route-setting, W46.review-phase4, W46.marks-detect-own); SUITE_TODO_DONE.md entries for
W46.vision-27-swap, W46.kind-mixed-support, W46.ocr-96-vision-filter, W46.hands-owner-pages, W46.marks-two-pass; for the
2026-11-06 edits, `ocr-hands-rescore.json`, `04-reading.md`, `14-owner-calls.md`.
