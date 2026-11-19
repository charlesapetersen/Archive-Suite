# 16. Features withheld for a quality floor — for the owner's review (W47.withheld-review)

*Built from `16-withheld-review.json` by `ArchiveProcessor/scripts/segbench/withheld_review_sheet.py md`; edit the JSON, not this page.*

Your rule of 18 November (14-owner-calls.md call 13): nothing is withheld for missing a quality floor without your confirmation. These are the withholdings made before it, found in the app's code, settings-routes.json (a route whose condition reads "not offered" is hidden by SettingsRouteTable.offered), the stage notes and the DONE entries. Left out: your own calls in 14-owner-calls.md section 1, and anything dropped for money, licence, safety or memory. The session decisions in section 2 of that file were put to you for veto, not confirmed, so they are listed. Figures are from ArchiveProcessor/segbench-results/ unless another path is given; an interval is the paired 95% one. Routes that clearly lost to what shipped are grouped into one box per stage so they can be confirmed at once.

**24 entries, about 12 minutes.** Recommendation counts: release 1, release with a label 4, keep withheld 13, ask again later 6.

## Reading

### 1. The "read poorly" flag for readers other than Apple Vision (`read-flag-readers`)

- **Where the withholding is:** OCR/ReadQualityFlag.swift flags Vision readings only; the decision is in the body of 6f87dc24 (W46.post-read-quality-flag), which filed W46.post-read-flag-readers (open, behind W46.capture-warning and so behind nice-to-have).
- **The floor, and where it is written:** At most 5% false alarms on good readings, a reading counted poor under 70 NES (post-read-flag.md).
- **The measured figure:** Vision's own cut (0.9815) holds it: 10 of 21 poor readings caught with 3 of 75 false alarms on the 96, 179 of 231 with 7 of 249 on the capture ladder. For LightOnOCR, disagreement with Vision catches 8 of 11 poor readings on the 96 (73%, 43-90) with 4 of 85 false alarms; cross-validated 62% (56-68) with handwritten pages in and 82% (77-87) on typed pages only (post-read-flag.md). Qwen3.5 9B 33-36%. The same cut flags 21% of Gemini's good readings of damaged images.
- **What the user loses:** No warning at all when LightOnOCR (the free handwriting default), Gemini, Qwen or any cloud route reads a page badly.
- **What shipping it would take:** The disagreement flag on LightOnOCR, labelled "measured on plain photographs"; Gemini left out or shown with its 21% false-alarm figure. Unblocking W46.post-read-flag-readers from nice-to-have.
- **Recommendation: release with a label.** LightOnOCR clears the false-alarm floor and catches most of its poor typed readings, and about three in five with handwriting in; it is the free handwriting default, where a silent poor reading costs the most. The label should say how much less it catches on handwriting.

### 2. Readers with no row on the reading chart: Apple's on-device model, the commercial services, and fifteen dominated routes (`reading-dominated`)

- **Where the withholding is:** settings-routes.json reading rule no-apple-fm; 04-reading.md section 3 (l.76) and section 4 (l.180-219).
- **The floor, and where it is written:** Beating, or tying at lower cost, a route already on the chart.
- **The measured figure:** macOS 27 on-device model 42.4 against Vision's 83.1 on the 96 (-40.7, -49.0 to -32.5), 33 of 96 pages looping (r1-foundation.md). Azure 89.6, Textract 86.6, Transkribus 82.5 against Mistral 4.1's 92.5 on 25 pages (Azure -2.9, -6.3 to -0.2). Fifteen hosted and cluster routes (qwen3-vl-8b, qwen3.5-122b-a10b, glm-ocr, lightonocr3-0.8b, ppocrv6-medium and others) each below a cheaper or faster route; paddleocr-vl1.5 superseded.
- **What the user loses:** The choice of a weaker but familiar or already-paid-for reader.
- **What shipping it would take:** A "show routes that lost" setting listing them with their figures.
- **Recommendation: keep withheld.** Each is beaten on the same pages by something the user can pick; showing them adds choices that only do worse.

### 3. A post-correction stage after reading (`post-correction`)

