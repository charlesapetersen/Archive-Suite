# 01. Image preparation for the reading copy: rotation, crop, deskew, dewarp, image size

Draft for Phase 4 (2026-11-06). Figures are copied from the files named; [M] measured, [I] inferred, [?] unverified.

## 1. Stage and question

The stage turns each page upright, may level or straighten the image the reader sees, and sets the size the page is sent to readers at.
The user chooses nothing per route here: rotation follows the profile, the geometry follows one owner rule (only methods that remove no content touch the reading copy; seemingly incidental marks are evidence, `00-plan.md`), and one switch turns straightening on or off.

## 2. Is there a choice?

No route choice. Rules and one switch. Rotation picks its route by profile and script from measured rows (W46.rotation-default carries the build). Crop and dewarp do not touch the reading copy, because every automatic crop or dewarp measured removes text [M, §5 below]. Deskew is the one geometry method measured to remove no word and to help (place-geom-real5.md) [M]. The switch is the owner's of 2026-10-20 (`figures.json` "fixed.enhancement": "The reading copy's deskew or dewarp is a user switch, content-preserving methods only"); its default is on (owner, 2026-11-06; "Owner's calls" below).

## 3. The rule for the settings layer

Sheet text: "Pages are turned upright before reading. A page whose lines slope by 1 degree or more is turned level after reading, unless you switch Straighten off; nothing is cropped or cut, and marks stay. Dewarping, cropping and shading correction are not applied to the page you see."

