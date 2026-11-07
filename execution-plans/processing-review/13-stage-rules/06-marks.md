# 06. Marks: annotations, stamps, signatures, marginalia (Phase 4 stage rule)

Drafted 2026-11-06 from the strand notes, the result notes, `11-measurement-audit.md` and the passes under `measure-reviews/`. Figures carry [M] measured, [I] inferred, [?] unverified, each with its file. Checked against the passes and walked with the owner on 2026-11-06 ("Owner's calls" below).

## 1. Stage and question

The stage would find handwritten annotations, marginal notes, stamps and signatures on a page as boxes, read each one, and write them into the output as a marks layer (an invisible text run at each mark's box, labelled as a mark, not as body text; `D-enhancement.md` section 6.5). The user would choose whether the layer is written and by which route. Today there is nothing to choose: no route measured here produces a layer worth offering, and marks are kept by never altering the reading copy.

## 2. Is there a choice?

No (yet). The rule, the measured reason and the switch:

- Rule: the app offers no marks layer. Marks are preserved on the reading copy by the enhancement rule below (owner, 2026-10-20: "seemingly incidental marks are evidence and are preserved", `00-plan.md`).
- Measured reason: no detector is a marks layer, and no whole-page reader's reading carries placeable coordinates except Apple Vision's. Detection is in section 4's evidence; reading is in section 3.
- Switch: none ruled. The reading copy's one switch (Straighten) belongs to `01-reading-copy.md`, not to this stage. No marks switch is filed until a route clears section 6.
- The future route is a two-pass layer: the whole-page reading plus a region reading at each mark's box, so a mark is read when either reading reads it. It needs a box source (section 6) and a placement path for readers whose replies carry no coordinates.

## 3. The rule for the settings layer

Sheet text: "Marks (stamps, signatures, handwritten notes): not offered yet. Your page images are never altered to hide them, and the page reading includes them where the reader can read them."

- Metric and tie rule [M, `marks-read.md`, `mixed-route.md`]: marks read, count of the 35 owner-reviewed mark texts with NES >= 0.8 on the 32 detector-eligible owner-core pages. Tie: a gap inside the page-bootstrap interval, about 20 points (`marks-read.md` card: "the two readers tie on the oracle boxes"). Detection recall is reported beside it with its own interval of about 14 points (`marks-detect.md` card).
- Kind rules: handwritten, forms, typed and clippings all get no marks route. Newspapers and any layout route: region routes must keep picture regions or the layer is dropped (`layout-order-marks.md`: DocLayout-YOLO's app filter, text and title only, keeps 7 of 45 marks; with pictures and tables kept, 26 of 45; PP-DocLayoutV3 text classes 2 of 45) [M]. This is a rule for the layout stage (`03-layout.md`), carried here.
- Fallback: if a route is ever added and fails on a page, write no layer for that page and keep the raw image. Never write a partial or merged layer.
- Must not run at all: any enhancement whose output replaces the stored reading copy (`enh-ocr-marks.md` verdict). Content-removing methods may produce an OCR input only, and the review found none helps any reader (`enh-ocr-input`, cited in `enh-ocr-marks.md`), so the OCR input stays the raw image.
- Enhancement rule for marks [M, `enh-ocr-marks.md`, P9-5]: the reading copy and the OCR input both stay the raw image, and no enhancement is offered for viewing either (owner, 2026-11-06, recorded in `01-reading-copy.md`). `enh-ocr-marks.md` named a gain-only shading division as the one method that could be offered for viewing; it is not offered. It keeps 97.3% of faint-inclusive ink in the mark boxes against the re-encoding floor's 97.9%, loses 0 of 85 boxes, but greys coloured marks: paired by page against the floor, -18.2 colour points (-33.0 to -4.7) with faint ink and -20.7 (-37.4 to -5.4) clear, on the 14 pages and 31 boxes with coloured ink (P9-5: a resolved loss, not noise). GCDRNet erases faint ink (84.9% kept, 6 of 85 boxes lost on 3 pages). SBB keeps 75.9%, loses 13 boxes on 5 pages and all colour (0.0%). Counts: 85 boxes on 28 of the 40 pages, 14 with colour (P9-5).

## 4. Table rows

The stage object for `settings-routes.json` (schema in `00-index.md`):

```
{"id": "marks", "name": "Marks: annotations, stamps, signatures, marginalia", "unit": "pages", "choice": false,
 "metric": {"id": "marks_read_nes08", "label": "Marks read (NES >= 0.8), of 35 owner-core marks", "higher_is_better": true},
 "kinds": [], "rules": [{"id": "marks-not-offered", "text": "No marks layer is offered; marks stay on the untouched reading copy.", "source": "marks-detect.md §What this says", "switch": null},
           {"id": "marks-raw-reading-copy", "text": "The reading copy and the OCR input stay the raw image; shading division is not offered for viewing.", "source": "enh-ocr-marks.md §Verdict", "switch": null}],
 "fallback": "raw image, no layer", "routes": []}
```

Routes: none. The measured candidates are not rows because none is a layer; their figures are kept here for the future table.

| Candidate | Result | File |
|---|---|---|
| PP-DocLayoutV3 Seal + Aside Text | 0 of 45 marks found, 1 box emitted [M] | marks-detect.md |
| YOLO11m (AnnoPage + SignverOD), floor 0.25 | 8 of 45 (18%, 5-37), precision 53% [M] | marks-detect.md |
| same, floor 0.05 | 17 of 45 (38%, 21-60), precision 42% [M] | marks-detect.md |
| same, Core ML on the M3 Pro | 8 of 45 at 0.25; median 0.43 s a page, an engine session's timing, so an upper bound [M] | marks-detect.md |
| LightOnOCR-3 4B, owner's box | 17 of 35 read (mean NES 0.62) [M] | marks-read.md |
| Apple Vision, owner's box | 13 of 35 read (mean NES 0.59) [M] | marks-read.md |
| LightOnOCR-3 4B through YOLO11m boxes | 4 of 35 at floor 0.25; 6 at 0.05 [M] | marks-read.md |
| Whole page, no box: Vision / LightOnOCR-3 4B / GLM-OCR | 14 / 16 / 13 of 35 [M] | mixed-route.md |
| Whole page plus the owner's box (oracle union) | Vision 17, LightOnOCR-3 4B 24, GLM-OCR 21 of 35 [M] | mixed-route.md, "Two passes" |
| Whole page plus YOLO11m box | adds 0-3 per reader, none significant (p >= 0.5) [M] | mixed-route.md, SUITE_TODO_DONE W46.marks-two-pass |

## 5. Caveats carried

- MRK-1 (circular set): the 150-page set was drawn partly from Qwen3.6-27B's pre-flag. Respected: the A-core (16 pages, independent of every route) and B-core (24, from the pre-flag) are reported apart, descriptive, no population weights (`marks-scan.md`, `marks-set-freeze.md`). Qwen3.6-27B (26 of 35 whole page, unranked) is not ranked on these pages: 30 of 35 marks lie on B-core pages (P10-2).
- MRK-2 (look by eye, run a model audit): process finding, no figure; the owner's core check replaced it (`marks-set-reconciled.md`).
- P3-3 (phase fractions are not validated inclusion weights): every core figure here is descriptive of an enriched set; no population recall, prevalence or corpus-weighted benefit is stated. Only 16 of the 50 phase-A pages carry owner truth (`marks-scan.md`).
- P11-1 (W46.marks-detect-own retired on a misreading): corrected. The run condition is met: a whole-page reader misses 19-22 of 35 marks, and with the mark's own box LightOnOCR-3 4B and GLM-OCR each read 8 more of 35 (sign test p = 0.016 and 0.008 against an irrelevant second reading; Vision +3, p = 0.25) [M, `mixed-route.md`]. The whole-page rerun was identical on 32 of 32 [M], so the gain is not read-to-read noise (LightOnOCR's determinism rests on that one rerun). The gains are oracle boxes, mostly on the B-core (B-core +3, +7, +5; A-core +0, +1, +3), so a trained detector would get less. The tracker shows the reopening done: W46.marks-detect-own is behind W46.nice-to-have (SUITE_TODO.md; owner, 2026-11-06 walkthrough).
- P9-10 (ranking the drafter on its own boxes): no Gemini 3.7 Flash box arm is ranked on the core; W46.marks-detect-paid was retired unrun (2026-11-05). Gemini 3.7 Flash drafted 20 of the 35 texts verbatim (P10-3), so no Gemini mark figure appears here and none is implied.
- P10-9 (wording): "both readers deterministic" is stated as Vision measured identical (two runs, 32 of 32 pages, P10-2), LightOnOCR asserted then one rerun identical; "45 boxes" are on 20 of the 32 pages (P9-6c), 12 pages carry none.
- P9-5: colour loss is stated as resolved (section 3). P9-6: marks in layout coverage are coverage, not reading; 9 of Vision's 30 covered marks touch print.
- The post-hoc rule "Vision where LightOnOCR answers nothing" (18 of 35) is a hypothesis, not a ranked route (`marks-read.md`).

## 6. What would change the rule

- A box source that reaches the union. Trigger: on pages the pre-flag did not choose (the A-core, or new independent owner pages), a detector or whole-page reader that matches the oracle-box union (LightOnOCR-3 4B 24, GLM-OCR 21 of 35) within the interval, with recall well above today's best 17 of 45 at floor 0.05 [M]. Today's YOLO11m is 8 of 45 at its default floor.
- A reader that places its own marks. LightOnOCR-3 4B, GLM-OCR and Qwen3.6-27B replies carry no coordinates (0 of 32 each); only Apple Vision's carry a box per line, and 13 of its 14 whole-page reads are read again from the lines meeting the mark's box [M, `mixed-route.md`]. A reader that returns boxes removes the detector need.
- A stronger whole-page reader that reads marks well alone (not measured on independent marks; P11-1 notes these pages cannot rank it).
- Owner evidence on pages beyond the 32 (8 core pages stay excluded; `marks-set-reconciled.md`).

## 7. Owner calls

1. Is a marks layer offered at all today? Settled: no (section 2). Evidence: no detector is a layer (`marks-detect.md`), marks read from perfect boxes are 17 of 35 for LightOnOCR-3 4B (`marks-read.md`).
2. What the two-pass route would offer and what it waits on. Shown settled as a description, not an offer: whole page plus box reading, up to LightOnOCR-3 4B 24 and GLM-OCR 21 of 35 against 16 and 13 whole page [M]. It waits on a box source (W46.marks-detect-own, behind W46.nice-to-have; 110 non-core pages as training data, Sherlock size review first, SUITE_TODO.md) and on placement for VLM readers. Settled by the tracker; no call.
3. How marks are preserved on the reading copy: settled as the enhancement rule (section 3). The residual question, whether shading division is offered for viewing given -18.2 colour points on marks (-33.0 to -4.7), is settled: not offered (owner, 2026-11-06; the call's home is `01-reading-copy.md`).

## 8. Items to file

- Correct the fixed rule text in `settings-design/figures.json` ("fixed"/marks). It reads "No detector found a mark (0 of 45 boxes)", which is true only of PP-DocLayoutV3. Replace with the YOLO11m figures and the two-pass state. Offline, $0, size S, waits on nothing. Done when the text matches `marks-detect.md` and a drift test passes. [M]
- Add per-route marks rows and the generator's `noise` entry (metric, tie of about 20 points, source) when `settings_routes.py` is built. Size S, waits on that item.
- Independent marks truth for any detector ranking: at least a second owner draw of pages the pre-flag did not choose (MRK-1 fix), since the A-core holds 5 of the 35 marks. Size M, owner time needed; waits on W46.marks-sampling-support and the owner. [I]
- Resolve the 8 excluded core pages (unmerged relationship boxes, an unboxed rejected mark, a sideways page) so they can become detector truth (`marks-set-reconciled.md`). Size S-M, owner or Gemini pass.
- A placement test: a VLM that returns boxes with its text, scored on whether the box meets the owner's mark box. Not filed anywhere ("nothing open carries" it, P11-1). Size M, offline for open models.
- Test the post-hoc Vision-fallback rule on new marks pages (`marks-read.md`). Size S, waits on new independent marks.
- Whether the colour measure reads divided images differently was not tested (`enh-ocr-marks.md`); size S, offline.

## 9. Profile test expectations

Every profile and every document kind: the solver offers no marks layer and selects no route; the stage shows its sheet text and writes nothing. Rows deciding: `routes` is empty and `choice` false.

| Profile | Pick | Decided by |
|---|---|---|
| 1. Laptop, open weights, 16, 32, 64 GB | none; raw reading copy | no row; YOLO11m Core ML 8 of 45 is not a layer |
| 2. Cheap API | none | no row; no hosted-reader marks arm is ranked (P9-10, P10-3) |
| 3. Premium APIs or plans | none | same; Gemini marks arms retired unrun |
| 4. Cluster | none now; the detector fine-tune is queued behind nice-to-have | W46.marks-detect-own |
| 5. Any plus a coding agent | none; the kit does not train a marks detector | no kit stage |
| Any kind (handwritten, typed, forms, clippings, newspapers, non-Latin, early modern) | none; layout routes must keep picture regions | `layout-order-marks.md` 7 versus 26 of 45 |

R5, plans through a local CLI: none found. The gap audit's marks row for R4 and R5 names Gemini 3.8 Flash or Claude Sonnet 5.5 asked for boxes, or inline region tags, untested (10-gap-audit.md, marks rows); the plan-route arm of W46.marks-detect was skipped under the owner's plan-routes rule. R6, commercial document services: none found as a route. Azure DI Read's per-line `isHandwritten`, Textract's `TextType` and Document AI's `styleInfo` are documented and unmeasured on our pages (10-gap-audit.md, marks R6 row; K claims 18-20); the Azure flags served as a drafting aid (MRK-1), not a route. Every marks figure above is on the owner core; no public marks set was scored.

## Owner's calls (2026-11-06)

From `14-owner-calls.md` §1 call 6 and §2 "Marks".
- No marks layer is offered (call 1, unchanged).
- Shading division is not offered for viewing; note 06's earlier "may be offered for viewing" is withdrawn. Section 3's rule and the `marks-raw-reading-copy` rule text now say so (call 3, settled).
- The two-pass route stays described, not offered, behind W46.marks-detect-own, which waits on W46.nice-to-have as the owner set it in the 2026-11-06 walkthrough (call 2). The former call 4, which asked whether that status should change, is deleted: it re-asked a decision the owner took that day.
- Region routes must keep picture regions (7 of 45 marks kept by the app's filter against 26).

Files read: execution-plans/processing-review/00-plan.md; 13-stage-rules/00-index.md (worktree); 14-owner-calls.md; 10-gap-audit.md (marks rows); K-kinds.md and D-enhancement.md (marks passages by grep); 11-measurement-audit.md lines 481-493; measure-reviews 2026-10-31-3, 2026-11-05, 2026-11-05-2, 2026-11-05-3 (P3-3, P9-5, P9-10, P10-2, P10-3, P10-9, P11-1); SUITE_TODO.md (W46.marks-detect-own, review-phase4 lines); SUITE_TODO_DONE.md (W46.marks-two-pass entry); settings-design/figures.json (marks "fixed"); segbench-results/marks-detect.md, marks-read.md, marks-scan.md, marks-set-draft.md, marks-set-freeze.md, marks-set-reconciled.md, marks-preflag-pilot-review.md, enh-ocr-marks.md, layout-order-marks.md, mixed-route.md (Two passes, per-class table).
