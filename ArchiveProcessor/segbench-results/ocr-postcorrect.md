# Image-grounded post-correction in the NES 70-90 band (W46.ocr-postcorrect)

C test 6, gap audit §5 item 29: does a correction stage belong in the OCR cascade, and for whom. Produced by
`scripts/segbench/postcorrect.py score --results` from the Sherlock collection of 2026-10-24
(`~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results/postcorrect-20261022`, jobs 49139316, 49139318, 49202351).
Figures: `ocr-postcorrect.json` (means, counts and seeded 95% bootstrap intervals) and `ocr-postcorrect-pages.csv`
(one row per request). No money: the corrector ran on Sherlock.

## Set-up

- **Corrector:** Qwen3.6-27B FP8 on vLLM, thinking off, temperature 0, max 8,192 tokens.
- **Band:** pages a cheap reading scored NES 0.70-0.90 under `ocr_rescore.py`. On the 96, all such pages for Apple
  Vision, LightOnOCR-3 4B on the Mac, Qwen3-VL 8B (the FarmShare panel's reading) and Gemini 3.5 Flash-Lite: 57
  readings. On the 895, 40 a route for GLM-OCR, LightOnOCR-3 4B and Qwen3-VL 8B, spread over L1 (English hands), L2
  (English manuscripts 1700-1850), L4 (ledgers and forms) and L6 (German Kurrent; only 6 band pages): 120 readings.
- **Easy (the abstention check):** 40 readings of the 96 that already scored NES 0.97 or more, 10 a route.
- **Arms:** each reading went twice, with the page image (the design the field calls safe) and as text only (the
  control). Every reply is scored three ways: as sent; **trimmed**, which is *No Free Lunches*' alignment trimming
  (keep the reply between its first and last characters aligned to the reading, widened to word boundaries); and
  **cap-guarded**, which keeps the reading wherever the corrector hit the token cap (the cascade's rule that a cap is
  a failure).
- **Direct:** the same 27B's own reading of each page from scratch (`ocr-scorers-pages.csv`: the local panel's on the
  96, the FarmShare panel's on the 895), with a failed reading falling back to the cheap one. That is what a
  correction stage competes with: either way the page goes once to the 27B with its image.
- The pack's 464 rows hold 434 unique requests (W46.fix-postcorrect-pack); all 434 were answered, every reading
  matched its source, and every band reading recomputes inside 0.70-0.90.

## Results

NES ×100, mean over readings. Worse = readings the reply scored below the reading.

| Set | Pages | Reader | n | Reading | Image arm | trimmed | cap-guarded | Text arm | worse (image as sent / text) | cMER reading → image | added words reading → image |
|---|---|---|---|---|---|---|---|---|---|---|---|
| the 96 | band | all routes | 57 | 84.0 | 89.8 | 89.7 | 89.8 | 85.6 | 4 / 14 | 0.122 → 0.080 | 5.8% → 4.5% |
| the 96 | band | Apple Vision | 16 | 83.3 | 93.1 | 92.5 | 93.1 | 87.7 | 1 / 0 | 0.150 → 0.065 | 4.6% → 4.1% |
| the 96 | band | Gemini 3.5 Flash-Lite | 9 | 84.9 | 86.6 | 86.6 | 86.6 | 84.9 | 1 / 3 | 0.105 → 0.094 | 5.2% → 5.1% |
| the 96 | band | LightOnOCR-3 4B (Mac) | 16 | 83.4 | 90.9 | 90.9 | 90.9 | 84.7 | 1 / 5 | 0.113 → 0.072 | 6.5% → 3.1% |
| the 96 | band | Qwen3-VL 8B | 16 | 84.7 | 87.2 | 87.3 | 87.2 | 84.6 | 1 / 6 | 0.114 → 0.096 | 6.5% → 6.1% |
| the 96 | easy | all routes | 40 | 99.2 | 99.5 | 99.5 | 99.5 | 99.2 | 4 / 11 | 0.005 → 0.003 | 0.2% → 0.1% |
| public 895 | band | all routes | 120 | 81.4 | 83.8 | 83.7 | 85.0 | 81.4 | 12 / 47 | 0.153 → 0.133 | 3.5% → 2.9% |
| public 895 | band | GLM-OCR | 40 | 81.2 | 84.4 | 84.1 | 88.0 | 81.3 | 2 / 17 | 0.159 → 0.131 | 3.1% → 2.3% |
| public 895 | band | LightOnOCR-3 4B | 40 | 80.9 | 82.8 | 82.8 | 82.8 | 80.7 | 8 / 13 | 0.156 → 0.141 | 3.4% → 2.9% |
| public 895 | band | Qwen3-VL 8B | 40 | 82.3 | 84.2 | 84.2 | 84.2 | 82.2 | 2 / 17 | 0.143 → 0.129 | 4.0% → 3.4% |

Mean gain in NES points, 95% bootstrap interval (cap-guarded; paired on the same reading):

| | Image arm | Text arm | Image − text | Direct 27B reading | Image arm − direct |
|---|---|---|---|---|---|
| the 96, band (57) | +5.82 [+3.26, +7.99] | +1.60 [+0.70, +2.69] | +4.22 [+1.73, +6.14] | +6.23 [+3.64, +8.49] | −0.42 [−1.47, +0.64] |
| the 96, easy (40) | +0.33 [+0.17, +0.50] | +0.01 [−0.11, +0.12] | +0.32 [+0.15, +0.52] | −0.21 [−1.15, +0.36] | +0.54 [+0.03, +1.44] |
| public, band (120) | +3.56 [+2.86, +4.29] | −0.04 [−0.19, +0.12] | +3.60 [+2.88, +4.35] | +2.08 [+0.70, +3.31] | +1.47 [+0.55, +2.63] |

Public band, image arm cap-guarded by stratum: L1 +3.32 [+2.14, +4.52] (39), L2 +3.10 [+2.19, +4.12] (39), L4 +4.22
[+2.71, +5.97] (36), L6 +4.04 [+0.91, +7.76] (6). The text arm is within ±0.13 of zero in every stratum.

## What it shows

1. **Image-grounded correction pays in the band; text-only does not.** With the image the 27B lifts the 96's band
   readings 5.8 points and the public band 3.6 (cap-guarded), worsening 4 of 57 and 10 of 120. Text only, it gains 1.6
   on the 96 and nothing on the public pages, where it worsens 47 of 120. This is the literature's split (C claims
   31-32, 35), now on our pages.