- **Where the withholding is:** settings-routes.json reading rule no-post-correction; 04-reading.md l.77-80.
- **The floor, and where it is written:** A gain over re-reading with the same model.
- **The measured figure:** The image-grounded corrector against re-reading with the 27B: -0.42 (-1.47 to +0.64) on the 96, but +1.47 (+0.55 to +2.63) on 120 public band readings; it worsens 4 of 57 and 10 of 120. Text-only correction gains 1.6 on the 96 and nothing on the public set, where it worsens 47 of 120 (ocr-postcorrect.md).
- **What the user loses:** An image-grounded second pass that gains about 1.5 points on public material and ties on yours.
- **What shipping it would take:** The image corrector as an optional stage, labelled with both figures.
- **Recommendation: keep withheld.** On your own material it ties; the public gain is real but small and costs a second 27B pass per band. Text-only correction stays out either way. A label would be a fair alternative if public-material users matter.

### 4. Cascade triggers other than failure: log-probability and two-reader disagreement (`cascade-triggers`)

- **Where the withholding is:** 04-reading.md l.79 and l.344; 10-kinds-and-routing.md l.50 (casc-disagree-0.5, "not built"). Owner call 5 made failure the only trigger and the Vision word-count trigger opt-in; these two were left out before that call by the session.
- **The floor, and where it is written:** A consistent gain on unseen pages.
- **The measured figure:** Log-probability shown only as a "check this reading" flag (ocr-logprob.md); disagreement and kind triggers "gain inconsistently on unseen pages"; the disagreement trigger "wants a larger test".
- **What the user loses:** A second reading on pages the first reader probably got wrong but did not fail on.
- **What shipping it would take:** A larger disagreement test, then an opt-in trigger beside the word-count one.
- **Recommendation: keep withheld.** Your call 5 already settles the cascade's design; these sit inside it and their figures do not argue for reopening it.

### 5. A half-size retry when a cluster reader loops (`half-size-retry`)

- **Where the withholding is:** 04-reading.md section 3 l.91; section 2 Reading ("never a half-size retry on the cluster"); bench-corpus/loop-rerun-20261021.md.
- **The floor, and where it is written:** Rescuing most looped pages.
- **The measured figure:** Answered 351 of 1,573 looped pages on the cluster, 1,216 capped again, and the answers read at 4.2-11.0 NES pooled (bench-corpus/loop-rerun-20261021.md); on the Mac it led on three MLX loops (87.5), n 3.
- **What the user loses:** An answer on a fifth of looped pages, almost all of it unreadable.
- **What shipping it would take:** A retry step before the second-reader fallback, labelled with its answer rate and level.
- **Recommendation: keep withheld.** Its answers read at 4-11 NES, so it rescues almost nothing; the second VLM reader is the real fallback.

## Reading copy and OCR input

### 6. Cleaning the image before reading (shading, GCDRNet, SBB, DocRes, colour dropout, crop as OCR input) (`ocr-input-cleaning`)

- **Where the withholding is:** 02-ocr-input.md sections 2-3 (l.11-61), ocr-colour-dropout.md; 01-reading-copy.md l.20 (crop); section 2 OCR input. Owner call 6 covers only the reading copy.
- **The floor, and where it is written:** The paired interval clearing 0 and a 0.49 NES gap (02-ocr-input.md l.25).
- **The measured figure:** Five methods on 63 originals and the 96: none gained, several lost (Vision with SBB -6.4, -8.8 to -4.2; Gemini with shading -0.8, -1.6 to -0.2). Colour dropout on 40 pages: Vision +0.7 (-1.3 to +3.1), Gemini 3.7 -7.2 (-12.6 to -2.7); on the 16 pages with a real coloured mark Vision +3.4 (-0.1 to +8.4), but no cue picks those pages out. Crop on the originals -0.3 (-1.5 to +1.4). The Qwen3-VL 8B null is underpowered (about 5 NES).
- **What the user loses:** An optional "clean before reading" setting; perhaps a small gain for Vision on stamped pages.
- **What shipping it would take:** A per-route opt-in labelled with its measured change.
- **Recommendation: keep withheld.** No method gains on any reader measured, and the stamp lead cannot be aimed at the pages it helps.

### 7. DocRes cleaning on glare pages (`glare-cleaning`)

