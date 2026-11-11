# 02. Enhancement as OCR input only (stage rule note, Phase 4)

Draft, 2026-11-06. Strand D. Result notes: `enh-ocr-input.md`, `enh-ocr-marks.md` (both in `ArchiveProcessor/segbench-results/`). Tags: [M] measured, [I] inferred, [?] unverified. Every figure is copied from the file named beside it.

## 1. Stage and question

The stage would apply binarisation, shading or show-through removal, restoration or mark removal to a copy of the page that only a reader (an OCR model) sees, never to the image a person sees (owner, 2026-10-20, `00-plan.md`). The question is whether any such copy should be offered to any route; the measured answer for the readers tried is no, so the user has nothing to choose.

## 2. Is there a choice?

No, for the five readers measured. The reason is measured: on the owner's 96 truth pages, five enhancement methods (shading division, GCDRNet, the SBB binariser, DocRes appearance, DocRes deshadow) gave no gain beyond noise to Apple Vision, PP-OCRv6, Qwen3-VL 8B, GLM-OCR or Gemini 3.7 Flash, and several lost (section 4) [M, `enh-ocr-input.md`]. No switch: the owner's switch (on or off) governs the reading copy's content-preserving preparation, which is stage 01. This stage has no switch and no route.

Colour dropout (a stamp in a second ink faded by taking one colour channel; W46.ocr-input-colour-dropout, 2026-11-11) does not change this: on 40 stamp-class pages chosen by a colour cue it ties for Vision (+0.7, -1.3 to +3.1) and loses for Gemini 3.7 Flash (-7.2, -12.6 to -2.7), with a probable Vision gain only where the gateway draft lists a real coloured mark (+3.4, -0.1 to +8.4, 16 pages), which the cue cannot separate from coloured print; R02.1 stands [M, `ocr-colour-dropout.md`, draft truth].

What remains open is coverage, not a choice: the null is tight for Vision and Gemini and wide for the small laptop reader (ENH-3), the 96 hold no page Vision reads as empty, the public strata were not run (OCR-7), and routes outside the five were not tried. These are items (section 8), not decisions.

## 3. The rule for the settings layer

Text the sheet shows: "Pages are read from the image as captured. No cleaning, binarising or mark removal is applied to what a reader sees, and none helped any reader tested."

Rules (for `rules[]` in the table):
- R02.1 Nothing is applied before OCR by this stage; the OCR input is the same pixels as the reading copy's source (the captured image at the app's size cap). Source: `enh-ocr-input.md`, `enh-ocr-marks.md`.
- R02.2 Separation, stated by the layer: the reading copy and the OCR input are two named images. The reading copy takes content-preserving methods only (stage 01, user switch). An OCR input may take any method, but it is transient: never written to the output page, never shown, never a fallback reading copy. Every arm measured keeps the raw image's size, so line and word boxes found on an OCR input apply to the reading copy unchanged (`enh-ocr-input.md`, Comparison) [M]. A method that changes geometry is a stage 01 method, not an OCR-input method [I].
- R02.3 A content-removing method (binarisers, DocRes, GCDRNet, diffusion restorers) never replaces the stored page (`enh-ocr-marks.md`, Verdict) [M].
- Metric and tie rule: NES on the owner's truth, paired by page; a paired 95% interval across 0, or a gap under 0.49 NES, is a tie (`ocr-rerun-noise.md` floor as quoted in the `enh-ocr-input.md` card; measured on Gemini and Qwen, not Vision) [M].
- Headline set: the 63 originals, with the 96 beside them, because the 96 mix in 33 PDF images that went through FineReader (ENH-2).
- Kind rules: none. The stage scores by capture-defect tag and by original or PDF image, not by document kind; no per-kind enhancement table exists (handwritten pages are not scored apart) [?].
- Fallback: not applicable (no route). The built-in behaviour is the raw image.
- Must not run: always, until section 8's coverage items clear a route on both OCR sets.

Proposed replacement for the `enhancement` entry's `fixed` text (`settings-design/figures.json`), split in two because its second clause is stage 01's: "No enhancement of any kind gained any reader tested beyond noise as OCR input; a binariser lost on three of the five readers; so none is applied." The current text says "helps any reader" without naming the readers and cites `enh-dewarp.md` for dewarp; the dewarp clause moves to 01-reading-copy.md.

## 4. Table rows

Stage object:

