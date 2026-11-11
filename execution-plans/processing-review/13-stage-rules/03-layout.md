# 03 Layout and reading order (Phase 4 rule note, draft)

Tags: [M] measured, [I] inferred, [?] unverified. Every figure names its file. Corrections cite the pass id.

## 1. Stage and question

The stage decides whether a layout detector runs before reading (regions first), which detector, on which kinds, and how the regions and lines are ordered.
The user chooses nothing here: the choice is a rule by kind, because the whole page beats every detector on every kind but newspapers.

## 2. Is there a choice?

No. The rule, with the measured reason:

- Newspapers and other dense multi-column print get a detector, then regions in a geometric order. A detector gains on the whole page only here: L9 whole 29.2 NES against PP-DocLayoutV3 86.2 [M, layout-photo-tables.md]. The whole-page figure is partly the reader's token cap (GLM-OCR fails or returns nothing on 9 of 15 whole pages), so the gain is operational, not proof that layout helps transcription (measure-reviews/2026-11-01.md, P4 finding on layout).
- Every other kind reads the whole page. On the 96 the whole page scores 90.9 and the best detector, heron, 87.1 (-3.9 [-7.7, -0.3]) [M, layout-photo-tables.md].
- Handwriting and registers never get a detector (below).
- No switch. The owner ruled none for this stage, and the figures give no kind where the user's own taste decides.
- Routes in view (E-layout.md section 9): R1 Apple Vision document request is not a substitute (L9 16.8 NES; worst of the arms on the illumination and warping conditions, 70.2 and 61.3, though above YOLO with the app sort on Scanning and Skew) [M, layout-photo-tables.md]. R2 and R7 use the same detector. R3 to R5 keep the detector on the Mac and send regions. R6 none recommended (E-layout.md section 9: none measured on archival photographs; test 10 unrun) [?]. R8 is the kind gate itself.

## 3. The rule for the settings layer

Sheet text: "Newspapers and other dense multi-column pages are read in regions, column by column. Everything else is read as a whole page. Handwriting and registers are never split into regions."

