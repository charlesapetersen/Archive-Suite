# 11. Phone capture: what the companions set and check (stage rule note)

Drafted 2026-11-06 for Phase 4 from `L-capture.md` (sections 5, 6, 7, 9), `capture-ladder.md`, `capture-tags.md`, `11-measurement-audit.md` and the measure-review passes. Figures are tagged [M] measured, [I] inferred, [?] unverified, and each names its file.

## 1. Stage and question

The stage is the phone photograph before it leaves the iOS or Android companion: the camera settings, the framing guidance, and any check run on the frame. The user chooses nothing here. The companions apply one rule set, and the reader that later reads the page is not known at the shutter.

## 2. Is there a choice?

No. The rule is the same for every profile and every route. The measured reason: the readers differ by an order of magnitude in how much blur costs them (Apple Vision -53.8 NES points at defocus sigma 5, Qwen3.6-27B -15.1, LightOnOCR-3 4B -15.3; `capture-ladder.md` per-reader tables) [M], and the phone cannot know which reader will run, so guidance is set for the most fragile reader. There is no switch. The only user-facing control is the retake the companion offers.

## 3. The rule for the settings layer

Text the sheet shows: "The capture app photographs each page at full sensor quality with the flash off, keeps the original JPEG untouched, and tells you when the frame is likely to read badly. Hold the phone still, avoid reflections, keep the page edges and only that page in the frame. The Mac reads a copy sized to 2,048 pixels on the long side at JPEG quality 0.85."

Metric and tie rule. The metric is the change in strict NES within one reader, paired by page against that reader's own plain image, with a 95% bootstrap interval (`capture-ladder.md`, header and measurement card) [M]. A change whose interval crosses 0 is read as no effect. The practical floor for the two Sherlock readers is the JPEG 75 and 85 rows, 0.3 and 0.1 from raw (card, Noise); Apple Vision is taken as deterministic, a claim that rests on one tool and one handwritten page (P8-2: the two tools disagree on three handwritten originals on 27.2); Gemini 3.7 Flash's rerun range is 0.24 points.