- **Where the withholding is:** 02-ocr-input.md section 6 l.79, held as a lead inside the no-enhancement rule.
- **The floor, and where it is written:** A result, not a lead: more than 6 pages, a significant pair.
- **The measured figure:** On 6 glare pages, Vision with DocRes appearance +10.2 (+0.6 to +25.6), deshadow +9.2 (+0.2 to +24.8). The lead is Vision's only: on the same pages DocRes gives Gemini +0.5 (-0.5 to +1.9) and Qwen3-VL and GLM about 0 (enh-ocr-input.md); the 27B was not run.
- **What the user loses:** A possible rescue of glare pages for Apple Vision readings.
- **What shipping it would take:** The larger test, already filed inside W46.enh-small-reader-power (behind nice-to-have); then a glare-tag-triggered setting. DocRes needs a cluster GPU, so it would be a cluster setting.
- **Recommendation: ask again later.** The largest gain in the OCR-input work, but for one reader on 6 pages; the filed test is the way to settle it.

### 8. Rotation without Apple Vision: Tesseract, small local VLMs, PP-LCNet alone on right-to-left pages (`rotation-alternatives`)

- **Where the withholding is:** 01-reading-copy.md section 3 l.18 ("must not run").
- **The floor, and where it is written:** Vision and the agreement rule (3 of 119 held-out pages wrong).
- **The measured figure:** Tesseract OSD 62.7%, Qwen3-VL 8B 78.1% over all turns (rotation-routes.md); PP-LCNet alone flips 73 of 80 Hebrew turns.
- **What the user loses:** A rotation route on a machine without Vision.
- **What shipping it would take:** Rows labelled "below Vision".
- **Recommendation: keep withheld.** Every user of the app has Vision; these turn pages wrong a third of the time or more.

## Layout

### 9. Layout regions off newspapers: other kinds, handwriting, registers; Vision on regions; Apple's document request (`layout-regions`)

- **Where the withholding is:** 03-layout.md section 2 l.15-18 and section 3 l.31 (calls 2-3, section 2 Layout); settings-routes.json layout-never-hands-registers; VisionOCRKit Prefs.swift figures() returns nil for Vision on regions off newspapers.
- **The floor, and where it is written:** Beating the whole page.
- **The measured figure:** On the 96, whole page 90.9 against heron 87.1 (-3.9, -7.7 to -0.3); tables with PP -9.1 (-18.3 to -2.3). On 16 hand pages 70.5 against 85.8 (-15.3, -28.2 to -4.4); on L4's 80 registers -10.8 (-14.8 to -6.8) (layout-photo-tables.md). Vision on regions off newspapers: 1.20% to 1.09% wrong at twice the time, no interval. Apple's document request 16.8 NES on L9.
- **What the user loses:** A region pass that, where measured, loses text, apart from Vision's 0.1-point gain at twice the time.
- **What shipping it would take:** A "read by regions" setting per kind, labelled with these losses.
- **Recommendation: keep withheld.** The losses are measured and large on handwriting and registers; Vision's one gain is a tenth of a point for double the time.

### 10. DocLayout-YOLO as the detector for scanned newspapers (`doclayout-yolo-scans`)