- **Metric and tie rule.** Reading: strict NES (higher is better), paired difference over the same pages with a 95% page bootstrap; an interval that crosses 0 is a tie; per-kind groups under 20 pages are descriptive [M, layout-photo.md card]. On the 96 a gap is also a tie when under twice the rerun range, 0.49 NES points for Gemini 3.7 Flash [M, ocr-rerun-noise.md as applied in measure-reviews/2026-10-31.md R-2]. Order: Kendall tau over placed lines on pages placing at least 15 lines, with the benchmark guard (60% of truth lines) where the set has it [M, layout-order.md, layout-order-marks.md]. Ties as above.
- **Detector on newspapers: PP-DocLayoutV3** (MLX port, 1,024 px, confidence 0.5). Reasons: it is the only detector inside the noise on Real5 Scanning (91.7 against 92.1 whole, -0.4 [-3.4, +2.5]) and loses 10.0 on Skew where DocLayout-YOLO loses 40.1 and keeps no region on 58 of 155 pages [M, layout-photo.md, layout-photo-tables.md]; it finds the manuscript regions YOLO misses (tau 0.999 on all 15 multi-column benchmark pages, YOLO valid on 5) [M, layout-order.md]; licence Apache-2.0 [E-layout.md section 9]. DocLayout-YOLO is not shipped as the detector (layout-photo.md, open decision 1). Paired on the 15 L9 scans through four readers, DocLayout-YOLO (newspaper-ocr) beats it: PP-DocLayoutV3 is -4.6 [-8.0, -1.1] strict NES behind on the readers' mean (85.6 against 90.2), beyond the interval for GLM-OCR, LightOnOCR-3 4B and Qwen3.6-27B, a tie for PaddleOCR-VL 1.5, and -2.0 [-2.9, -1.0] order-free [M, layout-pair-newspapers.md]. The choice stands on photographs (above, and 70.9 against 84.9 on the 96), which the owner's pages are; on scanned newspapers it costs about 5 points.
- **Order, when regions run: the detector's own order.** On L9 PP-DocLayoutV3's native order gives tau 0.881, word accuracy 37.2% and gap 23.4, the best of the arms on the last two; the app region sort on YOLO regions has tau 0.905 and the lowest reading-order edit (0.147); HDBSCAN 0.922. These are not separable at n 15 (layout-order.md, caveats). The app region sort run on PP-DocLayoutV3's own regions was not run on L9; on the 96 it is 0.961 against 0.992 for native order, a tie by interval (+0.014 [-0.005, +0.040] against the YOLO base) [M, layout-order-marks.md] [?] for L9.
- **Order, when no detector runs: the line order the reader gets.** Vision's line order 0.972 and the app's line column sort 0.971 on the 96, keeping 100% of lines, a tie (Vision +0.027 [+0.001, +0.056], column sort +0.026 [-0.004, +0.057], both against the YOLO base) [M, layout-order-marks.md]. No trained orderer (W46.layout-order-train moves behind W46.nice-to-have, per layout-order-marks.md).
- **Kind rules.** Newspapers and dense multi-column print: regions. Typed single-column, clippings, tables, forms, periodicals: whole page. Handwritten and registers: no detector. An uncertain kind reads the whole page [I]. The kind comes from the router (139 of 144 pages, about 0.6 s a page on the M3 Pro, kind-classifier.md); whether it has a newspaper label is not in these inputs [?].
- **Before the stage on a photograph: quad correction.** The quad lifts PP-DocLayoutV3 by 7.4 on Skew [+4.9, +10.0] and 0.8 on Warping (a tie) [M, layout-photo-tables.md]. Whole-page dewarping for OCR still does not pay (whole page +1.7 [-0.3, +4.2] on Skew with the quad). Newspapers photographed, rather than scanned, are unmeasured [?]: L9 is scans.
- **Fallback when the detector fails a page.** Read the whole page. PP-DocLayoutV3 answered 15 of 15 on L9 and read nothing on 1 of 96 owner pages [M, layout-photo-tables.md, layout-photo-hands.md]. The threshold for "failed" (regions cover too little of Vision's ink) is not measured [?]. PP-DocLayoutV3 reads 69.4% of ink on L9 on average and 6 of 15 pages under 80% [M, layout-photo-hands.md], so a miss is common; see items.
- **When the stage must not run.** Handwritten pages and registers: on the 96's 16 handwritten pages PP-DocLayoutV3 scores 70.5 against 85.8 whole (-15.3 [-28.2, -4.4]); on L4's 80 registers 48.9 against 59.7 (-10.8 [-14.8, -6.8]); YOLO scores 14.2 and 1.6 and reads nothing on 10 of 16 and 49 of 80 [M, layout-photo-tables.md, layout-photo.md]. The 96's 16 handwritten pages are a descriptive group (under 20 pages); the rule holds on L4's 80 registers and on direction. Premium readers on newspapers: detector first (owner, 2026-11-06).
- **Marks.** A region pass drops marks: the app's DocLayout-YOLO filter keeps 7 of 45 marks, 26 with pictures and tables kept; PP-DocLayoutV3 keeps 3 at most [M, layout-order-marks.md, confirming LAY-2]. If regions run, pictures stay in the stream or marks are read in stage 06's own layer.

## 4. Table rows

The stage object, replacing the design's fixed text (figures.json "fixed" layout rule names PP-DocLayoutV3 and the two never-run kinds; this note adds the quad and the fallback). Its `routes` list is the two rows in the second block:

```
{"id":"layout","name":"Layout and reading order","unit":"pages","choice":false,
 "metric":{"id":"nes","label":"strict NES","higher_is_better":true},
 "kinds":["newspapers","typed","clippings","tables","handwritten","registers"],
 "rules":[{"id":"layout-regions-newspapers","text":"Newspapers and dense multi-column print: PP-DocLayoutV3 regions, the detector's own order, quad correction first on a photograph.","source":"layout-photo-tables.md §L9","switch":null},
  {"id":"layout-whole-otherwise","text":"Every other kind, and an uncertain kind, reads the whole page in the reader's line order.","source":"layout-photo-tables.md §the 96","switch":null},
  {"id":"layout-never-hands-registers","text":"No detector on handwritten pages or registers.","source":"layout-photo-tables.md §handwritten","switch":null},
  {"id":"layout-fallback-whole","text":"A page the detector fails reads whole.","source":"layout-photo-tables.md §the 96","switch":null}],
 "fallback":"whole-page"}
```

```
{"id":"pp-doclayoutv3","name":"PP-DocLayoutV3 regions, then the reader","family":"mac","app_route":null,"status":"measured",
 "needs":{"key":[],"plan":[],"cluster":false,"mac_gb":16,"gpus":0},
 "figures":{"newspapers":{"value":86.2,"n":15,"truth":"L9 published transcriptions","source":{"file":"layout-photo-tables.md","route":"L9 pp-doclayoutv3","attribute":"NES strict","value":"86.2"}},
            "typed":{"value":94.7,"n":41,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"typed pp-doclayoutv3","attribute":"NES strict","value":"94.7"}},
            "clippings":{"value":81.8,"n":13,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"clippings pp-doclayoutv3","attribute":"NES strict","value":"81.8"}},
            "tables":{"value":82.8,"n":12,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"tables pp-doclayoutv3","attribute":"NES strict","value":"82.8"}},
            "handwritten":{"value":70.5,"n":16,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"handwritten pp-doclayoutv3","attribute":"NES strict","value":"70.5"}},
            "registers":{"value":48.9,"n":80,"truth":"L4 published transcriptions","source":{"file":"layout-photo-tables.md","route":"L4 pp-doclayoutv3","attribute":"NES strict","value":"48.9"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":0,"price_read":null,"source":{"file":"E-layout.md","route":"section 7","attribute":"detectors are free everywhere","value":"free"}},
 "time":{"per_unit_s":0.47,"measured":true,"measured_on":"M3 Pro CPU, the lab's 2026-10-16 run that measured the 794 MB","source":{"file":"E-layout.md","route":"claim 36","attribute":"detect s a page","value":"0.47"}},
 "memory":{"peak_gb":0.794,"measured_on":"RSS of the MLX port, 128 MB weights, same run","source":{"file":"E-layout.md","route":"claim 36","attribute":"peak RSS","value":"794 MB"}},
 "caveats":["a second run gives 0.27 s a page (layout-photo-hands.md), likely background QoS (LAY-3); re-timing owed","L9 is scans; photographed newspapers unmeasured","on L9 scans DocLayout-YOLO beats it by 4.6 NES paired (layout-pair-newspapers.md)","regions drop marks (LAY-2)","96 deltas order-sensitive (OCR-6)","one reader, GLM-OCR (layout-photo.md card)"],
 "kind_rules":["newspapers and dense multi-column: regions","handwritten, registers: never","all other kinds: whole page"],
 "fallback":"whole-page","conditions":["quad correction first on a photograph"]}
{"id":"whole-page","name":"Whole page, no layout stage","family":"mac","status":"shipped",
 "figures":{"typed":{"value":94.0,"n":41,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"typed whole","attribute":"NES strict","value":"94.0"}},
  "clippings":{"value":86.9,"n":13,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"clippings whole","attribute":"NES strict","value":"86.9"}},
  "tables":{"value":91.9,"n":12,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"tables whole","attribute":"NES strict","value":"91.9"}},
  "handwritten":{"value":85.8,"n":16,"truth":"owner-96","source":{"file":"layout-photo-tables.md","route":"handwritten whole","attribute":"NES strict","value":"85.8"}},
  "registers":{"value":59.7,"n":80,"truth":"L4 published transcriptions","source":{"file":"layout-photo-tables.md","route":"L4 whole","attribute":"NES strict","value":"59.7"}},
  "newspapers":{"value":29.2,"n":15,"truth":"L9 published transcriptions","source":{"file":"layout-photo-tables.md","route":"L9 whole","attribute":"NES strict","value":"29.2"}}},
 "caveats":["newspaper figure is GLM-OCR hitting its token cap on 9 of 15 pages"]}
```

The cluster route has no row in this stage's table; see owner call 4 (shown settled).

## 5. Caveats carried

- LAY-1: "the app's region sort needs no change" is reworded to "the best geometric rule on print where the detector finds regions"; it rests on 5 multi-column pages plus 15 newspaper pages, the other 10 failing on YOLO finding no body region. The owner-page verdict is layout-order-marks.md's (tau 0.945 for that sort on the 96, below native PP-DocLayoutV3 0.992). Respected: the order rule names the detector's own order, not the app sort.
- LAY-2: detection is held fixed per detector, with YOLO pictures kept, in layout-order-marks.md. Respected: the rule keeps pictures in the stream and the handwriting kind rule does not rest on YOLO's picture filter alone; PP-DocLayoutV3, which labels almost no hand a picture (3 of 80 L1 pages), still loses 15.3 on the 96's hands [M, layout-photo-hands.md, layout-photo-tables.md].
- LAY-3: Mac seconds (YOLO 1.77 s a page in layout-photo-hands.md against 0.51 s in the gap audit) were likely background QoS. Respected: no seconds figure is a route decision here; the row pairs claim 36's 0.47 s with the same run's 794 MB, names the 0.27 s run in a caveat, and the re-time is an item.
- OCR-6: the region losses on the 96 are order-sensitive NES on a truth the gap audit read as having no order. Respected: the kind rules rest on direction and intervals, not size; the typed tie and the hand and register content losses stand ("probably stands", OCR-6); rescoring order-free is W46.ocr-rescore-offline. layout-photo-tables.md uses the same strict NES, so its 96 deltas carry the same caveat [?].
- R-2 (measure-reviews/2026-10-31.md): the -0.18 bowF1 for tiles on typed pages is a tie by the rerun rule; whole-page reading stays the default on the intervals that matter (-7.5 and -2.4 on the 96). Respected: no kind rule rests on a gap under 0.49 points; typed ties (+0.6, +1.7, +2.2) are ties and not a reason to run a detector.
- P10-4 (measure-reviews/2026-11-05-2.md): Gemini's own block order changes no default. "Ties" is over each arm's kept lines: Gemini places 69% of truth lines on its 66 valid pages against Vision's 86%; the 96's order truth is the drafters' shared order, a relative of Gemini; the gap to PP-DocLayoutV3 (-0.013 to -0.019) is about the read-to-read shift (+0.011 [-0.009, +0.037]) [M, layout-order-paid.md]. Respected: no rule sends a page to a model for its order, and the tau table is given with its kept-line shares.
- P9-6 (measure-reviews/2026-11-05.md): PP-DocLayoutV3's 0.992 is tau over the lines it keeps (+0.020 [+0.002, +0.048] over Vision's line order on 66 pages, 2,788 against 2,974 lines); Vision's 30 of 45 marks are coverage and 21 of 27 clear of print is the purer figure; the marks lie on 20 of the 32 pages. Respected: the rule gives no "best orderer" claim.
- P4-3 (measure-reviews/2026-11-02.md): layout-photo-tables.md now carries its card; numeric verdicts unchanged.
- Newspaper gain under per-crop caps (measure-reviews/2026-11-01.md): carried as the operational caveat in section 2.
- Vision caches on 26.6 (measure-reviews/2026-11-04-2.md): the 96 excludes pages Vision read as empty, so Vision comparisons there are on readable pages.