- **Rotation.** Metric: pages wrong at any of four turns on the held-out owner pages (lower is better), turns exact as the second figure; tie: Wilson page intervals that overlap, and "a gap of a few turns between two routes is read as a tie" (rotation-routes.md, Noise). Kind rules: Latin-script modern material takes the agreement rule; charters (L7) and non-Latin scripts (N1 Arabic, N4 Hebrew, N5 Chinese) take llmSingle on every page where a measured cloud route exists, because the local rule flags most of them (L7 66 of 80, N4 78 of 80 turns) [M, rotation-routes.md]; PP-LCNet is never used alone on right-to-left pages (flips Hebrew 73 of 80) [M]. Fallback: a page where the local routes disagree or Vision abstains and no cloud route is set is left as it is and flagged [I, the rule's design; the free rule flags 14 of 119 held-out pages, rotation-routes.md §"Held out"]. Must not run: no measured route is skipped; Tesseract OSD and the small local VLMs are not routes (Tesseract 62.7%, Qwen3-VL 8B comparative 78.1% over all turns) [M].
- **Deskew** (switch `reading_copy.straighten`, default on). Runs after OCR on the reading copy only, on an enlarged canvas, with the lab writer, when the page's median Vision line angle is 1° or more (place-geom-real5.md) [M]. Metric: PDFKit line pass rate, paired 95% interval across 0 is a tie. Not on level pages: −0.1 (−1.5 to +1.2) there, so below 1° it changes nothing (corrected reading, P10-5; the Verdict's +0.1 was the overshoot table's) [M].
- **Crop and dewarp.** Never on the reading copy (Apple quad, UVDoc, DocRes); not as OCR input either, by default (§5, enh-dewarp.md). DocRes never runs. No dewarped copy is offered (owner, 2026-11-06). The per-page guard is now measured (W46.dewarp-guard, `dewarp-guard.md`): on the 63 originals guarded UVDoc ties raw for every reader, and on Real5 Warping it lifts Vision +4.3 (+2.2 to +6.6). The owner's bound or curled pages are not yet scored (W46.dewarp-curved-select).
- **Shading division.** Not offered, for viewing or as the reading copy (owner, 2026-11-06): it greys coloured marks on 14 pages and 31 boxes (enh-ocr-marks.md §Verdict, P9-5) [M] and helps no reader as OCR input (02).
- **Image size.** Readers receive the app's 2,048 px long side at JPEG 0.85 (`ImageEncoding.maxOCRDimension`, L-capture.md claim 39) [M]. No change: a tie with the bench's 2,400/0.90 for every reader measured, and a gain for PP-OCRv6 (+0.8, +0.2 to +1.5 on the 96) [M, enh-dewarp.md §"The app's encoding"]. Rotation candidates for the comparative prompt are 800 px at JPEG 0.8 (rotation-routes.md, Comparison) [M].

## 4. Table rows

The stage is no-choice, so `routes` is empty for geometry. Rotation's rows go in as rules with their figures, so the solver can pick by profile. Held-out figures (W46.rotation-heldout, rotation-routes.md §"Held out") are as stored on 119 pages, with the 5-page set-apart figure beside them (P10-7).

```
{"id":"rotation.vision","name":"Apple Vision (RotationDetector)","family":"mac","app_route":null,"status":"shipped","needs":{"key":[],"plan":[],"cluster":false,"mac_gb":null,"gpus":0},
 "figures":{"owner-heldout":{"value":"6 of 119 pages wrong (<=10.6%), 7 flagged; 91.6% turns (86.3-96.2)","n":119,"truth":"constructed turns","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"held out, all 119","value":"107/119 right"}},
  "owner-96-dev":{"value":"0 of 96 wrong (<=3.8%); 99.0% turns","n":96,"truth":"constructed turns","caveat":"development set, P9-1","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"the 96 by page","value":"95/96 right, 0 wrong (≤3.8%)"}},
  "L7":{"value":11.2,"n":80,"truth":"stored orientation, constructed turns","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"By stratum","value":"9/80 (11.2%)"}},
  "N1":{"value":80.0,"n":80,"truth":"as L7","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"By stratum","value":"64/80 (80.0%)"}},
  "N4":{"value":55.0,"n":80,"truth":"as L7","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"By stratum","value":"44/80 (55.0%)"}},
  "N5":{"value":68.8,"n":80,"truth":"as L7","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"By stratum","value":"55/80 (68.8%)"}},
  "L1":{"value":93.8,"n":80,"truth":"as L7","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"By stratum","value":"75/80 (93.8%)"}},
  "L4":{"value":97.5,"n":80,"truth":"as L7","source":{"file":"rotation-routes.md","route":"Local Vision","attribute":"By stratum","value":"78/80 (97.5%)"}}},
 "cost":{"usd_1000_list":0},"time":{"per_unit_s":0.15,"measured":true,"measured_on":"engine session, background QoS; ratios only"},"memory":null,
 "caveats":["2 of 114 wrong when 5 agreement-only pages are set apart (unchecked, P10-7)","confident wrong axis on charters: 36 of L7's 80 turns"],"fallback":"leave and flag"}
{"id":"rotation.agree-else-flag","name":"Vision checked by PP-LCNet, else leave and flag","family":"mac","app_route":null,"status":"measured","needs":{"key":[],"cluster":false,"mac_gb":null},
 "figures":{"owner-heldout":{"value":"5 of 119 wrong (<=9.5%), 14 flagged; 414/476 turns (87.0%)","n":119,"truth":"constructed turns","source":{"file":"rotation-routes.md","route":"agree, else leave and flag","attribute":"held out, all 119","value":"101/119 right, 5 wrong (≤9.5%), 14 flagged"}},
  "owner-heldout-setapart":{"value":"1 of 114 wrong, 13 flagged","n":114,"truth":"constructed turns, 5 pages set apart","source":{"file":"rotation-routes.md","route":"agree, else leave and flag","attribute":"Pages, without them","value":"101/114 right, 1 wrong (≤4.8%), 13 flagged"}},
  "L1+L4":{"value":"0 wrong, 10 of 160 turns flagged","n":160,"truth":"as rotation.vision L7","source":{"file":"rotation-routes.md","route":"the free rule","attribute":"Verdict","value":"0 wrong and 10 of 160 flagged"}},
  "L7":{"value":"66 of 80 turns flagged","n":80,"truth":"as above","source":{"file":"rotation-routes.md","route":"the free rule","attribute":"Verdict","value":"L7 66 of 80"}},
  "N4":{"value":"78 of 80 turns flagged","n":80,"truth":"as above","source":{"file":"rotation-routes.md","route":"the free rule","attribute":"Verdict","value":"N4 78 of 80"}}},
 "cost":{"usd_1000_list":0},"time":{"per_unit_s":0.17,"measured":true},
 "conditions":["PP-LCNet (Apache-2.0, about 7 MB, 0.02 s) converted to Core ML and checked against the bench's answers (W46.rotation-default)"],"fallback":"leave and flag"}
{"id":"rotation.agree-else-llmsingle-gw","name":"Vision and PP-LCNet agree, else Gemini 3.7 Flash comparative call (gateway)","family":"cloud","app_route":null,"status":"measured","needs":{"key":["stanford-gateway"],"cluster":false},
 "figures":{"owner-heldout":{"value":"7 of 119 wrong (<=11.6%); 448/476 turns (94.1%, 89.9-97.5); 45 calls for 476 turns","n":119,"truth":"constructed turns","source":{"file":"rotation-routes.md","route":"agree, else llmSingle","attribute":"held out, all 119","value":"112/119 right, 7 wrong (≤11.6%)"}},
  "owner-heldout-setapart":{"value":"2 of 114 wrong (<=6.2%), both near-blank covers","n":114,"truth":"constructed turns, 5 pages set apart","source":{"file":"rotation-routes.md","route":"agree, else llmSingle","attribute":"Pages, without them","value":"112/114 right, 2 wrong (≤6.2%)"}},
  "public-6":{"value":"462/480 (96.2%)","n":480,"truth":"public strata's stored orientation","source":{"file":"rotation-routes.md","route":"agree, else llmSingle","attribute":"Pages the public set may store turned, as stored","value":"462/480 (96.2%)"}},
  "L7":{"value":92.5,"n":80,"truth":"as above","source":{"file":"rotation-routes.md","route":"agree, else llmSingle","attribute":"By stratum","value":"74/80 (92.5%)"}}},
 "cost":{"usd_1000_list":1.0,"source":{"file":"rotation-routes.md","attribute":"$ a page","value":"0.0010"}},"time":{"per_unit_s":1.86,"measured":true,"measured_on":"gateway round trip"},
 "caveats":["usd_1000_list is the file's $0.0010 a page times 1,000 = $1.0; an estimate at list, the gateway returns no bill","no app route runs Gemini 3.7 Flash; hasRoute is false for the gateway (P9-3)"],"conditions":["PP-LCNet in the app","a gateway rotation route"],"fallback":"rotation.vision"}
{"id":"rotation.llmsingle-gw","name":"Gemini 3.7 Flash, one comparative call (gateway)","family":"cloud","app_route":null,"status":"measured","needs":{"key":["stanford-gateway"]},
 "figures":{"owner-96-dev":{"value":"384/384","n":96,"truth":"constructed turns","caveat":"no held-out owner figure for llmSingle alone","source":{"file":"rotation-routes.md","route":"llmSingle","attribute":"By stratum","value":"384/384 (100.0%)"}},
  "L7":{"value":98.8,"n":80,"truth":"public stratum's stored orientation","source":{"file":"rotation-routes.md","route":"llmSingle","attribute":"By stratum","value":"79/80 (98.8%)"}},
  "N1":{"value":88.8,"n":80,"truth":"as L7","caveat":"as stored; 2 pages the set may store turned","source":{"file":"rotation-routes.md","route":"llmSingle","attribute":"By stratum","value":"71/80 (88.8%)"}},
  "N4":{"value":98.8,"n":80,"truth":"as L7","source":{"file":"rotation-routes.md","route":"llmSingle","attribute":"By stratum","value":"79/80 (98.8%)"}},
  "N5":{"value":97.5,"n":80,"truth":"as L7","source":{"file":"rotation-routes.md","route":"llmSingle","attribute":"By stratum","value":"78/80 (97.5%)"}},
  "public-6":{"value":"467/480 (97.3%) as stored","n":480,"truth":"as L7","source":{"file":"rotation-routes.md","route":"llmSingle","attribute":"Pages the public set may store turned, as stored","value":"467/480 (97.3%)"}}},
 "cost":{"usd_1000_list":3.7,"source":{"file":"rotation-routes.md","attribute":"$ a page","value":"0.0037"}},"time":{"per_unit_s":5.79,"measured":true},
 "kind_rules":["the route for charters and non-Latin scripts"],"caveats":["usd_1000_list is the file's $0.0037 a page times 1,000 = $3.7; an estimate at list","P9-3 as above"],"fallback":"rotation.vision"}
```

Stage rules and fallback (the `rules` and `fallback` keys of the stage object):

```
{"rules":[
 {"id":"rotation-by-profile","text":"Free: Vision checked by PP-LCNet, else leave and flag. Gateway: agree, else llmSingle. Charters and non-Latin scripts: llmSingle on every page where a cloud route exists.","source":"rotation-routes.md §Held out","switch":null},
 {"id":"straighten-after-ocr","text":"Deskew the reading copy after OCR when the median Vision line angle is 1 degree or more; nothing is cropped.","source":"place-geom-real5.md §Verdict","switch":{"id":"reading_copy.straighten","label":"Straighten sloping pages","default":true}},
 {"id":"no-crop-no-dewarp-on-reading-copy","text":"No crop, dewarp or shading division on the reading copy, and none offered for viewing.","source":"place-geom-real5.md §Verdict","switch":null},
 {"id":"ocr-send-2048-q85","text":"Readers receive the 2,048 px long side at JPEG 0.85.","source":"enh-dewarp.md §The app's encoding","switch":null}],
 "fallback":"leave the page as photographed"}
```

## 5. Caveats carried

- **P9-1 (major).** Vision's 99.0% on the 96 is RotationDetector's development set on a 20-word Vision-filtered draw; every rule cites the held-out 119 (rows above), and the 96 appear only labelled "dev" [M].
- **P9-2.** The public "without" figures (llmSingle 98.9%) are an upper bound chosen by llmSingle's own answers; rows quote the as-stored 97.3% [M].
- **P9-3.** The cloud rotation figures are Gemini 3.7 Flash through the gateway; the app's direct keys ask gemini-2.5-flash-lite, gpt-5.4-mini or claude-sonnet-4-6, unmeasured, and the gateway has no rotation route. No row carries an app_route until one runs the measured model; a direct-key default waits on measuring that key's model (item 2) [M].
- **P10-7.** The five set-apart held-out pages rest on the routes' agreement, unchecked. Rows give as-stored first. Setting them apart lowers wrong pages by different amounts (Vision 6 to 2, free rule 5 to 1, cloud rule 7 to 2) and turns Vision against the cloud rule from 6 against 7 into a tie at 2 [M, rotation-routes.md §"Held out"]. Seven of PP-LCNet's nine held-out wrong pages are filter-replaced pages turned by `orient_like_pdf`, which can leave photos rotated (P10-7) [M].
- **P10-5.** Level-page deskew is −0.1 (−1.5 to +1.2), not +0.1; UVDoc's 443 removed own-sheet words lie on 84 images (128 lose anything); page-clustered intervals are no wider (overall +27.3 to +38.6, mild +2.8 to +9.1) [M].
- **P9-5.** Shading division greys coloured marks (−18.2 colour points, −33.0 to −4.7, enh-ocr-marks.md); the figure did not settle whether that removes content, so it went to the owner (below).
- **ENH-1 / OCR-8.** Worded as the audit asks: no dewarp by default on box photographs of loose sheets; strongly curled or bound pages untested. Curl-tagged originals are 10, perspective 18, intervals about ±10 (Vision curl UVDoc +1.9, −0.7 to +4.8) [M]. The capture ladder's tilt half is done: quad correction recovers nothing (tilt 12: −0.7 against −1.2; tilt 20: −1.7 against −1.4) (capture-ladder.md) [M]. Real5 Warping OCR (W46.dewarp-guard): Vision raw 78.5, quad +1.1 (−1.3 to +3.4), UVDoc +6.0 (+3.5 to +8.8) [M, dewarp-guard.md]. Pages whose lines fan most are now measured for selection (W46.place-curved-owner): on the 32 sample pages at the line-angle cue's top 1% (covers, display type and some handwriting among them as well as bound volumes; not classed as bound or curled) the print layer passes 74.3% of lines against 94.1% on same-collection flat pages, −19.8 (−26.2 to −12.8); −17.1 (−23.5 to −9.4) without the owner-tagged handwritten and clipping pairs; one level run per line cannot follow a bent line [M] (place-curved-owner.md).
- **ENH-2.** Image-preparation headlines quote the 63 originals: Gemini 3.7 Flash quad −0.3 (−1.5 to +1.4), UVDoc −2.5 (−5.6 to +0.1), DocRes −12.1; Qwen3.6-27B UVDoc −2.8 (−7.4 to +1.1); Vision UVDoc −1.7 (−5.3 to +1.8) (enh-dewarp.md) [M].
- **ENH-3.** The null for small readers is about ±5 NES for Qwen3-VL 8B; stated beside any "no gain" for the laptop profile [M, audit].
- **ENH-4.** The 96's edge losses, split (W46.dewarp-guard): quad 44 truth words = 19 own-sheet (4 pages) + 25 neighbour; UVDoc 429 = 397 own (41 pages) + 32 neighbour; on the 63 originals UVDoc 170 = 138 own (27 pages) + 32. Real5: quad 79 own, 65 neighbour; UVDoc 443 and 97 (place-geom-real5.md; 495 and 97 in dewarp-guard.md's rerun) [M]. The no-crop rule holds on own-sheet losses alone [M, dewarp-guard.md].
- **Vision 26.6.** enh-dewarp.md's Vision arms are macOS 26.6 readings, not comparable with the 27.2 route until re-read (W46.vision-27-swap) [M].
- **Curvature trigger.** No reference-free dewarp trigger: angle residual and UVDoc bend correlate with gain at ρ −0.18 to −0.03, none significant (enh-dewarp.md) [M]; D §8 test 5 answered no.