Settings the companions set (until W46.capture-companions, 2026-11-13, they set nothing and checked nothing: iOS used `.photo` with default `AVCapturePhotoSettings()`, Android passed only an output file; L-capture claim 37) [M code read]. Now set: iOS `CaptureSettings` in `CameraController.swift`, Android `CaptureCameraDefaults.kt`; neither checks anything:
- Flash off on both platforms, explicit. Reading rooms forbid it ("Flash photography is not permitted", UK National Archives, L-capture claim 36) [M]. The iOS default flash mode was never read on a device (claim 38) [?], so it is set, not inherited; the question no longer bears on the app.
- Full-resolution still capture, no digital zoom, no downsizing preset. The corpus photographs are 2,592 px or more on the long side (`kind-classifier.md` as cited in claim 46) [M].
- iOS `photoQualityPrioritization` raised from the default `.balanced` to `.quality` (the output's maximum is set to `.quality` and each shot takes the maximum), and the JPEG codec set explicitly (default [M] from WWDC21; the gain for document shots is unmeasured) [I]. Size stays the `.photo` preset's full-sensor 12 MP; the 48 MP opt-in is not taken. Android: `CAPTURE_MODE_MAXIMIZE_QUALITY`. Read from the CameraX 1.3.4 bytecode (W46.capture-companions): the default capture mode is MINIMIZE_LATENCY, and with no JPEG quality set the quality follows the mode, 100 under MAXIMIZE_QUALITY and 95 otherwise; the default resolution selector is the highest available at 4:3 [M, library read; not run on a device]. CameraController 1.3.4 has no JPEG-quality or selector setter, so the mode gives quality 100 and the size is left at the default.
- Focus and exposure locked on the page once settled, as DocScan does (claim 25) [I; not measured by us].
- No on-phone binarisation, crop, enhancement or filter. The raw JPEG is what the Mac receives, as the owner's reading-copy rule requires (L-capture section 6.2 item 5) [I].

Guidance shown before the shot, from the ladder: hold the phone still and avoid reflections, because glare, motion blur and heavy defocus cost every measured reader and nothing else measured does [M]. Tilt up to 20 degrees and JPEG quality 60 to 85 need no warning for any reader [M, synthetic].

Checks. Evidence supports warnings only, never a refusal. The companion always keeps the photograph and always sends it if the user keeps it. A warning is advice with a one-tap retake. No live check ships until the threshold passes the condition in section 7. Until then the guidance above is static text.

Kind rules: handwritten pages lose most to glare (27B -12.9, Gemini 3.7 Flash -16.1 on 8 handwritten pages) and typed and printed pages lose most to blur on PDF images (27B motion 31 px -57.3 against -27.3 on phone originals; `capture-ladder.md` group tables) [M]. The guidance is the same for all kinds.

Fallback when a photograph reads badly on the Mac: the existing text-page and cascade handling (stages 04 and 10). The companion's retake is advice, not a gate. Must not run: any content-removing capture filter, and any on-phone reader.

Image size the Mac sends a reader (rule, from L-capture claim 39, `ImageEncoding.swift` 7-69): long side capped at 2,048 px, JPEG quality 0.85, never upscaled. The bench ran 2,400 px at quality 90, and the segmentation windows run at 1,600 px. The app's own encoder at 2,048 / 0.85 against the panel's 2,400 / 90 on the 96 is a tie or a gain for every reader measured: Apple Vision +0.5 (-0.5 to +1.8), Qwen3.6-27B -0.3 (-1.5 to +0.7), LightOnOCR-3 4B -0.4 (-1.5 to +0.3), PP-OCRv6 +0.8 (+0.2 to +1.5), Gemini 3.7 Flash -0.1 (-0.4 to +0.3) [M, `enh-dewarp.md` §"The app's encoding"; the Vision row is a dated macOS 26.6 reading]. This is L-capture test 5, run there.

## 4. Table rows

Routes: none (no choice). The stage object for `settings-routes.json`:

```
{"id":"capture","name":"Phone capture","unit":"pages","choice":false,
 "metric":{"id":"delta_nes_strict_paired","label":"Change in strict NES within one reader, paired by page","higher_is_better":true},
 "kinds":[],"fallback":"text-page","routes":[],
 "rules":[
  {"id":"cap-flash-off","text":"Flash off, explicit, on both companions","source":"L-capture.md §3 claim 36","switch":null},
  {"id":"cap-raw-full","text":"Full-resolution original JPEG kept untouched; no on-phone processing","source":"L-capture.md §3 claim 37","switch":null},
  {"id":"cap-warn-only","text":"Checks warn and offer a retake; they never refuse","source":"capture-ladder.md §Capture-time signals against a loss of 5 NES points or more","switch":null},
  {"id":"cap-guidance","text":"Hold still, avoid reflections; no tilt or compression warning","source":"capture-ladder.md §Findings","switch":null},
  {"id":"cap-mac-size","text":"Mac sends 2048 px long side, JPEG 0.85, never upscaled","source":"enh-dewarp.md §The app's encoding","switch":null}]}
```

## 5. Caveats carried

- CAP-1 (audit lines 474-480): Claude subagents drafted the capture tags; presence kappa against a blind retag is 0.14 (low light), 0.24 (glare), 0.33 (shadow), 0.39 (edge cut), 0.43 (defocus), 0.47 (perspective) (`capture-tags.md`) [M]. No rule here slices by an optical tag or routes on one. The tags enter only as direction for framing: edge cut -6.4 median NES points (26 of 29 routes worse), colour -4.1 (27 of 29), mixed -3.0 (26 of 29), neighbour -1.9 (21 of 29) (`capture-tags.md`) [M, weakened]. The audit says the edge-cut and colour aggregate losses, consistent across 26-27 of 29 routes, hold. The per-tag optical figures (glare +2.0, defocus +2.2, low light +9.0 on 3 pages, motion blur 0 pages) are not used. The neighbour figure is not named by the audit as holding, and its kappa is 0.60, so it supports guidance wording only.
- Sharpness and the ladder's tag split: no ladder tag effect is separable from native size on 20 pages (`capture-tags.md`) [M]. Four of the five defocus-tagged pages are PDF images of 1,255 to 2,538 px that collapse at a quarter whatever their tags.
- P6-6: two capture-ladder sentences outran their evidence. Corrected forms used: no reader is named as forgiving blur unless it has its own figures (Gemini 3.7 Flash now does, section 6); the re-save is not stated as a Vision NES effect. The re-save claim was then reduced further by P7-3 and the Vision re-read (`measure-reviews/2026-11-04-2.md`): the apparent 1.5 bowF1 re-save effect was the macOS update (+1.2, +0.3 to +2.1) and the re-encode alone is +0.3 (-0.3 to +0.9), a tie [M]. Vision's raw row against its re-save is NES +0.0 (-0.5 to +0.6) (`capture-ladder.md`). No rule depends on a re-save effect, and every Vision defect row is paired against the same-run re-save, so its deltas stand (P7-3).
- P7-2: the gateway arm's between-reader motion claim. Corrected form: Gemini 3.7 Flash loses motion 17 px as the open readers do, a tie, not "less well". On the same 48 pages Gemini loses 16.2 NES (-26.1 to -7.7), the 27B 10.4, LightOnOCR 11.7; the paired differences are -5.9 (-16.4 to +4.1) and -4.6 (-16.2 to +6.7), both holding zero (`capture-ladder.md`; P7-2's own 2,000-draw bootstrap gave -15.9 to +3.7 for the first) [M]. Motion 31 px: a tie against the 27B (-8.9, -19.7 to +1.5), resolved against LightOnOCR (+15.1, +3.1 to +27.0). Defocus sigma 5 is resolved: Gemini loses 6.2 (-11.2 to -2.7), 10.5 less than the 27B and 8.0 less than LightOnOCR. Glare ties throughout. These are within-reader deltas on 48 pages; the readers' levels are not compared (card, Truth).
- P7-2 on the verdict: Gemini's quality score separates a 5-point loss at pooled AUC 0.81 to 0.90 across the four readers on 480 defect images, but a page-blind score giving each image its setting's mean verdict reaches 0.83 to 0.91, so it separates defect kinds, not pages. Within one defect its AUC is 0.50 to 0.80, 0.50 at motion 31. The 480 : 48 prevalence is the design's. Its retake advice catches 90 to 96% of losses with false alarms on 30 to 46% of the rest and asks a retake on 8% of the plain photographs [M, synthetic]. For defocus-3 images the retake costs the 27B 2.3, Gemini 1.0, LightOnOCR 1.3 and Vision 16.4, so it is justified only for Vision. The verdict is not used as a page-level check.
- P7-3 and P8-2: every Vision row in the ladder is a macOS 27.2 reading; Vision returns empty on 15 of the 80 L7 public pages on 27.2 (public set, not capture). The ladder's "deterministic" claim rests on one tool and one handwritten page. No capture rule changes.
- P8-3: the 96 were drawn through a 20-word Apple Vision filter (26.6), so no page Vision reads as empty is in them. Vision capture figures are conditional on pages Vision could read.
- Synthetic scope (card, Scope): one defect at a time, Augraphy defaults (ShadowCast's default is faint, so a real shadow may cost more), no combined defects, no real phone captures. All thresholds are in-sample.

## 6. Resolution ladder: what a reader needs

The ladder is 20 pages, original / half / quarter of the native source, each capped at 2,400 px (`ocr-panel-local.md`, ladder rows) [M]. Mean NES: Qwen3.6-27B 96.05 / 95.32 / 71.70; Qwen3.5-27B 85.45 / 93.51 / 58.27; Qwen3-VL 8B 95.14 / 93.36 / 66.74; Qwen3.6-35B-A3B 94.77 / 94.88 / 68.97; gemma4-31b 90.27 / 92.59 / 86.02; Mistral Small 24B 91.68 / 90.54 / 62.96; Gemini 3.1 Flash-Lite 95.69 / 90.70 / 89.74; Apple Vision on macOS 27.2 79.61 / 73.23 / 50.39 (on 26.6 its half and quarter copies read 79.48 and 52.69, the file's header). The fall is page by page: 7 of 20 quarter images and 1 of 20 half images read 10 or more points worse for Qwen3.6-27B, and text height does not predict it (claim 46, `kind-classifier.md`) [M]. Reading [I, from the table]: the half rung costs little for most readers, except Apple Vision on 27.2, whose half copies fall -6.2 (-11.5 to -1.9) (`measure-reviews/2026-11-04-2.md` §1) [M]; the quarter rung costs 25 to 40 points for the Qwen family and Vision, and Flash-Lite and gemma4-31b hold best. Why: accuracy follows text per vision token (claim 15, DeepSeek-OCR 96.5% to 59.1%) [I]. The ladder cannot state a pixel floor, because it has two rungs and its small pages are mostly PDF images.

## 7. What would change the rule

- A warning ships when sharpness inside Vision word boxes (Laplacian variance AUC 0.70 to 0.75, Tenengrad 0.70 to 0.74 against a 5-point loss; image share in word boxes 0.70 to 0.78) holds on real captures with a cut chosen on held-out data. The in-sample cuts differ threefold between readers (Laplacian at most 52.16 for the 27B, 173.3 for LightOnOCR, 173.7 for Vision) (`capture-ladder.md` signals table) [M, in-sample].
- A glare warning needs a different signal. Clipped-highlight share does not detect the synthetic glare (AUC 0.52 to 0.53), luminance is inverted (0.38 to 0.46) and quad-to-frame margin carries no information (0.48 to 0.53) [M]. The margin was measured against synthetic losses, not cut edges, so it does not test framing [I].
- The size rule changes if a reader added to the table loses beyond its interval at the app's 2,048 / 0.85 against 2,400 / 90 on the 96. L-capture test 5 has run for five readers with no loss (section 3; `enh-dewarp.md` §"The app's encoding"); JPEG 60 costs the 27B 1.0 (-3.3 to +0.5) and Vision 0.7 (-1.5 to +0.1) (`capture-ladder.md`).
- A framing warning needs evidence that `VNDetectDocumentSegmentationRequest` finds the page quad on cluttered box photographs (L-capture open question 9), and tags checked by the owner (CAP-1).

## 8. Owner calls

1. Warning policy (queued call: what a check may refuse or warn about). Settled by the figures: no refusal. The best cuts hit 48 to 69% of losses and false-alarm on 17 to 34% of good pages (hit / false alarm 54% / 21%, 66% / 34%, 66% / 28% for Laplacian; 69% / 25%, 63% / 18%, 50% / 17% for word-box share) [M, in-sample]. Open: whether a warning ships before real captures exist. Options: (a) static guidance only until the real-capture arm reports; (b) ship a sharpness warning now at the Vision cut, accepting about 28% false alarms. The pass on 2026-11-03 notes no item ships a warning and one would wait on the real-capture arm. Recommendation: (a).
2. Companion defaults (queued call). Settled: flash off, raw original kept, no on-phone processing (reading-room rule and the owner's reading-copy rule). Not settled by the inputs, and not the owner's: the Android and iOS quality settings, which wait on a device read (item 2 below).

The image-size call is withdrawn: the rule is measured (section 3).

## 9. Items to file

1. W46.capture-real-arm: real phone captures with known truth (L-capture test 10, the owner's five-way series of 20 public-domain pages, or SmartDoc-QA's old letters, test 7), scoring sharpness in word boxes with a held-out cut. Done: a threshold with hit and false-alarm rates on real captures. Size: medium; owner time about 40 minutes for test 10, so an owner review session (judge the timing). Waits on nothing; gates call 1(b).
2. Done inside W46.capture-companions (2026-11-13; never filed separately): the CameraX defaults read from the library bytecode, and the iOS flash mode set rather than read. Was: W46.capture-defaults-device-read: read or test on a device the CameraX default capture mode and JPEG quality, and the `AVCapturePhotoSettings` default flash mode (L-capture open question 4). Done: [?] marks in section 3 replaced. Size: small. Waits on a device.
3. W46.capture-ladder-rungs: intermediate rungs between half and quarter on the 96 originals, to give a pixel floor. Done: a long-side figure per reader class. Size: medium, free. Needed for any minimum-size guidance.
4. W46.capture-framing-check: test 4 (quad crop against raw, the six worst pages hand-cropped) plus an owner spot-check of 20 capture tags (CAP-1: no owner check). Waits on the enh-dewarp geometry signals replacing the tags. Size: medium.
5. Confirm in `ImageEncoding.swift` whether the 2,048 / 0.85 copy is the reading copy as well as the reader copy (claim 39 says what the Mac sends to a reader). Stage 01 owns the reading copy. Size: tiny.
6. R5 plan-route CLI downscale is unknown (L-capture section 9) [?]; filed with the gateway-arm hold.
7. R6, commercial document services: none found. None is recommended for capture; Azure DI Read's limits (10,000 px, text at least 12 px on 1024x768) and Transkribus's DocScan guidance are the only capture facts found, and the search for Document AI, Textract or Extend photographed-robustness figures returned marketing pages (L-capture section 9, R6 row). Nothing to file.

## 10. Profile test expectations

- Laptop only, 16, 32 and 64 GB: same companion rules. Vision or a small open reader is the likely reader, so guidance matters most here: defocus 5 costs Vision 53.8 and the 27B 15.1 (ladder tables). Size rule 2,048 / 0.85. No tilt or JPEG warning.
- Cheap API: same rules. Raw original goes to the Mac, which sends 2,048 / 0.85. Qwen3.6-27B is the measured reader (motion 31 px -37.6, defocus 5 -15.1).
- Premium API or plans: same rules. Gemini 3.7 Flash loses defocus 5 only 6.2 and motion 17 px 16.2, so the retake matters least for defocus, equally for motion (tie, P7-2). Plan route: CLI downscale unknown [?].
- Cluster: same rules. The ladder readers (27B, LightOnOCR) lose 9.3 to 10.3 on glare and 7.9 to 12.2 on motion 17 px, so the guidance holds.
- Plus a coding agent: same rules. A kit-trained model is untested on capture defects (L-capture test 9 unrun).
- By kind: handwritten glare loss largest (27B -12.9); typed and printed PDF images collapse at motion 31 px (27B -57.3, `capture-ladder.md`); no kind gets a different capture rule.

## Owner's calls (2026-11-06)

From `14-owner-calls.md` §2 "Capture", taken on this note's recommendations and open to the owner's veto. Section 3's rule carries them.
- Static guidance only until a sharpness cut is validated on real captures (call 1, option a): the in-sample cuts false-alarm on 17 to 34% of good pages.
- Flash off, raw original kept, no on-phone processing (call 2). The Android and iOS quality settings wait on a device read (item 2).
- The Mac's 2,048 px at JPEG 0.85 stands, as measured (section 3). The owner's summary files L-capture test 5; that test has already run in `enh-dewarp.md` §"The app's encoding" (Vision +0.5, Qwen3.6-27B -0.3, LightOnOCR -0.4, PP-OCRv6 +0.8, Gemini -0.1), so the former call 3 and its paid item are removed.

Files read: `execution-plans/processing-review/00-plan.md` (lines 1-105); `13-stage-rules/00-index.md` (suite worktree); `14-owner-calls.md`; `ArchiveProcessor/segbench-results/enh-dewarp.md` (§"The app's encoding"); `ocr-panel-local.md` (header, ladder rows); `L-capture.md` (sections 5, 6, 7, 8, 9, claims 2, 36-39, 41-46); `ArchiveProcessor/segbench-results/capture-ladder.md`; `capture-tags.md`; `11-measurement-audit.md` (CAP-1 and grep context); `measure-reviews/2026-11-03.md`, `2026-11-04.md`, `2026-11-04-2.md` (P6-6, P7-2, P7-3, P8-2, P8-3 and the capture matches).
