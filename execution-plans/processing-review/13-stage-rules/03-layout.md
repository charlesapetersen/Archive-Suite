# 03 Layout and reading order (Phase 4 rule note, draft)

Tags: [M] measured, [I] inferred, [?] unverified. Every figure names its file. Corrections cite the pass id.

## 1. Stage and question

The stage decides whether a layout detector runs before reading (regions first), which detector, on which kinds, and how the regions and lines are ordered.
The user chooses nothing here: the choice is a rule by kind, because the whole page beats every detector on every kind but newspapers.

## 2. Is there a choice?

No. The rule, with the measured reason:

- Newspapers and other dense multi-column print get a detector, then regions in the detector’s native reading order. A detector gains on the whole page only here: L9 whole 29.2 NES against PP-DocLayoutV3 86.2 [M, layout-photo-tables.md]. The whole-page figure is partly the reader's token cap (GLM-OCR fails or returns nothing on 9 of 15 whole pages), so the gain is operational, not proof that layout helps transcription (measure-reviews/2026-11-01.md, P4 finding on layout).
- Every other kind reads the whole page. On the 96 the whole page scores 90.9 and the best detector, heron, 87.1 (-3.9 [-7.7, -0.3]) [M, layout-photo-tables.md].
- Handwriting and registers never get a detector (below).
- No switch. The owner ruled none for this stage, and the figures give no kind where the user's own taste decides.
- Routes in view (E-layout.md section 9): R1 Apple Vision document request is not a substitute (L9 16.8 NES; worst of the arms on the illumination and warping conditions, 70.2 and 61.3, though above YOLO with the app sort on Scanning and Skew) [M, layout-photo-tables.md]. R2 and R7 use the same detector. R3 to R5 keep the detector on the Mac and send regions. R6 none recommended (E-layout.md section 9: none measured on archival photographs; test 10 unrun) [?]. R8 is the kind gate itself.

## 3. The rule for the settings layer

Sheet text is `SettingsSheetWords.ruleText("layout")`: newspapers use every reader on regions in the detector’s order, pictures kept, except Qwen3.6 27B, which reads them whole (W47.wh-whole-page-large); photographs get perspective correction, each line is read once by the region holding most of it and text outside every region in small pieces of its own (W46.layout-partition-fix), and a failed layout or region reads whole. The rule names the helper download and whole-page behaviour until installed. Everything else reads whole, including handwriting, registers, ledgers and uncertain kinds. The rendered rule and download row were checked in the VM (W46.layout-newspapers).

