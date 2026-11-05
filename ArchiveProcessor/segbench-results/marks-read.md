# Whether found marks can be read (W46.marks-detect, transcription arm)

35 owner-reviewed mark texts on the 32 detector-eligible core pages, each read from a crop (`marks_read.py`; figures in `marks-read.json`). NES is 1 - edit distance / longer length, case kept; *read* is NES >= 0.8. A detector arm reads the YOLO11m box matched to the mark at IoU >= 0.1; a mark without one reads as nothing. Intervals: 95% page bootstrap.

| Reader | Box | Marks with a box | Mean NES | Read |
|---|---|---:|---|---|
| Apple Vision (the app's settings) | the owner's box (oracle) | 35 of 35 | 0.59 (0.50-0.73) | 13 of 35 (22-58%) |
| Apple Vision (the app's settings) | YOLO11m box, floor 0.25 | 6 of 35 | 0.12 (0.02-0.27) | 2 of 35 (0-16%) |
| Apple Vision (the app's settings) | YOLO11m box, floor 0.05 | 13 of 35 | 0.23 (0.11-0.42) | 5 of 35 (4-32%) |
| LightOnOCR-3 4B 8-bit (mlx-vlm) | the owner's box (oracle) | 35 of 35 | 0.62 (0.47-0.82) | 17 of 35 (30-74%) |
| LightOnOCR-3 4B 8-bit (mlx-vlm) | YOLO11m box, floor 0.25 | 6 of 35 | 0.15 (0.02-0.34) | 4 of 35 (0-29%) |
| LightOnOCR-3 4B 8-bit (mlx-vlm) | YOLO11m box, floor 0.05 | 13 of 35 | 0.25 (0.11-0.48) | 6 of 35 (4-39%) |
| LightOnOCR-3 4B, Vision where it answers nothing (post hoc) | the owner's box (oracle) | 35 of 35 | 0.70 (0.55-0.89) | 18 of 35 (32-77%) |
| LightOnOCR-3 4B, Vision where it answers nothing (post hoc) | YOLO11m box, floor 0.25 | 6 of 35 | 0.15 (0.02-0.34) | 4 of 35 (0-29%) |
| LightOnOCR-3 4B, Vision where it answers nothing (post hoc) | YOLO11m box, floor 0.05 | 13 of 35 | 0.27 (0.13-0.50) | 7 of 35 (6-43%) |

Read on the oracle box, by class:

| Reader | annotation | marginal_note | other | stamp |
|---|---:|---:|---:|---:|
| Apple Vision (the app's settings) | 4 of 14 | 1 of 10 | 2 of 2 | 6 of 9 |
| LightOnOCR-3 4B 8-bit (mlx-vlm) | 4 of 14 | 5 of 10 | 2 of 2 | 6 of 9 |
| LightOnOCR-3 4B, Vision where it answers nothing (post hoc) | 4 of 14 | 5 of 10 | 2 of 2 | 7 of 9 |

48 crops; LightOnOCR-3 4B took a median 1.1 s a crop on the M3 Pro (an engine session's timing, so an upper bound).

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
  No rerun floor: both readers are deterministic at these settings.
- **Scope.** Reading crops, not marks in a page reading. The rough truth boxes include neighbouring print on some
  marks (one RG165 box contains three others), which costs both readers alike. Not settled: whether a whole-page
  reader transcribes the marks (W46.mixed-route), and Gemini on the crops (W46.marks-detect-paid).
