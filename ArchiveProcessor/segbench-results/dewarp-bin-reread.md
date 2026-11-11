# W46.dewarp-bin-reread — the cached segbench-dewarp binary was not stale

W46.ocr-input-colour-dropout blamed the cached `segbench-dewarp` binary (built 2026-10-31, sha256 `b4ca2de5d19c98aa`,
kept as `segbench/bin/segbench-dewarp.built-20261031`) for reading less text on macOS 27.2 than `segbench-ocr`, and
replaced it with a rebuild from the same `dewarp.swift` (`8c0741beaa66c9b4`). That diagnosis was wrong. The same old
binary, run again on 2026-11-11 (macOS 27.2, 26B123), reads what the rebuild reads. The bad readings came from one run,
`ocr_colour_dropout.py vision` at 04:49-04:54 that morning: whole lines missing, mean NES 60.0 against 83.1 on the 96.
The colour-dropout figures were already taken from its second run (05:38) and do not change; only its note did.

## What was read again

Every `segbench-dewarp lines` reading made on 27.2 that is still in the bench cache, read again with the rebuild (and
the 96 with the old binary too), compared text for text (the lines joined by newlines):

| readings | made | read again with | identical | the rest |
|---|---|---|---|---|
| the owner's 96, raw (`colour-dropout/lines-dewarp-bin-20261031/raw`, the faulty run) | 2026-11-11 04:49 | old binary | 38 of 96 | 58 short, the fault |
| the owner's 96, raw | — | old binary against the rebuild | 93 of 96 | p048, p050, p053, handwritten |
| `enh-dewarp/lines/raw` (W46.vision-27-swap's 27.2 row, read by the old binary) | 2026-11-04 | rebuild | 95 of 96 | p048, handwritten |
| capture ladder, 16 arms × 96 (`capture-ladder/lines/*`) | 2026-11-03 | rebuild | 1,532 of 1,536 | p022, p046, p053 (handwritten), p041 motion-17 |
| place-geom-real5, 310 Real5-OmniDocBench photographs (`place-geom-real5/lines/raw`) | 2026-11-05 | rebuild | 308 of 310 | one page's warp and skew photo, 1 character each |

The capture ladder's p041 motion-17 also reads 919 characters with the old binary today, against 1,049 on
2026-11-03. The image is byte-identical to the pack manifest, so that change is run-to-run, not the binary. Not read
again: the ladder's `quad-tilt-12`, `quad-tilt-20` and `resave-q92` arms, whose images are no longer cached. They were
read in the same process as the 16 arms above (2026-11-03 20:05-20:14), which shows no fault. `date_undated.py`,
`enh_dewarp.py`, `enh_ocr_input.py` and `layout_photo.py` have no `segbench-dewarp` readings dated after 2026-11-03 in
the cache. `place_curved.py` uses its own build (`/tmp/pco-dewarp`), and `ct-read`/`ct-truth` use `segbench-ocr-lines`.
The place-geom-real5 photographs were fetched again from `PaddlePaddle/Real5-OmniDocBench` into `/tmp` and frozen by
`layout_photo.freeze`, as that item did. They were deleted afterwards.

**Nothing moved.** No report and no ArchiveOCRBench figure is regenerated. The 2026-11-04 swap's `enh-dewarp`
`lines/raw` came from the old binary and stands.

## The fault

The cause is not known. The faulty run used the same binary, images and settings as the good ones, ran under the heavy
lock, took the usual time (about 0.15 s a page), and its JSON is well formed. Lines are just missing (p004: 11 lines
against 27; p006: 4 against 8). The system log for its first minute shows nothing beyond the usual Vision start-up. One
run in about 3,400 readings checked here. A bench Vision result that looks low on 27.2 should be read twice before
anything is blamed.

## Measurement card

- **Truth.** None. This compares Vision readings with Vision readings of the same bytes, and scores nothing.
- **Selection.** Every `segbench-dewarp lines` reading in the bench cache dated after the 27.2 install (2026-10-30)
  whose image is still on disk or could be fetched again; nothing chosen by a route or by ABBYY text.
- **Comparison.** Same image bytes (the ladder's checked against its manifest), same tool source and settings
  (`.accurate`, language correction, en-US), same OS; only the binary build and the run differ.
- **Noise.** On 27.2 a few handwritten pages vary from run to run (W46.vision-27-reread: up to 3.7 NES on a page). Every
  difference here outside the fault is one of those pages, the one motion-blurred page, or a single character.
- **Scope.** It shows the old binary reads as the rebuild does. It does not explain the 04:49 fault, and it does not
  cover readings whose images are gone.