## 6. What would change the rule

- A pair test on L9 and photographed newspapers in which another detector clears PP-DocLayoutV3 beyond its interval after the quad. The L9 half is met: DocLayout-YOLO through newspaper-ocr clears it by 4.6 [1.1, 8.0] strict and 2.0 [1.0, 2.9] order-free, paired over four readers [M, layout-pair-newspapers.md]. The photographed half is unmeasured (no photographed newspaper set with truth; W46.layout-photo-newspapers, behind W46.nice-to-have), and photographed modern print points the other way (Real5 after the quad, above).
- A reader at or above the 27B class on a cluster or a premium model on newspapers that ties regions on L9 (whole 0.967 against regions 0.965 for Qwen3.6-27B, E-layout.md section 5, claim 34): then regions on newspapers become a cost choice, not a rule.
- A region result on clippings or periodicals by reader size (E-layout test 3) in which a small reader's regions gain beyond the interval on 20 or more pages of a kind.
- A detector with a hands class that holds on the 96's hands (kraken blla or a user-trained model, stage 12) would lift the never-run rule for that route.
- An order-free rescore (OCR-6) that moves a kind's sign.

## 7. Owner calls

Taken on the recommendations on 2026-11-06 (section "Owner's calls (2026-11-06)" below); kept as the evidence shown.