## 6. What would change the rule

- A dewarper whose image removes no own-sheet word on the 63 originals and on Real5, and whose NES gain over raw has a paired interval above 0 for Gemini 3.7 Flash or Qwen3.6-27B on the originals; today UVDoc removes text on 31 of 63 originals (170 words) [M]. The own-sheet guard (dewarp-guard.md) meets the first half by construction and passes UVDoc on 24 of 63 originals, but guarded UVDoc's gain there is Gemini +0.4 (−0.6 to +2.0), Qwen −0.5 (−3.2 to +1.6): not yet met [M]. On the owner's bound or curled pages a guarded copy would be judged on selection (W46.dewarp-curved-select).
- PP-LCNet shipped in the app (turns the agreement rule from "measured" to "shipped").
- A gateway rotation route on Gemini 3.7 Flash, or a direct-key model measured on the 864 turns and the held-out 476 within one Wilson interval of 3.7 Flash.
- A held-out owner figure for llmSingle alone, or a new owner kind (bound volumes, curled pages) where curl-tagged pages exceed the 10 now scored. The second half has evidence for selection, not yet the measure (W46.place-curved-owner, 2026-11-11: the 32 pages whose lines fan most, −19.8, not classed as bound or curled; measurement review pass 12, P12-5); the 64 pages are classed by the owner or a gateway model and the gap restated on the bound or curled pairs before it counts; the 2026-11-06 call stands until the owner revisits it (W46.dewarp-guard).