```
{"id":"ocr-input","name":"enhancement as OCR input only","unit":"pages","choice":false,
 "metric":{"id":"nes","label":"NES against owner truth","higher_is_better":true},"kinds":[],
 "rules":[{"id":"R02.1","text":"Nothing is applied before OCR by this stage; the OCR input is the reading copy's source image at the app's size cap.","source":"enh-ocr-input.md §Measurement card","switch":null},
  {"id":"R02.2","text":"The reading copy and the OCR input are two named images; an OCR input is transient, never written, shown or used as a fallback reading copy.","source":"enh-ocr-input.md §Measurement card","switch":null},
  {"id":"R02.3","text":"A content-removing method never replaces the stored page.","source":"enh-ocr-marks.md §Verdict","switch":null}],
 "fallback":"raw image","routes":[]}
```

Routes: none. Figures behind the "no" (NES change against raw on the 63 originals, then the 96; paired 95% interval; source `enh-ocr-input.md`, tables by reader):

| reader | method | originals (63) | all 96 |
|---|---|---|---|
| apple-vision (macOS 26.6) | shading | -1.7 (-3.3 to -0.4, p 0.020) | -0.6 (-1.9 to +0.9) |
| apple-vision (26.6) | gcdrnet | -2.0 (-4.2 to +0.0) | -1.7 (-3.6 to +0.2) |
| apple-vision (26.6) | sbb | -6.4 (-8.8 to -4.2) | -5.3 (-7.5 to -2.8) |
| apple-vision (26.6) | docres-appearance | +0.7 (-0.5 to +2.1) | +0.6 (-0.8 to +2.2) |
| apple-vision (26.6) | docres-deshadow | -0.3 (-1.0 to +0.4) | +0.3 (-0.6 to +1.5) |
| ppocrv6 | shading / gcdrnet / sbb | -0.5 / -0.9 / -2.3 (sbb -3.8 to -1.0) | -0.2 / -0.3 / -1.9 (sbb -3.0 to -0.8) |
| qwen3-vl-8b | shading / gcdrnet / sbb | +1.1 / +1.1 / -1.1 (all spanning 0, about 4 to 5 points wide each side) | +0.7 (-2.2 to +3.8) / +1.3 (-2.3 to +5.1) / +0.1 (-2.9 to +3.4) |
| qwen3-vl-8b | docres-appearance / deshadow | -0.5 / +0.3 | -1.0 (-5.4 to +3.1) / +0.5 (-2.1 to +3.2) |
| glm-ocr | all five | within -0.6 to +0.2 (sbb -0.6, -1.1 to -0.1) | within -0.0 to +0.5 |
| gemini3.7-flash-gw | shading | -0.8 (-1.6 to -0.2, p 0.010) | -1.2 (-2.9 to -0.2, p 0.002) |
| gemini3.7-flash-gw | gcdrnet / sbb | +0.2 / -1.8 (-3.9 to +0.7) | -0.4 (-1.6 to +1.1) / -1.9 (-3.8 to -0.1, p 0.036) |
| gemini3.7-flash-gw | docres-appearance / deshadow | -0.4 / -0.4 | -0.2 (-0.9 to +0.3) / -0.3 (-1.0 to +0.3) |

PP-OCRv6 did not run the DocRes arms (card: its job read a list made before those images existed) [M]. Raw NES for the 96: Vision 81.4, PP-OCRv6 76.8, Qwen3-VL 8B 91.6, GLM-OCR 85.0, Gemini 3.7 Flash 96.7. Gemini's cost, $1.71 for 480 calls, is an estimate at 3.8 Flash list price (gateway returns no bill). Diffusion restorers on the 30 worst pages: ResShift lowered Qwen3.6-27B by -7.1 (-10.9 to -3.6) and Vision by -5.1 (-12.5 to +2.0); NAF-DPM +1.5 (-0.7 to +4.6) for Qwen3.6-27B; seed instability per 1,000 words 237.8 (ResShift) and 100.8 (NAF-DPM) on Vision, 69.5 and 13.1 on Qwen3.6-27B [M]. Marks (`enh-ocr-marks.md`, faint ink included, 85 boxes on 28 pages): ink kept 97.9 (97.5 to 98.3) for the re-save floor, 97.3 (96.4 to 97.9) shading, 84.9 (79.5 to 89.8) GCDRNet with 6 boxes lost, 75.9 (67.8 to 82.7) SBB with 13 lost [M].

## 5. Caveats carried