- **Metric and tie rule.** Reading: strict NES (higher is better), paired difference over the same pages with a 95% page bootstrap; an interval that crosses 0 is a tie; per-kind groups under 20 pages are descriptive [M, layout-photo.md card]. On the 96 a gap is also a tie when under twice the rerun range, 0.49 NES points for Gemini 3.7 Flash [M, ocr-rerun-noise.md as applied in measure-reviews/2026-10-31.md R-2]. Order: Kendall tau over placed lines on pages placing at least 15 lines, with the benchmark guard (60% of truth lines) where the set has it [M, layout-order.md, layout-order-marks.md]. Ties as above.
- **Default detector on newspapers: PP-DocLayoutV3** (MLX port, 1,024 px, confidence 0.5). Reasons: it is the only detector inside the noise on Real5 Scanning (91.7 against 92.1 whole, -0.4 [-3.4, +2.5]) and loses 10.0 on Skew where DocLayout-YOLO loses 40.1 and keeps no region on 58 of 155 pages [M, layout-photo.md, layout-photo-tables.md]; it finds the manuscript regions YOLO misses (tau 0.999 on all 15 multi-column benchmark pages, YOLO valid on 5) [M, layout-order.md]; licence Apache-2.0 [E-layout.md section 9]. DocLayout-YOLO is available as an optional detector for scanned newspapers (owner call 15). Paired on raw crops from the 15 L9 scans through four readers, DocLayout-YOLO (newspaper-ocr) leads it, a direction on 15 pages (at most 12 items, one collection), descriptive: PP-DocLayoutV3 is -4.6 [-8.0, -1.1] strict NES behind on the readers' mean (85.6 against 90.2), beyond the interval for GLM-OCR, LightOnOCR-3 4B and Qwen3.6-27B, a tie for PaddleOCR-VL 1.5, and -2.0 [-2.9, -1.0] order-free [M, layout-pair-newspapers.md]. The choice stands on photographs (above, and 70.9 against 84.9 on the 96, none of them a newspaper), which the owner's pages are. Processor uses masked regions and outside crops, so its accuracy gain is unmeasured. Qwen3.6 27B now reads the whole newspaper page and skips the detector.
- **Order, when regions run: the detector's own order.** On L9 PP-DocLayoutV3's native order gives tau 0.881, word accuracy 37.2% and gap 23.4, the best of the arms on the last two; the app region sort on YOLO regions has tau 0.905 and the lowest reading-order edit (0.147); HDBSCAN 0.922. These are not separable at n 15 (layout-order.md, caveats). With PP-DocLayoutV3's own regions held fixed on L9, paired, its own order beats both geometric rules: tau 0.977 against 0.900 for the app region sort (-0.077 [-0.175, -0.016]) and 0.905 for HDBSCAN (-0.072 [-0.148, -0.019]); the order gap is 21.6 against 26.5 (+4.9 [+1.6, +8.6] points) and 27.5 (+5.9 [+1.6, +11.7]); reading-order edit 0.121 against 0.217 (a tie, +0.096 [-0.008, +0.257]) and 0.268 (+0.147 [+0.067, +0.238]) [M, layout-order-pp.md]. On the 96 the app sort on its regions is 0.961 against 0.992 native, a tie by interval (+0.014 [-0.005, +0.040] against the YOLO base) [M, layout-order-marks.md].
- **Order, when no detector runs: the line order the reader gets.** Vision's line order 0.972 and the app's line column sort 0.971 on the 96, keeping 100% of lines, a tie (Vision +0.027 [+0.001, +0.056], column sort +0.026 [-0.004, +0.057], both against the YOLO base) [M, layout-order-marks.md]. No trained orderer (W46.layout-order-train moves behind W46.nice-to-have, per layout-order-marks.md).
- **Kind rules.** Newspapers and dense multi-column print: regions. Typed single-column, clippings, tables, forms, periodicals: whole page. Handwritten and registers: no detector. An uncertain kind reads the whole page [I]. The kind comes from the router (139 of 144 pages, about 0.6 s a page on the M3 Pro, kind-classifier.md); the app’s `PageKindName.newspapers` label comes from its printed-page column rule, and `NewspaperPagePlan.usesRegions` requires at least 0.8 confidence (verified in W46.layout-newspapers).
- **Before the stage on a photograph: quad correction.** The quad lifts PP-DocLayoutV3 by 7.4 on Skew [+4.9, +10.0] and 0.8 on Warping (a tie) [M, layout-photo-tables.md]. Whole-page dewarping for OCR still does not pay (whole page +1.7 [-0.3, +4.2] on Skew with the quad). Newspapers photographed, rather than scanned, are unmeasured [?]: L9 is scans.
- **Fallback when the detector fails a page.** Read the whole page. PP-DocLayoutV3 answered 15 of 15 on L9 and read nothing on 1 of 96 owner pages [M, layout-photo-tables.md, layout-photo-hands.md]. The app now uses a 95% Vision line-box union floor plus a boundary-line guard (W46.layout-newspapers, implementation note below); an accuracy-optimal threshold is unmeasured. PP-DocLayoutV3 reads 69.4% of ink on L9 on average and 6 of 15 pages under 80% [M, layout-photo-hands.md], so a miss is common; see items.
- **When the stage must not run.** Handwritten pages and registers: on the 96's 16 handwritten pages PP-DocLayoutV3 scores 70.5 against 85.8 whole (-15.3 [-28.2, -4.4]); on L4's 80 registers 48.9 against 59.7 (-10.8 [-14.8, -6.8]); YOLO scores 14.2 and 1.6 and reads nothing on 10 of 16 and 49 of 80 [M, layout-photo-tables.md, layout-photo.md]. The 96's 16 handwritten pages are a descriptive group (under 20 pages); the rule holds on L4's 80 registers and on direction. Premium readers on newspapers: detector first (owner, 2026-11-06).
- **A large reader that ties the detector reads newspapers whole (owner, 2026-11-19, call 15).** Qwen3.6-27B scores 0.967 whole against 0.965 on DocLayout-YOLO's regions and 0.936 on PaddleX's (NewsBench overall, 1-CER, 15 L9 pages) [M, E-layout.md claim 34]: a tie, and the whole page is one request a page instead of one a region with no detector run, so by the stage notes' tie rule (the faster wins among equal cost, 04-reading.md) the whole page is picked. Measured on the detector's raw regions, not on the app's partition (W46.layout-partition-fix), on FarmShare's vLLM build rather than the OpenRouter route the app pins (chutes fp8), and not in strict NES [?]. The app applies it by reader: `NewspaperPageReader.wholePageReaderIDs`. No other reader has the tie measured: premium readers keep the detector (call 5), as do the Mac readers, none of them 27B-class.
- **Marks.** A region pass drops marks: the app's DocLayout-YOLO filter keeps 7 of 45 marks, 26 with pictures and tables kept; PP-DocLayoutV3 keeps 3 at most [M, layout-order-marks.md, confirming LAY-2]. If regions run, pictures stay in the stream or marks are read in stage 06's own layer.