## 7. Owner calls

All four were decided on 2026-11-06; the decisions are in "Owner's calls (2026-11-06)" below. The evidence he was shown:

1. **Rotation default and routes (W46.rotation-default).** Options: (a) llmSingle as the default (today's; on the gateway it silently runs Vision); (b) the agreement rule per profile; (c) Vision alone. Held out: free rule 5 of 119 wrong as stored (1 of 114 set apart), 14 flagged; cloud rule 7 of 119 (2 of 114), 45 calls for 476 turns; Vision 6 of 119 (2 of 114); llmSingle public 97.3% at $0.0037 a page against the cascade's 96.2% at $0.0010 (rotation-routes.md) [M]. Recommended (b).
2. **A dewarped reading copy (place-geom-real5.md).** Options: (a) never; (b) only where a per-page check shows the lattice keeps every word; (c) research only. On Real5 UVDoc passes 88.1% of line drags, +7.9 over deskew (+3.1 to +12.9), but cuts 900 of 15,067 truth lines and removes 443 of the page's own words on 84 of the 310 images (128 lose something: a truth line, an own-sheet or a neighbour word); on the owner's 58 placement-truth pages it lost to raw on every stratum (−8.6, −12.4 to −5.0, place-geom.md); as OCR input it costs Gemini −2.5 on the originals (enh-dewarp.md) [M]. Neighbour-sheet text (ENH-4) was part of the call. Recommended (a), revisit after item 3.
3. **The Straighten default.** Deskew removes no word, +33.1 (+25.6 to +40.7) on Real5, +5.7 at 1° to 3°, +6.8 (+3.4 to +14.2) on the 96's skewed pages, nothing below 1° [M, place-geom-real5.md]. Recommended on.
4. **Deskew's trigger, shown settled.** The 1° median line angle: below it −0.1, above it more lines on 162 of 229 skewed images and fewer on 20 [M, place-geom-real5.md].

## 8. Items to file

1. **W46.rotation-default** (exists, S): builds owner call 1 (option b, decided 2026-11-06); PP-LCNet Core ML conversion checked against the bench's answers; a gateway rotation route; rows quote as-stored beside set-apart. Waits on this note's walk.
2. **W46.rotation-direct-keys** (S, paid): gemini-2.5-flash-lite, gpt-5.4-mini and claude-sonnet-4-6 on the same 864 turns and the held-out 476; llmSingle's 864 turns cost $3.24 on the gateway, and a personal key is real money, so the total is priced and asked under the $7 rule first (P9-3). Done: a held-out figure per direct-key model. Owner call 1 is decided; waits on the $7 ask.
3. **W46.dewarp-guard** (M): done 2026-11-11, with item 4 folded in (`dewarp-guard.md`). Follow-up: **W46.dewarp-curved-select** (S, free), guarded UVDoc for selection on place-curved-owner's 24 bound or curled pages.
4. **W46.dewarp-real5-ocr**: folded into W46.dewarp-guard; done.
5. **Re-read enh-dewarp's Vision arms on 27.2** (S, free), unless W46.vision-27-swap already queues it [?].
6. **Gaps for the table:** the app_route ids for Vision's rotation and any LLM rotation route [?]; measured peak memory for PP-LCNet in the app; the stored reading copy's own pixel size, which no input states [?]; cloud seconds tabulated (`measured: false` until then); `time.source` on every rotation row (rotation-routes.md §"Money, time and memory"); `cost.price_read` on the gateway rows.

## 9. Profile test expectations

- **Laptop, 16 / 32 / 64 GB (no difference by tier):** Latin modern: `rotation.vision` until PP-LCNet ships, then `rotation.agree-else-flag` (held out 5 of 119 wrong, 14 flagged). Charters and non-Latin: the same rule flags most pages (L7 66 of 80); the solver shows "needs a cloud rotation route". Straighten on unless switched off; no dewarp; no shading division; send 2048/0.85.
- **Cheap API:** no OpenRouter rotation route measured (none found in the inputs); same picks as the laptop.
- **R5, plans through a local CLI:** none found; no plan-route rotation or geometry arm exists (10-gap-audit.md, reading-copy rows); laptop picks.
- **R6, commercial document services:** none found; the gap audit names only TextIn's unwarp (elsewhere: PaddleOCR-VL's edit 37.5 photographed, 15.9 unwarped, 10.5 original, L claim 8) and Azure DI Read's size limits (10-gap-audit.md, R6 row).
- **Premium APIs or plans, with the gateway:** Latin modern `rotation.agree-else-llmsingle-gw` (7 of 119, 45 calls for 476 turns); charters and non-Latin `rotation.llmsingle-gw` (L7 98.8, N4 98.8, N5 97.5, N1 88.8). Direct key only, or a plan: no measured row (P9-3); the solver falls back to the laptop pick and says so.
- **Cluster:** no rotation or geometry route differs; laptop picks.
- **Any of these plus a coding agent:** the base profile's picks; nothing in this stage is trained.

