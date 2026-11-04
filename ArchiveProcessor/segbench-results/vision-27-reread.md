# Apple Vision re-read on macOS 27.2 (W46.vision-27-reread)

Re-read on macOS 27.2 (26B123), arm64, with the same tools and settings as the dated readings (`ocr.swift`: `.accurate`, language correction on, en-US, the app's defaults; the capture ladder's `segbench-dewarp lines`). The dated readings were made on macOS 26.6 (installed 2026-08-06; 27.2 was installed 2026-10-30): the owner panel on 2026-10-14, the 440 reference set's Latin-script pages on 2026-10-17, the capture ladder's raw row on 2026-10-22. New readings sit beside the old, which are kept: `ocr-panel-local/vision-27.2/`, `bench-corpus/routes/vision-27.2/`, `enh-dewarp/lines/raw-27.2/` under `~/Library/Caches/ArchiveSuiteRehearsal`. Δ is after minus before, in points, paired by page.

## Verdict

**The update moved Vision.** On the owner's 96 scored originals NES goes 81.4 → 83.1, +1.7 (-0.3 to +4.0), with 95 of 96 texts changed; on the 440's 320 Latin-script pages 37.5 → 39.3, +1.8 (+0.6 to +3.1), 320 changed. On the 96 the NES change does not clear zero but bag-of-words F1 does (+1.4 (+0.6 to +2.2)); the panel's downscaled copies went the other way (half -6.2 (-11.5 to -1.9), quarter -2.3 (-6.1 to +1.3) NES), and on the 440 one stratum fell (L7 -2.0 (-4.1 to -0.0)). The texts changed on nearly every page, so every Vision figure read before 2026-10-30 is a macOS 26.6 figure and is labelled so.
The capture ladder's re-save sentence compared a 26.6 raw reading with a 27.2 re-save. Measured on one OS, the re-encode alone moves bowF1 +0.3 (-0.3 to +0.9) and NES -0.0 (-0.6 to +0.5) on 96 pages; the update alone on the raw file moves bowF1 +1.2 (+0.3 to +2.1) (1 of 96 raw texts identical).

## The owner's 96 (139 images)

| set | n | text identical | NES before → after | ΔNES (95% CI) | Δ bowF1 (95% CI) | pages moved ≥5 NES |
|---|---|---|---|---|---|---|
| all half | 20 | 0 | 79.5 → 73.2 | -6.2 (-11.5 to -1.9) | -1.9 (-5.4 to +1.5) | 9 |
| all original | 99 | 1 | 80.0 → 81.5 | +1.6 (-0.3 to +3.8) | +1.3 (+0.5 to +2.1) | 19 |
| all quarter | 20 | 0 | 52.7 → 50.4 | -2.3 (-6.1 to +1.3) | +0.5 (-3.0 to +4.2) | 7 |
| original · handwritten | 19 | 0 | 54.4 → 56.1 | +1.7 (-0.9 to +4.7) | +0.4 (-2.0 to +2.7) | 4 |
| original · mixed | 2 | 0 | 73.2 → 70.8 | -2.4 | -3.3 | 0 |
| original · printed | 28 | 1 | 76.4 → 80.5 | +4.1 (-2.3 to +11.4) | +0.8 (-0.3 to +2.1) | 10 |
| original · scored | 96 | 1 | 81.4 → 83.1 | +1.7 (-0.3 to +4.0) | +1.4 (+0.6 to +2.2) | 19 |
| original · typewritten | 50 | 0 | 91.9 → 92.2 | +0.3 (-0.6 to +1.2) | +2.1 (+1.1 to +3.2) | 5 |
| half · mixed | 1 | 0 | 56.5 → 44.7 | -11.8 | -2.4 | 1 |
| half · printed | 5 | 0 | 59.9 → 57.9 | -2.1 | +1.7 | 2 |
| half · typewritten | 14 | 0 | 88.1 → 80.8 | -7.3 (-14.3 to -1.4) | -3.1 (-7.8 to +1.4) | 6 |
| quarter · mixed | 1 | 0 | 56.2 → 55.4 | -0.8 | -2.0 | 0 |
| quarter · printed | 5 | 0 | 39.1 → 31.2 | -7.9 | +0.9 | 2 |
| quarter · typewritten | 14 | 0 | 57.3 → 56.9 | -0.4 (-4.0 to +3.2) | +0.6 (-3.8 to +5.1) | 5 |

"original · scored" is the panel's headline set (the three agreement pages out). The half and quarter rows are the panel's downscaled copies of the same pages.

## The 440 reference set, Latin-script pages (Vision reads only these)