- OCR-7: arms are judged against a truth drafted from the unaltered image by two model families, so text an arm reveals is charged as added. The restoration-only counts (Vision SBB 121.0 per 1,000 words, GCDRNet 55.8) are therefore not proof of invented text [?]. The rule is worded "no gain measurable against a truth drafted from the unaltered image". Its fix, checking arm effects on the public strata, is not done (item E3).
- OCR-8 / ENH-1 and ENH-4 concern dewarp and edge loss. They bear on stage 01, not here; the dewarp clause leaves this stage's text.
- ENH-2: the 63 originals are the headline in the table above; the 96 sit beside. On originals the pattern is the same or worse for Vision shading (-1.7, p 0.020) [M].
- ENH-3: "no enhancement for any reader" is underpowered for the small readers. The Qwen3-VL 8B intervals run about 5 NES points each way [M, audit], so a gain of a point or two is not excluded for the laptop reader the stage was meant to help. The rule is therefore "none helped the readers tested", with the coverage item below, not "none can".
- P9-5: shading division greys the marks' colour, a resolved loss and not noise: paired by page against the re-save floor, -18.2 colour points (-33.0 to -4.7) with faint ink and -20.7 (-37.4 to -5.4) clear, on 14 pages and 31 boxes with coloured ink, 10 of the 14 below the floor; GCDRNet -21.1 (-37.9 to -5.0) [M, `enh-ocr-marks.md`]. The colour measure's behaviour on divided images is untested [?]. The older "only SBB's 0% is read" sentence is contradicted and not used. The marks verdict's offer of shading "for viewing" is not carried here; the owner declined it on 2026-11-06, a call recorded in 01-reading-copy.md.
- Vision pairing (P7-3, vision-27-swap): every Vision arm and its raw are macOS 26.6 readings (2026-10-22 to 28), paired with each other. The bench's plain Vision route is now the 27.2 reading (83.07 on the 96, `measure-reviews/2026-11-05.md`; `vision-27-reread.md`), against 81.4 for this table's 26.6 raw. Rows carry "macOS 26.6 pair". The deltas compare two readings from one OS, so they stand as within-OS effects [I]; the levels do not compare with 27.2 figures, and nothing says the 26.6 deltas hold on 27.2 [?]. The suspect-word counts use 26.6 Vision text.
- P9-7: both cards now exist, each marked a dated 26.6 report; the card rule now covers the stage.
- Card scope, carried as conditions: no page Vision reads as empty is in the 96 (19 were replaced at the draw), so rescue of unreadable pages is untested; the diffusion probe's 30 pages were chosen by low readers' scores, so some of their change is regression to the mean [I]; the reference-free suspect gate's thresholds are in-sample.
- The marks card's last sentence ("Gemini on the enhanced images is untouched") is stale: the gateway section of `enh-ocr-input.md` ran Gemini 3.7 Flash on every arm [I].

## 6. What would change the rule

- A reader or method whose paired NES interval on the 63 originals lies wholly above 0 and above the 0.49 floor, and which also passes on the public strata and the marks set (ink kept within the floor, nothing lost). The one lead in hand: glare-tagged pages, Vision with DocRes appearance +10.2 (+0.6 to +25.6, p 0.129) and deshadow +9.2 (+0.2 to +24.8, p 0.129) on 6 pages [M]; six pages and p above 0.1 is a lead, not a result.
- A re-read of the Vision arms on 27.2 showing a gain the 26.6 pairs did not (only if the owner wants R1 enhancement kept open).
- A reader that fails on a class of page (empty Vision readings, severe show-through) where an OCR input could rescue it.
- The app gaining a mark detector (stage 06), which would permit a mark-masked OCR input.

## 7. Owner calls

Both calls were settled on 2026-11-06 (section "Owner's calls (2026-11-06)" below); kept as the evidence shown.

C1. Offer any OCR-input enhancement to any route? Queued call. Settled for the five readers measured: no. Options: (a) keep "none" as the rule with the stated reader list, file the coverage test as an item (recommended: the null is tight for Vision and Gemini, and every other route carries no figure); (b) hold the stage open for the small readers until E1 reports. Evidence: section 4; ENH-3. Nothing here needs money before the owner says so.
C2. Is shading division, which the marks note offers "for viewing", a reading-copy option? It removes no ink (lost boxes 0 of 85) but greys about a fifth of a mark's colour (P9-5), and in OCR use it did not help (Vision originals -1.7, p 0.020). Options: (a) not offered, which stage 06's "marks preserved" reading favours; (b) offered with the colour loss named. The call's home is 01-reading-copy.md, where it is recorded as decided; listed here because `enh-ocr-marks.md` raised it.

## 8. Items to file