## Owner's calls (2026-11-06)

From `14-owner-calls.md` §1 call 6 and §2 "Rotation"; section 3 and the rules block carry them.

- **Straightening:** on by default at a median line angle of 1 degree or more (his "above 1 degree"), switchable off; the switch default is `true`. The deskew trigger stands.
- **Dewarping:** not offered (UVDoc removes content; no per-page guard existed). The guard is now measured (item 3, `dewarp-guard.md`) for his revisit.
- **Shading division:** not offered for viewing. This note is the call's home; 02 and 06 point here. He judged the colour loss on marks, -18.2 colour points (-33.0 to -4.7), reason enough.
- **Rotation:** option (b) as recommended, the cloud arm on the gateway only until a direct-key model is measured (P9-3); the five set-apart pages go to him in a later sheet (P10-7).

Files read: execution-plans/processing-review/00-plan.md (lines 1-105); 13-stage-rules/00-index.md (worktree suite-wt-20261106-205546-44529); 14-owner-calls.md; 10-gap-audit.md (reading-copy route rows); D-enhancement.md §3 (dewarp claims), §5, §8, §9; L-capture.md §5 and claims 39, 45; ArchiveProcessor/segbench-results/rotation-routes.md, enh-dewarp.md, enh-dewarp-uvdoc-bench.md, place-geom-real5.md, place-geom.md (Verdict), enh-ocr-marks.md (Verdict), capture-ladder.md (findings, card); 11-measurement-audit.md lines 425-473; measure-reviews/2026-11-05.md (P9-1, P9-2, P9-3, P9-5, P9-7), 2026-11-05-2.md (P10-5, P10-7, §1), 2026-11-01.md (geometry row); SUITE_TODO.md (W46.rotation-default); settings-design/figures.json ("fixed").