- **Where the withholding is:** 03-layout.md l.25, l.101 and call 1 (section 2 Layout picked PP-DocLayoutV3 for every newspaper).
- **The floor, and where it is written:** Working on photographed newspapers.
- **The measured figure:** On the 15 L9 scans (14 from one collection, mss34132) DocLayout-YOLO as the newspaper-ocr route leads PP-DocLayoutV3 by 4.6 (1.1 to 8.0), descriptive (layout-pair-newspapers.md). The photograph losses (40.1 on Skew, no region kept on 58 of 155 pages) are a different arm, YOLO with the app's region sort; the newspaper-ocr route was not run on photographs.
- **What the user loses:** About 5 points on flatbed-scanned newspapers.
- **What shipping it would take:** The newspaper-ocr processing route (not the app's YOLO arm) as a "scanned newspapers" detector setting, labelled measured on 15 scans from one collection and unmeasured on photographs.
- **Recommendation: release with a label.** A measured gain for users with flatbed scans, common outside your corpus, on a small one-collection set; a label says how thin it is.

### 11. Whole-page reading of newspapers for large readers (the detector is always run) (`layout-whole-page-large`)

- **Where the withholding is:** 03-layout.md call 5 (l.105, l.124); section 2 Layout ("the gain is nil, not negative").
- **The floor, and where it is written:** The reverse case: the detector is kept although it does not help.
- **The measured figure:** 27B whole page 0.967 against raw regions 0.965 on 15 pages, no interval, an inference (03-layout.md l.124); the app ships the partition, on which the 27B was not measured.
- **What the user loses:** The time of a detector pass that adds nothing for large readers.
- **What shipping it would take:** A "read whole" choice for large readers on newspapers, or letting the solver's "faster wins on a tie" rule pick it.
- **Recommendation: release.** A tie on 15 pages; the session's tie rule in section 2 ("faster wins among equal cost", itself open to your veto) points to the whole page.

## Placement

### 12. Other line layers: Orli base lines, Vision's document-request lines, block-emitting readers (`placement-alternatives`)

- **Where the withholding is:** settings-routes.json placement hand-orli-ctc ("not offered; kept as a measured alternative"); 05-placement.md l.90, l.110-125.
- **The floor, and where it is written:** Beating the shipped placer.
- **The measured figure:** Orli lines 38.3% line pass (182 of 475), -4.6 (-14.9 to +4.2), a tie (place-hands-lines.md). Vision document-request lines -10.8 (-15.3 to -6.5) (place-print.md). Unlimited-OCR and Nemotron-Parse 2.0 keep 9.4-13.5% of truth lines whole.
- **What the user loses:** Little: alternatives to a placer that does as well or better.
- **What shipping it would take:** An option in the cluster placement setting.
- **Recommendation: keep withheld.** A tie and two clear losses.

## Marks

### 13. A stamps and signatures layer (`marks-layer`)

- **Where the withholding is:** 06-marks.md sections 2-3 ("not offered yet"); section 2 Marks. You put the two-pass route (W46.marks-detect-own) behind nice-to-have on 6 November; that the layer is not offered at all was the session's.
- **The floor, and where it is written:** Detecting most marks.
- **The measured figure:** Best detector YOLO11m: 8 of 45 marks at 0.25 (18%, 5-37%), 17 of 45 at 0.05 (38%, 21-60%), precision 42-53% (marks-detect.md). A whole page plus a YOLO box adds 0-3 marks per reader, p 0.5 or more.
- **What the user loses:** A list of stamps and signatures on each page.
- **What shipping it would take:** A layer labelled "finds about 1 mark in 5".
- **Recommendation: keep withheld.** At one mark in five with half its finds wrong, the layer would mislead more than help; your nice-to-have item is the route to a better detector.

## Segmentation

### 14. The magazine kind "ranks nothing yet" for routes without the article rule (`seg-magazine`)

- **Where the withholding is:** 07-segmentation.md section 3 rule (a) l.67-78, call 5; settings-routes.json rule magazine-article-rule (5945c0b8).
- **The floor, and where it is written:** A valid comparison: the students trained on the box and the older prompts lack the article rule.
- **The measured figure:** Gemini 3.8 with g2 now ranks (93.8% of gaps against g1's 71.2%, seg-magazine-rule.md); g1, w1, c1 and the students still show figures without being picked.
- **What the user loses:** A pick among the older prompts and the students on magazines.
- **What shipping it would take:** No open item settles the rest: W46.seg-magazine-rule-redo and W46.seg-magazine-rule-app have shipped; c1 waits on W46.gateway-models-ok, and the students need a box they were not trained on (07-segmentation.md l.69-78).
- **Recommendation: ask again later.** A validity gap rather than a missed level, already lifted for the Gemini route; the rest waits on the gateway and a fresh box, so ask again then.

### 15. Segmentation options that did not help: the document-split and feature models, few-shot examples, self-voting, a collection-facts block, letter cue c2, disagreement review on every route (`seg-alternatives`)

- **Where the withholding is:** 07-segmentation.md section 2 l.15, l.87-88, l.275, SEG-4 l.290, call 3 option (b); section 2 Segmentation.
- **The floor, and where it is written:** A measured gain over the shipped prompt.
- **The measured figure:** Split and feature models 27.1% unchecked at 86.8 checks per 100 pages, against the 2B's 79.4% at 78.8 (seg-adapt-curve.md). Few-shot: no measurable gain at 1.43-2.01 times the input tokens (seg-adapt-fewshot.md). Self-voting and the facts block from seg-window-modality.md and seg-context.md, c2 no measured effect. Review on every route doubles the cost while the models err alike.
- **What the user loses:** Settings that cost more and do not change the result.
- **What shipping it would take:** Each as an opt-in labelled "no measured gain".
- **Recommendation: keep withheld.** None changes the result, and most add cost.

## Dating

### 16. The Mac Qwen3-VL 8B image pass on the no-key laptop dating route (`date-8b-image-mac`)

- **Where the withholding is:** settings-routes.json dating qwen3-vl-8b-image-mac (a7068d5f, local baseline 57ddaeee); 08-dating.md call 7.5, "decided as recommended (section 2)", not one of your section-1 calls as pass 16 said.
- **The floor, and where it is written:** "Once its quotes improve the year" over the text-only route.
- **The measured figure:** On 55 documents with no year in their Vision text: strict reading gains 0 and loses 1; as a quote source gains 1 and loses 2 (sign test p 1.0); baseline 33 of 55 (60.0%), both 8B arms 32 of 55; false years on undated documents 20 to 21 of 90 (date-8b-local.md). On the traces it gains 0 (date-route-pipeline.md).
- **What the user loses:** The only page-image dating a 16 GB Mac with no key could have.
- **What shipping it would take:** An optional switch, off, labelled "no measured gain".
- **Recommendation: keep withheld.** No gain on either measure, and it costs a model download and its time.

### 17. Dating options below the baseline: trained 2B and 4B as defaults, typeface and paper dating, look-alike retrieval, an enclosure step, entity links (`date-alternatives`)

- **Where the withholding is:** 08-dating.md 7.4 (l.403-406), step 5 (l.81-83, DAT-4), step 3a (l.36-39, DAT-5), 09-entities.md l.367-369; section 2 Dating; settings-routes.json no-typeface-dating.
- **The floor, and where it is written:** The shipped route's figure, or the simple baseline.
- **The measured figure:** Trained 2B and 4B 38.9% (51 of 131) on years not in the text, against the shipped route's 47.3%; 0 of 50 owner-uncertain documents marked uncertain (date-model.md); the 2B stays as the chooser. Typeface ranges hold the year on 11 of 12 at a median width of 50 years (date-image-typeface.md). Retrieval 27 of 122 exact against 52 for the nearest dated document before (date-image.md). Enclosure: 0 of 3 owner enclosures found on every arm but the 27B (1 of 3) (date-enclosure.md). Entity links bracket 2 of 54 documents.
- **What the user loses:** A coarse range for undated documents (typeface) and "Sent With" dating beyond the near-inert marker.
- **What shipping it would take:** Each as a labelled option ("range, about 50 years"; "found 1 of 3").
- **Recommendation: keep withheld.** Each does worse than what ships or than the simple baseline; the trained models also cite no evidence, which your traceable rule needs.

## Names

### 18. The 8,000-character Gemini entity prompt (`ent-prompt-8k`)

- **Where the withholding is:** 09-entities.md l.133-149 and section 9 l.382-383; settings-routes.json gemini-entity8k.
- **The floor, and where it is written:** A gain over the shipped call; withheld because its 3,000-character twin ties the shipped call, and it was never paired with the shipped call itself.
- **The measured figure:** Sender 0.76 against 0.69, place 0.84 against 0.80. Paired: 8k against 3k +0.087 (+0.022 to +0.170) on sender, though on 88 of 138 documents the two are equal by construction (cached); 8k against the shipped tagging call +0.054 (-0.026 to +0.145), a tie. Rerun drift is +0.044 (0.000 to +0.115) on sender and -0.155 on place, which covers the place gap (ent-score-paid.md). Cost about $3.0 per 1,000 documents, an estimate.
- **What the user loses:** Probably better senders and places on cloud routes.
- **What shipping it would take:** A paired run against the shipped call on the cached owner truth, then the prompt as the default if it holds.
- **Recommendation: ask again later.** Against the shipped call it ties, inside the rerun drift; a paired rerun would settle whether the sender lead is real.

### 19. Names on Macs too small for the 8B (NLTagger, GLiNER2.5), and on pre-modern hands and early print (`ent-small-mac`)

- **Where the withholding is:** settings-routes.json entities nltagger ("never offered… kept as the measured floor"), gliner2.5-base-spans-rule; 09-entities.md section 3 kind rule (e) l.42.
- **The floor, and where it is written:** The 8B extractor's level; no floor is written for kind rule (e).
- **The measured figure:** Sender F1 0.14 (NLTagger) and 0.24 (GLiNER) on 138 owner documents; even a perfect position rule reaches at most 35 and 60 of 138 named senders (ent-truth-owner.md, ent-score.md). Pre-modern Latin hands and early print 0.02-0.37 on L5 and L7 (ent-robust.md).
- **What the user loses:** Any names on an 8 GB Mac with no key, and on medieval and early-modern material.
- **What shipping it would take:** A row labelled "low confidence".
- **Recommendation: keep withheld.** At these levels most names written would be wrong. A cloud route covers the small-Mac case; no route, Gemini 3.8 included (0.12-0.37), covers pre-modern material.

## Kinds and routing

### 20. Routing by kind on pages under the classifier's 0.8 confidence floor (`kinds-under-floor`)

- **Where the withholding is:** settings-routes.json kinds rule low-confidence-keeps-model; 10-kinds-and-routing.md section 3 l.38-43; section 2 Kinds. The 0.8 comes from K-kinds section 5 (W41.app-page-kind); no measurement behind it was found.
- **The floor, and where it is written:** 0.8 on the top class.
- **The measured figure:** 78 of 848 pages fall under it, 17 of them among the 29 pages whose hand differs from the rest of their document (kind-churn.md). Routing by true kind reads 97.26 against 96.47 for the best single reader on the 96 (kind-classifier.md section 4).
- **What the user loses:** Kind routing on about one page in eleven, including most of the odd-hand pages it would help.
- **What shipping it would take:** Route on the top class with an "unsure" mark, or the document prior (filed, not measured); a measurement of the cut itself.
- **Recommendation: ask again later.** The floor itself is unmeasured; measure the document prior and the cut before choosing.

### 21. A mixed-page pre-flag (ATRIUM or another), so the mixed switch acts only on flagged pages (`mixed-preflag`)

- **Where the withholding is:** settings-routes.json kinds atrium-zero-shot ("not offered while the shipped classifier is kept"); 10-kinds-and-routing.md P4-1 l.86-88, l.61, section 6 l.113. Your call 3 set the switch off for its time cost; that is not this.
- **The floor, and where it is written:** Beating the shipped classifier on kinds, and an established filter for mixed pages.
- **The measured figure:** As a kind classifier ATRIUM is worse: 121 of 141 against 137 (p 0.000855), 638 of 895 against 723 (kind-atrium.md). On mixed pages its recall is 51-60% at 69.8% precision, covered-frame point estimates whose finite bounds run 18-95%, against the shipped classifier's 12-14% and Qwen3.6-27B's 23% at 99% precision. Qwen3.6-27B's pre-flag guessed the band on 7 of 14 pages (mixed-route-bands.md); the note says no mixed filter is established. Without a pre-flag the switch costs about 140 times Vision's time on every typed page (ocr-time-like-for-like.md, the like-for-like timing call 3 waited for).
- **What the user loses:** A mixed switch cheap enough to turn on.
- **What shipping it would take:** ATRIUM as an optional download used only as the mixed pre-flag, labelled with its recall, precision and wide bounds; then re-asking call 3 with the timing in hand.
- **Recommendation: release with a label.** Its licence is no longer a bar since 17 November, and as a pre-flag its point recall is four times the shipped classifier's; the bounds are wide, so the label must carry them.

## Capture

### 22. A sharpness or retake warning on the phone, and Gemini's quality score as a retake check (`capture-warnings`)

- **Where the withholding is:** settings-routes.json capture rule cap-guidance ("no tilt or compression warning"); 11-capture.md sections 3, 5, 7, 8 call 1; section 2 Capture. W46.capture-warning (a warning calibrated on real captures) is open behind nice-to-have.
- **The floor, and where it is written:** A cut chosen on held-out real captures (11-capture.md section 7).
- **The measured figure:** In-sample cuts catch 48-69% of losses with 17-34% false alarms on good pages; the Vision cut about 28% false alarms; Laplacian AUC 0.70-0.75 (capture-ladder.md). Gemini's score AUC 0.81-0.90 pooled, below a page-blind 0.83-0.91, and 0.50-0.80 within one defect, on 480 images of 48 pages.
- **What the user loses:** A one-tap retake prompt on a blurred capture; the app shows static guidance.
- **What shipping it would take:** A warning at the Vision cut labelled "in-sample, about 28% false alarms", or W46.capture-warning brought forward from nice-to-have.
- **Recommendation: ask again later.** A warning at a 28% false-alarm rate would nag on good pages; the filed item calibrates on real captures. Bringing it forward from nice-to-have would also unblock the reader flag above.

## Training kit

### 23. Trained segmentation models for small materials (the kit gate's minimums) (`kit-gate-minimums`)

- **Where the withholding is:** 12-training-kit.md section 3 l.49-62, calls 7.2 and 7.5; section 2 Kit.
- **The floor, and where it is written:** Session-set: the paired interval's low end above -3 points, at least 267 known gaps and 10 held-out documents, two scored runs, a 3.2-point anchor margin.
- **The measured figure:** The measured continuation's own next box, Lincoln box 2, holds 244 gaps and so fails the 267 minimum, though its errors fell from 17.2 to 4.9 per 100 gaps (-12.3, -18.8 to -7.4) (seg-kit-gate.md, seg-adapt-lora.md).
- **What the user loses:** Any trained model for a material with under 267 known gaps or 10 documents: bound volumes and registers, which the note names.
- **What shipping it would take:** Admit a model under the minimum with a "small held-out set" label and its interval shown.
- **Recommendation: release with a label.** The one measured case would be refused despite a large, clear gain; a label tells the user how thin the check is.

## Item fields

### 24. Item fields off the remote gateway, and three fields off their measured kinds (`item-fields-routes`)

- **Where the withholding is:** ItemFieldPolicy.skipReason (Tagging/ItemFieldExtractor.swift:269-273): not run on a Local Agent plan or a local-model gateway. ItemFieldPolicy.withheld (l.250-265): byline and publication date only on published kinds, recipient place only on correspondence, "not measured on this kind". Title fills everywhere since your gate (6d1fb653).
- **The floor, and where it is written:** The fill rule: Wilson lower bound 0.85 and point 0.90 on owner-checked pairs (FieldStatus.swift, item-fields-score.md).
- **The measured figure:** On title, only the Gemini 3.7 image prompt fills (0.91, 0.86-0.94 stratified, of 147); GPT 5.6 Luna 0.82 (0.76-0.87), below the bar. The local Qwen 27B, 8B and 4B rows are "too close" or below the bar on the other fields and never fill title, but were scored on ABBYY text, which your 30 October rule bars, so no local route has a valid figure.
- **What the user loses:** Every item field on the Mac and on a Local Agent plan, and three fields on kinds nobody measured.
- **What shipping it would take:** Re-run a local model on Vision text or the page images and score it; then fill under a "lower confidence" status, which the Reader already shows for dates and containers.
- **Recommendation: ask again later.** This is mostly a missing measurement rather than a miss; a local re-run is $0 but needs the heavy lock.

## Left out, and why

- Your section-1 calls: dewarping and shading division not offered (call 6), the handwriting fine-tune dropped (call 7), hand pages flagged "needs a download or a key" (call 4), the mixed switch off (call 3), the hand layer only at 0.9 alignment and every hand page given a text page (call 12, which also covers why free-profile LightOnOCR hand text is not placed on the image), the failure-only cascade (call 5), the 4B entity extractor not offered and no sender from Vision text (call 11 and the 13 November walkthrough; section 2 repeats the 4B as vetoable, so the two sections disagree on whose it is), gemini-tagging-place (call 10), the rerun floor not deciding a pick (call 14).
- A non-explicit date estimate that fails the evidence check is not shown (call 9) "until item 8.3 fixes the checker's false refusals". 8.3 (W46.date-evidence-check) shipped on 11 November, so the condition may now be met; worth a look, but it is your call, not this list's.
- Dropped for money: the image pass only where the text gives no year, and no month or day image pass (about $0.51 per 1,000); the qwen3.5-27b reading rerun waits on the paid hold.
- Dropped for memory: the Mac segmentation LoRA, the PP-OCRv6 hand detector on the Mac (32 GB).
- Dropped for safety: crop and dewarp on the reading copy, under your no-removal rule.
- Never measured, so withheld for want of a figure rather than a miss: direct-key rotation, the ChatGPT plan's OCR row, 27B readers on 32 and 64 GB Macs, Vision on non-Latin scripts, LightOnOCR off handwriting, names on non-correspondence and on a Local Agent plan, the 2B on 8 GB Macs, the right-to-left placement path, a handwritten-date reader.
- No working signal, so nothing to ship: a glare warning (AUC 0.52-0.53 at best), a low-resolution flag, a trained reading-order model (Vision's order 0.972 ties the column sort's 0.971).
- Lifted since: the text-only segmentation tier (your pick, 13 November); the title field (6d1fb653); the OpenRouter listing (W41.app-openrouter-unmeasured).
- Routes hidden by provider terms (15-training-terms.md) are a privacy rule, not a quality floor.