1. **Detector on newspapers.** Options: PP-DocLayoutV3 (recommended: skew-robust, Apache-2.0, 794 MB, finds manuscript regions), or DocLayout-YOLO through newspaper-ocr's processing, which scores 91.1 on L9 against 86.2 and was not run on Real5; DocLayout-YOLO with the app's region sort, a different arm, reaches 78.2 after the quad on Skew against PP-DocLayoutV3's 89.1, and YOLO is unsafe on any page the kind gate misjudges. The pair was not tested on L9 (paired intervals overlap: +61.9 [+41.8, +80.5] against +57.0 [+37.5, +74.8]) [M, layout-photo-tables.md]. Memory and time on the Mac, one run (E-layout.md claim 36) [M]: PP-DocLayoutV3 0.47 s a page and 794 MB peak RSS; DocLayout-YOLO Core ML 0.51 s and 1,241 MB peak RSS (its weights are 72 MB). A second run gives PP-DocLayoutV3 0.27 s (layout-photo-hands.md), likely background QoS (LAY-3). Not an owner call: the figures pick PP-DocLayoutV3, and the L9 gap is an item (layout-pair-newspapers).
2. **Multi-column non-newspaper pages (periodicals, forms, tables).** Shown settled for what is measured: tables and clippings read better whole (tables PP -9.1 [-18.3, -2.3], heron -4.2 tie; clippings -5.1 to -9.8, intervals cross 0 except Vision) [M], though the 96's 13 clippings and 12 tables are descriptive groups under the card's 20-page rule; forms and registers are not scored apart (L4 registers lose). Periodicals and programme pages have no owner or public page measured under a detector [?]; the owner chooses whether to leave them whole (recommended, nothing says otherwise) or fund E-layout test 3 on them.
3. **A detector never runs on handwriting or registers.** Settled by measurement (section 3). The owner may confirm only the one open boundary: a mixed page, handwritten notes on a printed page, goes whole-page as well (mixed pages belong to stage 10).
4. **The cluster route.** Settled: regions first for small readers on newspapers is a reading-stage figure, GLM-OCR on regions 0.969 on L9 at 1,087 pages per GPU-hour against Qwen3.6-27B whole 0.967, seventeen times the pages per GPU-hour (E-layout.md section 5, claim 35, as the gap audit cites it) [M, one 15-page set]. It belongs in stage 04's cluster rows as a newspapers `kind_rules` string, "regions first (layout stage)", with this stage owning the gate. Not a row here, because this stage has no user choice and the cost sits with the reader. Whether a cluster user on newspapers defaults to the small reader on regions or the 27B whole page is asked in 04, not here; this note asks nothing on it.
5. **Premium readers on newspapers.** Gemini 3.8 Flash and Claude Sonnet whole page versus a detector first: E-layout.md section 9 recommends whole page for these and a detector for Haiku-class and gpt-5.6-luna (0.232 to 0.894, 0.503 to 0.921, claim 34) [M, L9 only]. No figure on the premium models' own regions on the 96. Recommendation: detector on newspapers for every reader until the measured exception exists, since the gain for large readers is nil, not negative, on 15 pages [I].

