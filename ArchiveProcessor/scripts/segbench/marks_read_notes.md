## What this says

Marks that are found can mostly not be read well enough yet, even with a perfect box. On the owner's own boxes
LightOnOCR-3 4B, the laptop handwriting pick, reads 17 of 35 marks at NES 0.8 or better (mean NES 0.62), and Apple
Vision 13 (0.59). The two fail differently: LightOnOCR answers nothing on 8 crops, all short marks of 4 to 11
characters, where Vision answers on 6 but reads only one of them well; on long boxes it can run on into the print
around the mark. Using Vision only where LightOnOCR answers nothing reaches 18 of 35 (mean 0.70); that rule was
chosen after seeing these results, so it is a hypothesis to test on new pages, not a ranked route. Stamps read best
(6 of 9 for both readers); marginal notes split the readers (LightOnOCR 5 of 10, Vision 1 of 10).

Through the trained detector the chain is weak because detection is. At its default floor the YOLO11m boxes 6 of
the 35 marks and 4 are read (LightOnOCR); at a floor of 0.05 it boxes 13 and 6 are read. A Mac-local marks layer
built from this detector and these readers would carry about one mark in six, so the route question goes to a
whole-page reader (W46.mixed-route) and to a detector trained on our own pages.

## Measurement card

- **Truth.** The 35 mark texts the owner reviewed on the 32 detector-eligible core pages (reconciled record
  `marks-set-reconciled-da388b05c388-dac79c80c2f6`, `transcription_status` owner_reviewed). The texts were drafted
  by Gemini 3.7 Flash and Qwen3-VL 8B and kept or corrected by the owner; neither reader scored here drafted them.
- **Selection.** Every owner-reviewed text on the eligible pages; none chosen by a reader. The boxes are the owner's
  kept rough draft boxes (oracle) or the YOLO11m's, which never saw these pages in training.
- **Comparison.** The same crop file for both readers (1% padding, enlarged to 768 px where smaller). Vision at the
  app's settings; LightOnOCR with its card's empty prompt, temperature 0, 512 tokens (no reply reached it).
- **Noise.** n = 35 marks on 17 pages; page bootstrap, 2,000 resamples, seed 46. The intervals are about ±20
  points, so the two readers tie on the oracle boxes; only the gap between oracle and detector boxes is clear.
  No rerun floor. Vision's determinism is measured: two runs on these pages gave identical text (measurement review
  pass 10). LightOnOCR's at temperature 0 is asserted, not measured.
- **Scope.** Reading crops, not marks in a page reading. The rough truth boxes include neighbouring print on some
  marks (one RG165 box contains three others), which costs both readers alike. Not settled: whether a whole-page
  reader transcribes the marks (W46.mixed-route), and Gemini on the crops, which is not
  measured (W46.marks-detect-paid was retired unrun by the owner on 2026-11-05).