## 4. Table rows

The stage object, replacing the design's fixed text (figures.json "fixed" layout rule names PP-DocLayoutV3 and the two never-run kinds; this note adds the quad and the fallback). Its `routes` list is the four rows in the second block (the third, DocLayout-YOLO on scans, added by W47.wh-yolo-scans at the owner's call 15 of 2026-11-19, with its switch; the fourth, a 27B-class reader on newspapers whole, by W47.wh-whole-page-large at the same call):

```
{"id":"layout","name":"Layout and reading order","unit":"pages","choice":false,
 "metric":{"id":"nes","label":"strict NES","higher_is_better":true},
 "kinds":["newspapers","typed","clippings","tables","handwritten","registers"],
 "rules":[{"id":"layout-regions-newspapers","text":"Newspapers and dense multi-column print: PP-DocLayoutV3 regions, the detector's own order, quad correction first on a photograph.","source":"layout-photo-tables.md §L9","switch":null},
  {"id":"layout-whole-otherwise","text":"Every other kind, and an uncertain kind, reads the whole page in the reader's line order.","source":"layout-photo-tables.md §the 96","switch":null},
  {"id":"layout-never-hands-registers","text":"No detector on handwritten pages or registers.","source":"layout-photo-tables.md §handwritten","switch":null},
  {"id":"layout-fallback-whole","text":"A page the detector fails reads whole.","source":"layout-photo-tables.md §the 96","switch":null},
  {"id":"layout-large-reader-whole","text":"Qwen3.6 27B reads newspapers whole, with no detector: 0.967 whole against 0.965 on DocLayout-YOLO's regions on 15 L9 pages, a tie that goes to the faster, cheaper whole page. Measured on the raw regions, not the app's partition. Every other reader keeps the detector.","source":"E-layout.md §3 claim 34","switch":null},
  {"id":"layout-scans-doclayout-yolo","text":"DocLayout-YOLO is optional and off by default. On raw crops from 15 newspaper scans (14 from one collection), it averaged 4.6 reading-accuracy points above PP-DocLayoutV3 (95% interval +1.1 to +8.0) across GLM-OCR, PaddleOCR-VL 1.5, LightOnOCR-3 4B and Qwen3.6 27B. The comparison did not measure Processor's masked regions and outside crops. Qwen3.6 27B now reads whole pages without the detector. Photographed newspapers were outside the comparison and keep PP-DocLayoutV3. The optional download uses AGPL-3.0 weights.","source":"layout-pair-newspapers.md §What this says","switch":{"id":"layout.scan_newspapers_yolo","label":"On scanned newspapers, find the columns with DocLayout-YOLO (newspaper-ocr's route)","default":false}}],
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
 "time":{"per_unit_s":0.19,"measured":true,"measured_on":"M3 Pro 18 GB, like for like: median of 3 detections on each of the same 16 owner pages every Mac reader was timed on, 1024 px draft decode, model load (1.69 s) apart (W46.ocr-time-like-for-like)","source":{"file":"ocr-time-like-for-like.md","route":"pp-doclayoutv3","attribute":"median s a page","value":"0.19"}},
 "memory":{"peak_gb":0.794,"measured_on":"RSS of the MLX port, 128 MB weights, same run","source":{"file":"E-layout.md","route":"claim 36","attribute":"peak RSS","value":"794 MB"}},
 "caveats":["time re-taken like for like (LAY-3): 0.19 s a page beside Vision's 0.19 s on the same 16 pages; the lab's 0.47 s (E-layout claim 36) and the 0.27 s of layout-photo-hands.md were other runs and inputs","memory: the lab's 794 MB peak RSS stands in the table; the like-for-like run saw a 441 MB process RSS and a 1.52 GB MLX peak, not the same measure","L9 is scans; photographed newspapers unmeasured","on raw L9 crops DocLayout-YOLO averaged 4.6 NES points higher across four readers, a descriptive result on 15 scans (layout-pair-newspapers.md)","regions drop marks (LAY-2)","96 deltas order-sensitive (OCR-6)","one reader, GLM-OCR (layout-photo.md card)"],
 "kind_rules":["newspapers and dense multi-column: regions","handwritten, registers: never","all other kinds: whole page"],
 "fallback":"whole-page","conditions":["quad correction first on a photograph"]}
{"id":"doclayout-yolo-scans","name":"DocLayout-YOLO regions through newspaper-ocr's route, then the reader (scanned newspapers)","family":"mac","app_route":null,"status":"measured",
 "needs":{"key":[],"plan":[],"cluster":false,"mac_gb":16,"gpus":0},
 "figures":{"newspapers":{"value":91.1,"n":15,"truth":"L9 published transcriptions","source":{"file":"layout-photo-tables.md","route":"L9 yolo_newsocr","attribute":"NES strict","value":"91.1"}}},
 "cost":{"usd_1000_list":0,"usd_1000_batch":0,"price_read":null,"source":{"file":"E-layout.md","route":"section 7","attribute":"detectors are free everywhere","value":"free"}},
 "time":{"per_unit_s":2.05,"measured":true,"measured_on":"this Mac, headless Debug Processor: median Core ML detection on the CPU over the 15 L9 scans, 3,357-3,812 px wide, layout processing (0.18 s) apart (W47.wh-yolo-scans)","source":{"file":"scan-layout-parity.md","route":"Core ML detection","attribute":"median s a page","value":"2.05"}},
 "licence":"weights AGPL-3.0 (juliozhao/DocLayout-YOLO-DocStructBench-imgsz1280-2501), a separate optional download, never bundled (call 12); newspaper-ocr's layout processing MIT, vendored",
 "caveats":["on raw L9 crops, 4.6 NES points above PP-DocLayoutV3 (95% interval +1.1 to +8.0), averaged across GLM-OCR, PaddleOCR-VL 1.5, LightOnOCR-3 4B and Qwen3.6 27B (layout-pair-newspapers.md)","15 pages, 14 from one Library of Congress collection and four from one item: a direction, not a settled gap","scans only: photographed newspapers unmeasured, so they keep PP-DocLayoutV3; on photographed modern print and the owner's 96 the same detector with the app's sort trails it (layout-photo-tables.md)","Processor uses masked regions and outside crops (W46.layout-partition-fix), and Qwen3.6 27B reads whole pages without the detector","the app's boxes and region order matched on all 15 pages (scan-layout-parity.md); OCR accuracy through Processor's crop path is unmeasured","memory not measured"],
 "kind_rules":["scanned newspapers: regions, when the user turns it on","photographed newspapers: PP-DocLayoutV3","all other kinds: whole page"],
 "fallback":"whole-page","conditions":["the user's switch, off by default","PP-DocLayoutV3 while its detector is not downloaded"]}
{"id":"whole-page-large","name":"Whole page for a 27B-class reader on newspapers (Qwen3.6 27B)","family":"cloud","app_route":"openrouter|qwen/qwen3.6-27b","status":"shipped",
 "needs":{"key":["openrouter"],"plan":[],"cluster":false,"gpus":0},
 "figures":{"newspapers":{"value":0.967,"n":15,"truth":"L9 published transcriptions","source":{"file":"E-layout.md","route":"claim 34 Qwen3.6-27B whole","attribute":"NewsBench overall, 1-CER on lowercased alphanumerics","value":"0.967"}}},
 "caveats":["NewsBench overall (1-CER), not strict NES: not comparable with the other rows' newspaper figures","against 0.965 on DocLayout-YOLO's raw regions and 0.936 on PaddleX's, the same 15 pages (E-layout.md claim 34): a tie, so the faster wins; not measured on PP-DocLayoutV3 or the app's partition","measured on FarmShare's vLLM build of Qwen3.6-27B, not the OpenRouter route the app pins (chutes fp8)","one request a page instead of one a region, and no detector run: not timed on newspapers","15 pages, one set: a direction"],
 "kind_rules":["newspapers: whole page, no detector, for Qwen3.6 27B only","all other kinds: whole page"],
 "fallback":null,"conditions":["the reader is Qwen3.6 27B"]}
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
- LAY-3: Mac seconds (YOLO 1.77 s a page in layout-photo-hands.md against 0.51 s in the gap audit) were likely background QoS. Respected: no seconds figure is a route decision here. PP-DocLayoutV3 is now timed like for like (0.19 s a page on the 16 pages every Mac reader was timed on, ocr-time-like-for-like.md, 2026-11-11), and the row takes that figure; DocLayout-YOLO was not re-timed.
- OCR-6: the region losses on the 96 are order-sensitive NES on a truth the gap audit read as having no order. Respected: the kind rules rest on direction and intervals, not size; the typed tie and the hand and register content losses stand ("probably stands", OCR-6); rescoring order-free is W46.ocr-rescore-offline. layout-photo-tables.md uses the same strict NES, so its 96 deltas carry the same caveat [?].
- R-2 (measure-reviews/2026-10-31.md): the -0.18 bowF1 for tiles on typed pages is a tie by the rerun rule; whole-page reading stays the default on the intervals that matter (-7.5 and -2.4 on the 96). Respected: no kind rule rests on a gap under 0.49 points; typed ties (+0.6, +1.7, +2.2) are ties and not a reason to run a detector.
- P10-4 (measure-reviews/2026-11-05-2.md): Gemini's own block order changes no default. "Ties" is over each arm's kept lines: Gemini places 69% of truth lines on its 66 valid pages against Vision's 86%; the 96's order truth is the drafters' shared order, a relative of Gemini; the gap to PP-DocLayoutV3 (-0.013 to -0.019) is about the read-to-read shift (+0.011 [-0.009, +0.037]) [M, layout-order-paid.md]. Respected: no rule sends a page to a model for its order, and the tau table is given with its kept-line shares.
- P9-6 (measure-reviews/2026-11-05.md): PP-DocLayoutV3's 0.992 is tau over the lines it keeps (+0.020 [+0.002, +0.048] over Vision's line order on 66 pages, 2,788 against 2,974 lines); Vision's 30 of 45 marks are coverage and 21 of 27 clear of print is the purer figure; the marks lie on 20 of the 32 pages. Respected: the rule gives no "best orderer" claim.
- P4-3 (measure-reviews/2026-11-02.md): layout-photo-tables.md now carries its card; numeric verdicts unchanged.
- Newspaper gain under per-crop caps (measure-reviews/2026-11-01.md): carried as the operational caveat in section 2.
- Vision caches on 26.6 (measure-reviews/2026-11-04-2.md): the 96 excludes pages Vision read as empty, so Vision comparisons there are on readable pages.

## 6. What would change the rule

- A pair test on L9 and photographed newspapers in which another detector clears PP-DocLayoutV3 beyond its interval after the quad. On the L9 half the raw-crop benchmark gives a direction on 15 pages (at most 12 items, one collection), descriptive: DocLayout-YOLO through newspaper-ocr leads it by 4.6 [1.1, 8.0] strict and 2.0 [1.0, 2.9] order-free, paired over four readers, on page bootstraps that are optimistic for pages this alike [M, layout-pair-newspapers.md]. The photographed half is unmeasured (no photographed newspaper set with truth; W46.layout-photo-newspapers, behind W46.nice-to-have), and photographed modern print points the other way (Real5 after the quad, above).
- A reader at or above the 27B class on a cluster or a premium model on newspapers that ties regions on L9 (whole 0.967 against regions 0.965 for Qwen3.6-27B, E-layout.md section 5, claim 34): then regions on newspapers become a cost choice, not a rule.
- A region result on clippings or periodicals by reader size (E-layout test 3) in which a small reader's regions gain beyond the interval on 20 or more pages of a kind.
- A detector with a hands class that holds on the 96's hands (kraken blla or a user-trained model, stage 12) would lift the never-run rule for that route.
- An order-free rescore (OCR-6) that moves a kind's sign.

## 7. Owner calls

Taken on the recommendations on 2026-11-06 (section "Owner's calls (2026-11-06)" below); kept as the evidence shown.

1. **Detector on newspapers.** Options: PP-DocLayoutV3 (recommended: skew-robust, Apache-2.0, 794 MB, finds manuscript regions), or DocLayout-YOLO through newspaper-ocr's processing, which scores 91.1 on L9 against 86.2 and was not run on Real5; DocLayout-YOLO with the app's region sort, a different arm, reaches 78.2 after the quad on Skew against PP-DocLayoutV3's 89.1, and YOLO is unsafe on any page the kind gate misjudges. Memory and time on the Mac, one run (E-layout.md claim 36) [M]: PP-DocLayoutV3 0.47 s a page and 794 MB peak RSS; DocLayout-YOLO Core ML 0.51 s and 1,241 MB peak RSS (its weights are 72 MB). A second run gives PP-DocLayoutV3 0.27 s (layout-photo-hands.md); timed like for like with every Mac reader on the same 16 owner pages it is 0.19 s a page, model load apart (W46.ocr-time-like-for-like, ocr-time-like-for-like.md), so LAY-3's re-time is done for PP-DocLayoutV3. Not an owner call: the figures pick PP-DocLayoutV3, and the L9 pair is measured: a direction on 15 pages (at most 12 items, one collection), descriptive, toward DocLayout-YOLO (layout-pair-newspapers.md).
2. **Multi-column non-newspaper pages (periodicals, forms, tables).** Shown settled for what is measured: tables and clippings read better whole (tables PP -9.1 [-18.3, -2.3], heron -4.2 tie; clippings -5.1 to -9.8, intervals cross 0 except Vision) [M], though the 96's 13 clippings and 12 tables are descriptive groups under the card's 20-page rule; forms and registers are not scored apart (L4 registers lose). Periodicals and programme pages have no owner or public page measured under a detector [?]; the owner chooses whether to leave them whole (recommended, nothing says otherwise) or fund E-layout test 3 on them.
3. **A detector never runs on handwriting or registers.** Settled by measurement (section 3). The owner may confirm only the one open boundary: a mixed page, handwritten notes on a printed page, goes whole-page as well (mixed pages belong to stage 10).
4. **The cluster route.** Settled: regions first for small readers on newspapers is a reading-stage figure, GLM-OCR on regions 0.969 on L9 at 1,087 pages per GPU-hour against Qwen3.6-27B whole 0.967, seventeen times the pages per GPU-hour (E-layout.md section 5, claim 35, as the gap audit cites it) [M, one 15-page set]. It belongs in stage 04's cluster rows as a newspapers `kind_rules` string, "regions first (layout stage)", with this stage owning the gate. Not a row here, because this stage has no user choice and the cost sits with the reader. Whether a cluster user on newspapers defaults to the small reader on regions or the 27B whole page is asked in 04, not here; this note asks nothing on it.
5. **Premium readers on newspapers.** Gemini 3.8 Flash and Claude Sonnet whole page versus a detector first: E-layout.md section 9 recommends whole page for these and a detector for Haiku-class and gpt-5.6-luna (0.232 to 0.894, 0.503 to 0.921, claim 34) [M, L9 only]. No figure on the premium models' own regions on the 96. Recommendation: detector on newspapers for every reader until the measured exception exists, since the gain for large readers is nil, not negative, on 15 pages [I].

## 8. Items to file

- **layout-order-newspapers-pp**: done (W46.layout-order-newspapers-pp, layout-order-pp.md). On PP-DocLayoutV3's own L9 regions its own order leads the app region sort and HDBSCAN on tau and on the order gap, beyond the interval (a direction on 15 pages (at most 12 items, one collection), descriptive); the order rule in section 3 stands.
- **layout-pair-newspapers**: done (W46.layout-pair-newspapers, layout-pair-newspapers.md). On L9 DocLayout-YOLO leads the pair (a direction on 15 pages (at most 12 items, one collection), descriptive); no photographed newspaper set exists, so that half stays with layout-photo-newspapers.
- **layout-retime-interactive** (free, small): time and peak memory for PP-DocLayoutV3 and the reader per newspaper page on a 16, 32 and 64 GB Mac in an interactive session (LAY-3). Fills the table's time and memory cells.
- **layout-coverage-fallback**: implemented by W46.layout-newspapers; the geometry sweep and its 95% engineering floor, whole-line guard and accuracy limits are recorded below. An OCR-accuracy-optimal floor is still unmeasured.
- **layout-kind-label**: resolved by W46.layout-newspapers; the existing newspaper label and its confidence gate are used, with all other kinds whole-page.
- **layout-by-reader-size** (E-layout test 3, free for open readers, about $0.40 paid arm): whole against regions by reader size and by kind on the 96 and L3, L4, L1, order-free (W46.ocr-rescore-offline). Settles clippings and periodicals.
- **layout-photo-newspapers** (cluster or Mac, small): the staged route on photographed newspapers (E-layout test 8) for the quad rule.
- **Table gaps:** the `whole-page` row has no `cost`, `time` or `memory` figure (the reader's own cost sits in stage 04; the stage itself adds nothing measured), and no `app_route`; filled when `settings_routes.py` is built.

## 9. Profile test expectations

Kinds distinguished: newspapers and dense multi-column, typed and printed single-column, clippings, tables and forms, handwritten, registers.

- **Laptop, 16 GB.** Newspapers: PP-DocLayoutV3 regions (794 MB RSS), reader a small one (stage 04), quad first on a photograph; row pp-doclayoutv3, figure 86.2 on L9. All other kinds: whole page (rows whole-page: typed 94.0, clippings 86.9, tables 91.9). Handwritten and registers: never a detector (85.8, 59.7 whole against 70.5, 48.9).
- **Laptop, 32 GB.** Same picks. Larger open readers need regions less (E-layout.md section 9, 8B whole 85.3 NES on L9); the rule does not change, the gate stays on newspapers [I].
- **Laptop, 64 GB.** Newspapers: regions by the rule; the app offers no 27B-class Mac reader yet, so the whole-page exception (call 15, Qwen3.6 27B, 0.967 against 0.965) reaches a Mac only through OpenRouter; detector first for every other reader (owner, 2026-11-06).
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
- 2026-11-19, call 15 (the withheld-review sheet): Qwen3.6 27B reads newspapers whole, the measured tie going to the faster route (W47.wh-whole-page-large); DocLayout-YOLO as a choice on scanned newspapers (W47.wh-yolo-scans).

Files read: execution-plans/processing-review/00-plan.md (1-105), 13-stage-rules/00-index.md (worktree suite-wt-20261106-205546-44529), 14-owner-calls.md, kind-classifier.md (speed), E-layout.md (sections 5, 6, 7, 9), segbench-results/layout-photo.md, layout-photo-hands.md, layout-photo-tables.md, layout-order.md, layout-order-paid.md, layout-order-marks.md, 11-measurement-audit.md (LAY-1 to LAY-3, OCR-6), measure-reviews/2026-10-31.md (R-2), 2026-11-01.md, 2026-11-02.md, 2026-11-04-2.md, 2026-11-05.md, 2026-11-05-2.md, 2026-11-05-3.md, 2026-11-03.md (grep excerpts only), settings-design/figures.json ("fixed").

## App implementation (W46.layout-newspapers, 2026-11-15)

The Processor now applies PP-DocLayoutV3 through `PageReaders.reader`, including gateway, subscription, Vision and
paid-batch readers. The checked helper download is offered under the Rules tab, Columns and reading order; until
installed, confirmed newspapers read whole with a reason. The existing kind detector gates it; an unknown kind
and all other kinds stay whole. Pictures and native order remain. Photographs take the quad first. A failed
preparation or region read replaces partial text with one whole-page read; cancellation never starts that fallback.

`segbench-results/layout-coverage-fallback.md` measures the threshold's **geometry**, not its accuracy: keeping
pictures, the padded crop union covers 93.77% of Vision line-box area on average on the 15 L9 scans (8,135 boxes).
The engineering floor is 95%, with 7/15 pages below it. Boundary ownership also requires fill: lines split between
crops move intact into the masked whole-page fill, with their overlapping lines; earlier crop pixels are whitened
in later crops. That stronger guard requires fill on all 15 cached pages and moves 5,022 line boxes. No text
deduplication is used. Accuracy and speed of this partition were unmeasured when it shipped (measured below); the old 69.4%
dark-pixel figure excluded pictures and is not Vision coverage. This implements the fallback policy, without
claiming an accuracy-optimal threshold or changing the detector comparison above.

**The partition, read (W46.layout-partition-score, 2026-11-17).** Evidence scope first: every region figure above
(L9 86.2, the pair, the order results) is for raw regions (pictures dropped, no masking, no fill), not for the
partition the app ships. Read on the 15 L9 scans with the app's own plan images and the shipped Mac PaddleOCR-VL
1.6 4-bit, beside fresh matched controls, the partition scores 20.2 strict NES against 84.6 for raw regions from the
same detection (−64.4 [−70.3, −57.1], behind on all 15 pages; order-free 19.5 against 91.5) and ties the whole page
(21.5, −1.2 [−5.3, +3.1]) [M, layout-partition-score.md]. With the app's Vision lines the guard moves 8,037 of 9,635
lines (83%; the cached-geometry 5,022/8,135 above understated it) into the whole-page-sized fill, which ran to its
token cap on all 15 pages; nearly blank masked crops draw invented text. It costs 995 requests and 1,643 s of
reading against 969 and 650 s. The detector, native order and regions for every reader stand; the fill policy is
the defect, fixed under W46.layout-partition-fix. One small reader; larger readers unmeasured, and the inference
that the fill reads like a whole page for any reader is from the geometry [I].

**The fixed partition (W46.layout-partition-fix, 2026-11-17).** Each Vision line is now read once, whole, by the
region holding most of its pixels (930 of 9,635 lines cross a region edge); lines touching no region (244) are read
as 80 small crops of their own lines; 17 of 980 regions masked blank are not read; the whole-page fill stays only
for a page with no Vision line. Same reader and settings: 78.7 strict NES, not shown behind raw regions by the
predeclared rule (−5.9 [−15.8, +1.6]; order-free 91.2 against 91.5; added words 22.7 against 17.7), +58.5 over the
shipped partition, 791 s of reading [M, layout-partition-fix.md]. It is not a page-by-page tie: the partition trails
raw regions on 11 of 15 pages, −64.2 on one page's repetition loop (mss3413201819-6, which the kind gate reads whole,
so the app never sends it the partition), −17.2 and −13.4 on two more (one spread over many region reads plus the
outside crops, the other one region's capped loop), a mean of −1.7 over the other 14. As the app routes it: 78.6,
−6.0 [−16.1, +1.6] (W46.p16-score-hygiene). The coverage floor above no longer triggers anything; it is recorded only.
