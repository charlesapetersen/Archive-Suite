# Apple Vision language detection (W49.proc-vision-language-auto, 2026-11-21)

Paired before-and-after comparison of Processor's Apple Vision reader on macOS 27.2.1
(Vision text recognition revision 3). A blank **Languages** field enables detection. The
existing English default and entered language tags continue to select those languages.

| Pages | n | English NES | Auto-detect NES | Δ (95% interval) | Answered English / Auto | Median seconds English / Auto |
|---|---:|---:|---:|---:|---:|---:|
| Owner 96 | 96 | 81.32% | 81.99% | +0.67 (-0.03 to +1.99) | 96 / 96 | 0.17 / 0.19 |
| Public non-English | 562 | 26.58% | 38.91% | +12.32 (+10.18 to +14.58) | 535 / 540 | 0.14 / 0.15 |
| Owner non-English | 2 | 91.64% | 91.64% | +0.00 (+0.00 to +0.00) | 2 / 2 | 0.29 / 0.30 |
| L3 | 2 | 88.71% | 88.71% | +0.00 (+0.00 to +0.00) | 2 / 2 | 0.13 / 0.14 |
| L5 | 80 | 41.07% | 41.86% | +0.78 (-0.49 to +2.81) | 80 / 80 | 0.20 / 0.24 |
| L6 | 80 | 26.51% | 25.54% | -0.97 (-1.92 to -0.23) | 80 / 80 | 0.15 / 0.16 |
| L7 | 80 | 14.31% | 13.78% | -0.53 (-1.02 to -0.07) | 65 / 65 | 0.10 / 0.11 |
| L8 | 80 | 75.34% | 75.28% | -0.07 (-0.14 to +0.01) | 80 / 80 | 0.13 / 0.14 |
| N1 | 40 | 8.23% | 71.61% | +63.39 (+57.80 to +68.33) | 40 / 40 | 0.14 / 0.16 |
| N2 | 40 | 20.09% | 19.14% | -0.94 (-1.51 to -0.46) | 40 / 40 | 0.13 / 0.15 |
| N3 | 40 | 11.10% | 10.67% | -0.43 (-2.13 to +1.37) | 37 / 39 | 0.09 / 0.10 |
| N4 | 40 | 1.18% | 1.47% | +0.30 (+0.12 to +0.49) | 33 / 35 | 0.16 / 0.17 |
| N5 | 40 | 6.95% | 61.24% | +54.29 (+44.22 to +64.00) | 38 / 39 | 0.14 / 0.45 |
| N6 | 40 | 7.06% | 65.19% | +58.13 (+54.68 to +61.37) | 40 / 40 | 0.13 / 0.13 |

NES is normalized edit similarity to the reference transcription, expressed as a percentage.
A missing or empty reading gets zero. Time is the median per page from a serial local run.
Both readings cost $0.

The public gain came mostly from Arabic manuscripts (+63.39 points), Chinese print
(+54.29), and Devanagari print (+58.13). German Kurrent and the Cyrillic set each
lost about one point. The two owner pages screened as likely non-English tied.
The interval across all 96 owner pages includes zero.

## Measurement card

- **Truth.** The owner's frozen 96 reference transcriptions were drafted by Claude Opus 5.5
  and Gemini 3.8 Flash, adjudicated by the owner where they differed, and subsequently sampled
  blind for shared errors. See [the truth record](ocr-truth.md). Public references are the
  existing source transcriptions in the [895-page frozen manifest](bench-corpus/manifest.jsonl),
  SHA-256 `27673d67e648a1864f16515ed6d73bf9a0b35a4895e8821455ea36c17f4236eb`.
  Each source preserves its own conventions for margins, historic spelling and diacritics.
- **Selection.** Run all 96 owner pages as a control. Screen their reference text with
  Apple's Natural Language language recognizer, after removing the literal `[illegible]`
  marker. The top label must have confidence at least 0.80 to enter the subset. Labels
  at that threshold were one German, 87 English and one Dutch, with seven below it.
  The two non-English labels are provisional. The original owner draw replaced 19 pages where Vision read fewer than 20 words, so the 96 favour pages
  Vision can already read. From the public set, take the two French TAPUS pages in L3,
  all pages in L5–L8, and all pages in N1–N6, 562 in all. Selection uses the frozen
  source strata.
- **Comparison.** Compile the app's `OCR/VisionClient.swift` with its queue and quality
  rule into a command-line host and run with the old explicit `en-US` list and the new
  empty list. Both arms use accurate recognition, language correction, minimum confidence
  0, and no custom vocabulary. Alternate which arm runs first. Use the effective owner
  JPEGs in `ocr-truth/pages`, including the 15 JPEG-original upgrades. For public images,
  use `corpus/routes.py`'s frozen checksum join and its 2,400-pixel, quality-90 JPEG
  preparation. Compare with the stratum-specific `ocr_panel_score.py` scorer.
- **Noise.** 10,000 page-paired bootstrap draws with seed 0. Rerun the first two pages
  of each measured stratum and of the owner set, reversing arm order, for
  24 pages per arm. Maximum same-arm rerun differences in NES points
  were 0.00 for both settings. The existing 96-page rerun floor is 0.49 points.
  Intervals resample pages individually, including where a single collection contributed several pages.
- **Scope.** The figures cover accurate-mode transcription of one whole page at a time. Apple Vision
  revision 3 on this Mac lists Arabic, Russian, Chinese and Hindi among its supported
  languages. Greek and Hebrew fall outside the revision 3 language list. The owner subset is a small
  exploratory check, and the public figures apply to these frozen source strata.