- E1 Small-reader power test (ENH-3). Done: states the minimum detectable paired NES effect for Qwen3-VL 8B, Qwen3.6-27B, GLM-OCR, Vision, PP-OCRv6 and Gemini from the per-page paired spreads (`enh-ocr-input-pages.csv`, not read here), then, if a laptop-reader effect of a size that matters is not excluded, runs the arms most likely to help (DocRes deshadow, GCDRNet) on enough pages to exclude it, on the original photographs, both OCR sets. Small, offline for the bound; the extra run is cluster time. Waits on nothing.
- E2 Pages Vision cannot read: a test of DocRes and GCDRNet inputs on pages Vision reads as empty or under 20 words (the 19 replaced at the draw plus public pages). Small. Waits on nothing.
- E3 Public strata (OCR-7, D section 9 q6): run the arms with a non-null prior on the public set's photographed strata, with the 96, same item. Medium. Waits on the strata's photograph-or-scan split.
- E4 Glare lead: 6 pages is too few. Done: glare-tagged originals enlarged (capture tags, `capture-tags.json`), arms DocRes appearance and deshadow, Vision on one OS. Small. Waits on E1's reader list.
- E5 Vision on 27.2: re-read the five enhancement arms on one OS (vision-27-swap's option), free, Mac, under the heavy lock. C1 is settled as "none", so only needed if E4 runs; otherwise leave the dated 26.6 label.
- E6 Marks arm of DocRes (`W46.enh-ocr-input-marks-docres`, behind `W46.nice-to-have`): stays filed; it decides nothing while the app ships no enhancement.
- E7 Table gap (12-settings-design 3.9): per-kind enhancement figures do not exist; hand pages in the 96 are 16 and are not scored apart. Item folds into E1.

## 9. Profile test expectations

For every profile the pick is "no enhancement; OCR input is the captured image", for every kind this stage distinguishes (none; it distinguishes origin and capture tag only).
- Laptop only, 16, 32 and 64 GB (Vision, Qwen3-VL 8B, GLM-OCR): none. Deciding rows: Vision SBB -5.3 (-7.5 to -2.8); Qwen3-VL 8B GCDRNet +1.3 (-2.3 to +5.1), a tie; Vision DocRes appearance +0.6 (-0.8 to +2.2), a tie, and it needs a cluster GPU.
- Cheap API (open-weight hosts): none; Qwen3-VL 8B and GLM-OCR rows all span 0.
- Premium APIs or plans: none; Gemini 3.7 Flash shading -1.2 (-2.9 to -0.2, p 0.002), SBB -1.9 (-3.8 to -0.1).
- Cluster: none; PP-OCRv6 SBB -1.9 (-3.0 to -0.8), ResShift -7.1 (-10.9 to -3.6) on Qwen3.6-27B.
- Any of these plus a coding agent (kit): none; the kit's training rows use the captured image; no measurement says otherwise [?].
- The solver never offers a route here; a test that finds an enhancement row must fail until a table row exists.
- R5, plans through a local CLI: none found. The gap audit's OCR-input row for R3 to R5 recommends none (GPT-4o 6.51 to 6.06 under restoration, elsewhere; Real5 illumination costs frontier readers 0 to 2 points, L claim 6), and plan-route arms wait on the gateway rule (10-gap-audit.md, OCR-input rows).
- R6, commercial document services: none found. Vendor prebuilt enhancement was not surveyed; the one search, in L ("Document AI Textract photographed document skew shadow accuracy"), returned marketing pages (10-gap-audit.md, OCR-input R6 row).

## Owner's calls (2026-11-06)

From `14-owner-calls.md` §1 call 6 and §2 "OCR input".
- **C1 settled as "none":** no enhancement for any route, stated for the five readers measured; the small-reader power test (E1) is filed, not run. Section 3's rule stands as written.
- **C2 settled as not offered:** shading division is not offered for viewing, decided in 01-reading-copy.md (its home). Nothing in this stage changes.

Files read: `00-plan.md` (1-105), `13-stage-rules/00-index.md`, `14-owner-calls.md`, `10-gap-audit.md` (OCR-input rows), `D-enhancement.md` (140-392), `enh-ocr-input.md`, `enh-ocr-marks.md`, `11-measurement-audit.md` (420-473), `settings-design/figures.json` ("fixed"), `measure-reviews/2026-11-05.md` (lines 20-32, 118-165), `2026-11-04-2.md` (90-136), `2026-11-04.md` (136-150), plus greps of `2026-10-31-2.md`, `2026-11-04-2.md`, `2026-11-04.md`, `2026-11-05.md`.
