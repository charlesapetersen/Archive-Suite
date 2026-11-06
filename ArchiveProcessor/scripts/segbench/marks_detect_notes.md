## What this says

PP-DocLayoutV3 does not find marks. Its Seal and Aside Text classes emitted one box in 32 pages and matched none
of the 45 marks. Even counting every region it draws, at the loose rule only 4 of 45 marks fall under one, and those
are text regions that happen to overlap a mark. A layout-region route therefore drops nearly every mark.

A YOLO11m trained on public data finds few of them either. Trained on Sherlock (one L40S) on AnnoPage's 416 pages
with a handwritten inscription or stamp box, as many pages without, and SignverOD's 2,299 forms, it scored mAP50
0.81 on its own validation split (handwritten 0.51, stamp 0.82, signature 0.96; 195 epochs in 2.2 hours, stopped
early, best at epoch 95). On our 32 pages, at Ultralytics' default floor of 0.25, it found 8 of 45 marks at the
loose rule (18%, interval 5-37) and 6 at IoU 0.5, with half its 15 boxes on a mark. Dropping the floor to 0.05
reaches 17 of 45 (38%, 21-60) at 42% precision. It found 1 of the 10 stamps even at 0.05, although stamps were its
second-best class on AnnoPage: the public stamps are library and ownership stamps, ours are receipt and file
stamps. Annotations went best (9 of 17 at 0.05). The one-epoch pilot found nothing, which says only that the
chain ran.

The trained model exports to Core ML on this Mac (Ultralytics 8.4.202, coremltools 9.0; an 80.6 MB fp32
`.mlpackage`, NMS left to Ultralytics because coremltools 9's NMS pipeline fails to convert on torch 2.15). On the
M3 Pro it takes a median 0.43 s a page, JPEG decode included, after a 1.1 s first page (an engine session's timing,
so an upper bound). Its boxes are not identical to the cluster's, since the export takes a square 1,024 px input
where PyTorch took the page's own shape: the same 8 of 45 at the default floor, but 2 rather than 1 on the A-core,
and 14 boxes rather than 15.

Reading the marks it finds is the other half (`marks-read.md`): on the owner's own boxes LightOnOCR-3 4B reads 17
of 35 marks at NES 0.8 and Apple Vision 13; through this detector's boxes, 6 at best.

So no detector measured here is a marks layer. Public training data does not transfer to these pages at a usable
recall. The comparison that decides the route is a whole-page reader (W46.mixed-route), which needs no detector;
a fine-tune on our own pages (W46.marks-detect-own) was to run only if whole-page readers missed marks, and was
retired on 2026-11-05: W46.mixed-route found no ranked reader's whole page behind the owner's box beyond noise.

## Arms not run here

- **The tech4humans YOLOv8s signature detector.** Its Hugging Face repository is gated, and this Mac has no
  Hugging Face token. The core has 4 signature or initials boxes, so it could not be ranked on this truth even
  with access.
- **Qwen3.6-27B boxes.** The B-core was drawn from its pre-flag, so MRK-1 allows scoring it on the A-core only,
  which has 6 boxes. That interval would run from about 0 to 100, so the arm is not sent to Sherlock.
- **Claude inline tags.** Dropped (measurement audit MRK-1). Gemini's boxes and inline tags are
  W46.marks-detect-paid; Gemini 3.7 drafted every core page, so the item has to rule on whether 3.8 may be
  ranked on them.

## Measurement card

- **Truth.** The reconciled owner core (W46.fix-marks-sheet-feedback, record
  `marks-set-reconciled-da388b05c388-dac79c80c2f6`): owner keep/reject, class and touches-print on 32 pages. The
  boxes are rough draft boxes from Gemini 3.7 Flash and Qwen3-VL 8B that the owner kept, plus one owner box. They
  are not tight geometry, which is why the loose rule is reported beside IoU 0.5. Neither PP-DocLayoutV3 nor
  the YOLO11m drafted or chose a page, and the YOLO11m was trained on public sets only (no page of ours).
- **Selection.** The frozen two-phase selection: A-core (15 pages) independent of every route, B-core (17) drawn
  from Qwen3.6-27B's pre-flag bands. Reported apart and pooled descriptively, without population weights. Excluded
  pages (8) are not negatives.
- **Comparison.** One image per page (the freeze's 2,400 px copies), class-agnostic one-to-one matching, each
  detector at its default settings: PP-DocLayoutV3 at score floor 0.5 and 1,024 px; the YOLO11m at 1,024 px and
  Ultralytics' floor 0.25, with the sweep beside it.
- **Noise.** n = 45 boxes on 20 of the 32 pages (12 pages carry none). Page bootstrap, 2,000 resamples, seed 46. With 45 boxes, a detector's pooled
  recall carries an interval of about ±14 points, so only large differences separate two detectors. No per-class
  ranking: no class has more than 17 boxes.
- **Scope.** Detection only. This does not cover whether found marks can be read (a transcription arm), whether a
  whole-page reader already transcribes them (W46.mixed-route), or precision on pages with no marks beyond the core's.