2. **But on the 96 it is no better than reading the page again.** The same 27B reading from scratch scores within
   half a point of the corrected text (−0.42 [−1.47, +0.64]) and both cost one 27B call with the image; the
   correction prompt only adds the reading (median 4,232 prompt tokens with the image, 320 without it). For the owner's
   material the band is better served by the cascade's existing escalation than by a new stage. On the public band,
   correction beats the direct reading by 1.5 points [+0.55, +2.63]: on hands, registers and Kurrent the cheap reading
   carries information the 27B does not recover alone. By reader the margin is widest for LightOnOCR-3 4B (82.8
   against 80.0) and Qwen3-VL 8B (84.2 against 82.9) and nil for GLM-OCR (88.0 against 87.7).
3. **The abstention check passes on harm, not on the letter.** On the easy pages the image arm changes words in 65%
   of the readings, so it does not "change nothing"; but the changes are fixes (+0.33 [+0.17, +0.50]), 4 of 40 are
   worse and the worst loses 0.81 points. The text arm changes 52%, gains nothing and worsens 11. A stage run on
   every page would not damage clean readings, so routing by band is about cost, not safety.
4. **Alignment trimming does nothing here; the cap guard does the work.** Thinking off, the 27B writes no preamble
   or trailing note, so trimming cuts only 36 replies and lowers the mean slightly (it drops edge words the corrector
   restored). The two failures it was meant for are loops: both GLM-OCR L2 images (Washington Papers) hit the cap and fell to NES 0.03 and
   0.02, which trimming lifts only to 0.07 and 0.14 because the loop starts inside the page. Keeping the reading on a
   cap turns the public band from +2.4 into +3.6.
5. **The one large loss is added text.** Apple Vision p025 went from 85.9 to 45.6: the corrector transcribed a
   different letter visible in the photograph (80 added words), which neither the reading nor the truth contains. A
   length-ratio guard (claim 27's 0.35-2.8×) would not catch its 2.1×.
6. **Cheap readers gain unevenly.** Apple Vision gains most (+9.8 on the 96), then LightOnOCR-3 4B (+7.5); Qwen3-VL
   8B (+2.5) and Gemini Flash-Lite (+1.7) gain least.

## For the cascade (R8)

- No correction stage for the owner's material: escalating a band page to the 27B reader does as well.
- Where a stage is used (hands, registers, Kurrent on the 895's evidence): image-grounded only, a cap is a failure
  and keeps the reading, trimming optional. Never text-only.
- Limits: one corrector; the 96's band is 57 readings over at most 16 pages a route; the 96's direct reading is the
  local panel's provider run, not the Sherlock FP8 build; the public band caps 40 a route and L6 has 6 pages. The
  Gemini corrector arm is W46.ocr-postcorrect-paid.