## 8. Items to file

- **layout-order-newspapers-pp** (offline, free, small): app region sort and HDBSCAN on PP-DocLayoutV3's own regions on L9, scored with tau, gap and reading-order edit against the native order (the gap in section 3). Waits on nothing.
- **layout-pair-newspapers**: done (W46.layout-pair-newspapers, layout-pair-newspapers.md). On L9 DocLayout-YOLO wins the pair; no photographed newspaper set exists, so that half stays with layout-photo-newspapers.
- **layout-retime-interactive** (free, small): time and peak memory for PP-DocLayoutV3 and the reader per newspaper page on a 16, 32 and 64 GB Mac in an interactive session (LAY-3). Fills the table's time and memory cells.
- **layout-coverage-fallback** (free, medium): how much of Vision's ink the regions must cover before the page falls back to whole or gets a whole-page fill pass (PP reads 69.4% of L9 ink on average; 6 of 15 pages under 80%); and the union form (regions added to the whole page) that P11-1 describes for marks. Sets the failed-page threshold.
- **layout-kind-label** (small): does the router carry a newspaper or dense multi-column label, or does the gate need one. Waits on the kind-classifier note.
- **layout-by-reader-size** (E-layout test 3, free for open readers, about $0.40 paid arm): whole against regions by reader size and by kind on the 96 and L3, L4, L1, order-free (W46.ocr-rescore-offline). Settles clippings and periodicals.
- **layout-photo-newspapers** (cluster or Mac, small): the staged route on photographed newspapers (E-layout test 8) for the quad rule.
- **Table gaps:** the `whole-page` row has no `cost`, `time` or `memory` figure (the reader's own cost sits in stage 04; the stage itself adds nothing measured), and no `app_route`; filled when `settings_routes.py` is built.

## 9. Profile test expectations

Kinds distinguished: newspapers and dense multi-column, typed and printed single-column, clippings, tables and forms, handwritten, registers.

- **Laptop, 16 GB.** Newspapers: PP-DocLayoutV3 regions (794 MB RSS), reader a small one (stage 04), quad first on a photograph; row pp-doclayoutv3, figure 86.2 on L9. All other kinds: whole page (rows whole-page: typed 94.0, clippings 86.9, tables 91.9). Handwritten and registers: never a detector (85.8, 59.7 whole against 70.5, 48.9).
- **Laptop, 32 GB.** Same picks. Larger open readers need regions less (E-layout.md section 9, 8B whole 85.3 NES on L9); the rule does not change, the gate stays on newspapers [I].
- **Laptop, 64 GB.** Newspapers: regions by the rule; the 27B whole page ties (0.967 against 0.965) and is not chosen, since the gate is a rule [I]; detector first for every reader (owner, 2026-11-06).
- **Cheap API.** Detector on the Mac, regions to the model, order from the detector (Flash Lite 0.820 whole to 0.961 regions, E-layout.md section 9, claim 34 [M]). Other kinds whole.
- **Premium APIs or plans.** Newspapers: detector first by the default rule (owner, 2026-11-06); other kinds whole page; the model's own block order is not used (P10-4).
- **Cluster.** Newspapers: regions first, small reader, same detector (stage 04's cluster row carries 1,087 pages per GPU-hour). Other kinds and the never-run kinds as above. FarmShare and Sherlock share the rule.
- **Any of these plus a coding agent.** Same rules. A user-trained ordering model is not offered (layout-order-marks.md, no trained orderer needed on the 96).

## Owner's calls (2026-11-06)

From `14-owner-calls.md` §2 "Layout", taken on this note's recommendations and open to the owner's veto. Section 3's rule already says each.
- PP-DocLayoutV3 regions on newspapers for every reader, premium readers included (call 5): the gain for large readers is nil, not negative, on 15 pages.
- Everything else reads the whole page (call 2); never a detector on handwriting or registers (call 3).
- The cluster "regions first for small readers" lives as a kind rule on 04's cluster rows (call 4); this stage owns the gate only.
- The PP-DocLayoutV3 against DocLayout-YOLO pair test on L9 is filed (layout-pair-newspapers; call 1).

Files read: execution-plans/processing-review/00-plan.md (1-105), 13-stage-rules/00-index.md (worktree suite-wt-20261106-205546-44529), 14-owner-calls.md, kind-classifier.md (speed), E-layout.md (sections 5, 6, 7, 9), segbench-results/layout-photo.md, layout-photo-hands.md, layout-photo-tables.md, layout-order.md, layout-order-paid.md, layout-order-marks.md, 11-measurement-audit.md (LAY-1 to LAY-3, OCR-6), measure-reviews/2026-10-31.md (R-2), 2026-11-01.md, 2026-11-02.md, 2026-11-04-2.md, 2026-11-05.md, 2026-11-05-2.md, 2026-11-05-3.md, 2026-11-03.md (grep excerpts only), settings-design/figures.json ("fixed").