| stratum | n | text identical | NES before → after | ΔNES (95% CI) | Δ bowF1 (95% CI) | pages moved ≥5 NES |
|---|---|---|---|---|---|---|
| all | 320 | 0 | 37.5 → 39.3 | +1.8 (+0.6 to +3.1) | +1.9 (+1.3 to +2.5) | 134 |
| L5 | 80 | 0 | 38.4 → 41.1 | +2.7 (-0.3 to +5.8) | +3.8 (+2.3 to +5.3) | 39 |
| L6 | 80 | 0 | 22.4 → 26.5 | +4.1 (+1.0 to +7.2) | +0.3 (-0.2 to +0.8) | 51 |
| L7 | 80 | 0 | 16.3 → 14.3 | -2.0 (-4.1 to -0.0) | -0.6 (-2.0 to +0.6) | 28 |
| L8 | 80 | 0 | 72.8 → 75.3 | +2.6 (+1.9 to +3.2) | +4.2 (+3.1 to +5.2) | 16 |

## The capture ladder's re-save baseline

| comparison | set | n | Δ bowF1 (95% CI) | ΔNES (95% CI) |
|---|---|---|---|---|
| reported (resave 27.2 - raw 26.6) | all | 96 | +1.5 (+0.6 to +2.4) | +1.6 (-0.4 to +3.9) |
| update alone (raw 27.2 - raw 26.6) | all | 96 | +1.2 (+0.3 to +2.1) | +1.6 (-0.3 to +4.0) |
| re-encode alone (resave 27.2 - raw 27.2) | all | 96 | +0.3 (-0.3 to +0.9) | -0.0 (-0.6 to +0.5) |
| reported (resave 27.2 - raw 26.6) | pdf image | 33 | +2.3 (+0.9 to +3.8) | +4.6 (+0.1 to +10.6) |
| update alone (raw 27.2 - raw 26.6) | pdf image | 33 | +2.0 (+0.8 to +3.5) | +4.4 (-0.1 to +10.4) |
| re-encode alone (resave 27.2 - raw 27.2) | pdf image | 33 | +0.3 (+0.0 to +0.5) | +0.2 (-0.3 to +0.7) |

## Which reports carry a macOS 26.6 Vision figure

Every script that reads one of the three dated caches (`ocr-panel-local/vision`, `bench-corpus/routes/vision`, `enh-dewarp/lines/raw`) reports 26.6 Vision text, as committed on 2026-11-04. Vision's own score: `ocr-panel-local.md` (ocr_panel_score.py), `ocr-scorers.md` and `ocr-pages.csv` (ocr_rescore.py, ocr_pages_export.py; the bench page's Vision rows and its cascade and agreement tables), `bench-corpus/routes.csv` (corpus/routes.py), `enh-dewarp.md`'s raw row, `capture-ladder.md`'s raw row and its re-save sentence (above: the update, not the re-save), `truth-jpeg-upgrade.md`, `ocr-ppocrv6-hands.md`'s Vision rows, and the Vision column of `r1-foundation.md` (in flight). Vision text as an input to another route: `layout-order.md` and `place-geom.md`. The capture ladder's defect and re-save rows, and `capture-ladder-paid`, were read on 27.2. The bench page says so in its footer; the charts keep the 26.6 readings until the dated caches are swapped for these and the reports above regenerated together (W46.vision-27-swap), so that no table pairs a 27.2 Vision with a 26.6 one.


## Measurement card

- **Truth.** Unchanged and the same files the dated scores used: the owner panel's adjudicated truth (`ocr_truth` cache, owner-checked pages as recorded there) and the 440's frozen public truths. No model drafted anything here; this item compares Vision with itself.
- **Selection.** Every image the dated readings covered: all 139 panel jobs, all 320 Latin-script pages of the 440 (Vision's script filter, unchanged), the capture ladder's scored pages (the panel's originals less the three agreement pages). Nothing chosen by a route or by ABBYY text.
- **Comparison.** Same images byte for byte, same tool source and settings, same scorer (`ocr_panel_score.score`, the 440's per-stratum options) and truth; only the OS differs. The `segbench-ocr` (2026-11-03) and `segbench-dewarp` (2026-10-31) binaries were rebuilt on 27.2 from unchanged sources, so "the update" here is the OS together with the SDK the tools link against, which is what any build on this Mac now gets; the request revision is the SDK default in both runs.
- **Noise.** Read twice on 27.2, 30 of 30 texts (15 panel images, 15 public pages) came back byte-identical, so Vision is deterministic on one OS and any change here is the update. Intervals are paired bootstrap 95% over pages (10,000 resamples, `ocr_panel_score.paired`); none is given under ten pages.
- **Scope.** Apple Vision text only, on these images. It does not re-read the capture ladder's defect rows (all read on 27.2 on 2026-11-03, and paired against the same-run re-save, so their deltas stand), nor the Processor's own Vision path in the app.
