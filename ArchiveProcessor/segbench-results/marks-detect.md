# Marks detection on the owner core (W46.marks-detect)

Truth: 32 detector-eligible owner-core pages, 45 rough boxes (`marks_detect.py report`; every figure is in `marks-detect.json`). Recall, found/of with a 95% page bootstrap interval; matching is one to one and class-agnostic.

## Recall, loose hit, IoU >= 0.1

| Detector | All | A-core | B-core | Touching print | Clear of print | Boxes emitted | Precision |
|---|---|---|---|---|---|---:|---|
| PP-DocLayoutV3 Seal + Aside Text | 0/45 = 0% (0-0) | 0/6 = 0% (0-0) | 0/39 = 0% (0-0) | 0/18 = 0% (0-0) | 0/27 = 0% (0-0) | 1 | 0% |
| PP-DocLayoutV3, any region (coverage only) | 4/45 = 9% (2-17) | 1/6 = 17% (0-50) | 3/39 = 8% (0-14) | 2/18 = 11% (0-26) | 2/27 = 7% (0-22) | 403 | – |

## Recall, IoU >= 0.5, the filed rule

| Detector | All | A-core | B-core | Touching print | Clear of print | Boxes emitted | Precision |
|---|---|---|---|---|---|---:|---|
| PP-DocLayoutV3 Seal + Aside Text | 0/45 = 0% (0-0) | 0/6 = 0% (0-0) | 0/39 = 0% (0-0) | 0/18 = 0% (0-0) | 0/27 = 0% (0-0) | 1 | 0% |
| PP-DocLayoutV3, any region (coverage only) | 1/45 = 2% (0-5) | 0/6 = 0% (0-0) | 1/39 = 3% (0-6) | 1/18 = 6% (0-15) | 0/27 = 0% (0-0) | 403 | – |

## Truth support by class

| Class | Boxes | Touching print |
|---|---:|---:|
| annotation | 17 | 8 |
| marginal_note | 11 | 4 |
| other | 3 | 1 |
| signature_initials | 4 | 2 |
| stamp | 10 | 3 |

## What this says

PP-DocLayoutV3 does not find marks. Its Seal and Aside Text classes emitted one box in 32 pages and matched none
of the 45 marks. Even counting every region it draws, at the loose rule only 4 of 45 marks fall under one, and those
are text regions that happen to overlap a mark. A layout-region route therefore drops nearly every mark: the marks
layer needs its own detector or a whole-page reader. The free recall check is closed, at no cost.

## Arms not run here

- **The tech4humans YOLOv8s signature detector.** Its Hugging Face repository is gated, and this Mac has no
  Hugging Face token. The core has 4 signature or initials boxes, so it could not be ranked on this truth even
  with access.
- **Qwen3.6-27B boxes.** The B-core was drawn from its pre-flag, so MRK-1 allows scoring it on the A-core only,
  which has 6 boxes. That interval would run from about 0 to 100, so the arm is not sent to Sherlock.
- **A YOLO11m trained on AnnoPage and SignverOD.** Prepared as a Sherlock pack (`sherlock/marks-detect/`, a
  ceiling of 6.5 GPU-hours), with its size review in `execution-plans/items/W46.marks-detect.md`. It is scored here
  when the results come home.
- **Claude inline tags.** Dropped (measurement audit MRK-1). Gemini's boxes and inline tags are
  W46.marks-detect-paid; Gemini 3.7 drafted every core page, so the item has to rule on whether 3.8 may be
  ranked on them.

## Measurement card

- **Truth.** The reconciled owner core (W46.fix-marks-sheet-feedback, record
  `marks-set-reconciled-da388b05c388-dac79c80c2f6`): owner keep/reject, class and touches-print on 32 pages. The
  boxes are rough draft boxes from Gemini 3.7 Flash and Qwen3-VL 8B that the owner kept, plus one owner box. They
  are not tight geometry, which is why the loose rule is reported beside IoU 0.5. Neither PP-DocLayoutV3 nor
  anything trained from it drafted or chose a page.
- **Selection.** The frozen two-phase selection: A-core (15 pages) independent of every route, B-core (17) drawn
  from Qwen3.6-27B's pre-flag bands. Reported apart and pooled descriptively, without population weights. Excluded
  pages (8) are not negatives.
- **Comparison.** One image per page (the freeze's 2,400 px copies), the detector's default settings (score floor
  0.5, 1,024 px), class-agnostic one-to-one matching.
- **Noise.** n = 45 boxes on 32 pages. Page bootstrap, 2,000 resamples, seed 46. With 45 boxes, a detector's pooled
  recall carries an interval of about ±14 points, so only large differences separate two detectors. No per-class
  ranking: no class has more than 17 boxes.
- **Scope.** Detection only. This does not cover whether found marks can be read (a transcription arm), whether a
  whole-page reader already transcribes them (W46.mixed-route), or precision on pages with no marks beyond the core's.
