# Apple Vision re-read on macOS 27.2 (W46.vision-27-reread)

Re-read on macOS 27.2 (26B123), arm64, with the same tools and settings as the dated readings (`ocr.swift`: `.accurate`, language correction on, en-US, the app's defaults; the capture ladder's `segbench-dewarp lines`). The dated readings were made on macOS 26.6 (installed 2026-08-06; 27.2 was installed 2026-10-30): the owner panel on 2026-10-14, the 440 reference set's Latin-script pages on 2026-10-17, the capture ladder's raw row on 2026-10-22. New readings sit beside the old, which are kept: `ocr-panel-local/vision-27.2/`, `bench-corpus/routes/vision-27.2/`, `enh-dewarp/lines/raw-27.2/` under `~/Library/Caches/ArchiveSuiteRehearsal`. Δ is after minus before, in points, paired by page.

**Swapped in (W46.vision-27-swap, regenerated 2026-11-04).** The 27.2 readings are now the bench's Vision route: each dated folder moved aside as `*-26.6` (kept, nothing deleted) and a copy of its `*-27.2` sibling put in its place. `raw-27.2` held 96 files to the dated `raw`'s 99, since `read` skipped the three agreement pages the ladder does not score; `fill` read those on 27.2, so both hold 99. This regeneration adds the answered column, the empty-page finding, the two-tool repeat on the handwritten originals and the list below; no figure of the first report moved.

## Verdict

**The update moved Vision.** On the owner's 96 scored originals NES goes 81.4 → 83.1, +1.7 (-0.3 to +4.0), with 95 of 96 texts changed; on the 440's 320 Latin-script pages 37.5 → 39.3, +1.8 (+0.6 to +3.1), 320 changed. On the 96 the NES change does not clear zero but bag-of-words F1 does (+1.4 (+0.6 to +2.2)); the panel's downscaled copies went the other way (half -6.2 (-11.5 to -1.9), quarter -2.3 (-6.1 to +1.3) NES), and on the 440 one stratum fell (L7 -2.0 (-4.1 to -0.0)). The texts changed on nearly every page, so every Vision figure read before 2026-10-30 is a macOS 26.6 figure and is labelled so. **On 27.2 Vision returns nothing on 15 of the 80 L7 pages** it answered on 26.6 (answered 80 → 65), and those pages are all of L7's fall: they contribute -2.9 of its -2.0, and the other pages average +1.1. With the swap the public Vision row answers 305 of 320 pages, not 318; Vision is the second reader of the bench's suspect columns, so on those pages every word another route reads is suspect. Pages that changed from answered to empty or back: panel all quarter: 1 lost; public L6: 0 lost, 2 gained; public L7: 15 lost.
The capture ladder's re-save sentence compared a 26.6 raw reading with a 27.2 re-save. Measured on one OS, the re-encode alone moves bowF1 +0.3 (-0.3 to +0.9) and NES -0.0 (-0.6 to +0.5) on 96 pages; the update alone on the raw file moves bowF1 +1.2 (+0.3 to +2.1) (1 of 96 raw texts identical).

## The owner's 96 (139 images)

| set | n | text identical | answered before → after | NES before → after | ΔNES (95% CI) | Δ bowF1 (95% CI) | pages moved ≥5 NES |
|---|---|---|---|---|---|---|---|
| all half | 20 | 0 | 20 → 20 | 79.5 → 73.2 | -6.2 (-11.5 to -1.9) | -1.9 (-5.4 to +1.5) | 9 |
| all original | 99 | 1 | 99 → 99 | 80.0 → 81.5 | +1.6 (-0.3 to +3.8) | +1.3 (+0.5 to +2.1) | 19 |
| all quarter | 20 | 0 | 20 → 19 | 52.7 → 50.4 | -2.3 (-6.1 to +1.3) | +0.5 (-3.0 to +4.2) | 7 |
| original · handwritten | 19 | 0 | 19 → 19 | 54.4 → 56.1 | +1.7 (-0.9 to +4.7) | +0.4 (-2.0 to +2.7) | 4 |
| original · mixed | 2 | 0 | 2 → 2 | 73.2 → 70.8 | -2.4 | -3.3 | 0 |
| original · printed | 28 | 1 | 28 → 28 | 76.4 → 80.5 | +4.1 (-2.3 to +11.4) | +0.8 (-0.3 to +2.1) | 10 |
| original · scored | 96 | 1 | 96 → 96 | 81.4 → 83.1 | +1.7 (-0.3 to +4.0) | +1.4 (+0.6 to +2.2) | 19 |
| original · typewritten | 50 | 0 | 50 → 50 | 91.9 → 92.2 | +0.3 (-0.6 to +1.2) | +2.1 (+1.1 to +3.2) | 5 |
| half · mixed | 1 | 0 | 1 → 1 | 56.5 → 44.7 | -11.8 | -2.4 | 1 |
| half · printed | 5 | 0 | 5 → 5 | 59.9 → 57.9 | -2.1 | +1.7 | 2 |
| half · typewritten | 14 | 0 | 14 → 14 | 88.1 → 80.8 | -7.3 (-14.3 to -1.4) | -3.1 (-7.8 to +1.4) | 6 |
| quarter · mixed | 1 | 0 | 1 → 1 | 56.2 → 55.4 | -0.8 | -2.0 | 0 |
| quarter · printed | 5 | 0 | 5 → 5 | 39.1 → 31.2 | -7.9 | +0.9 | 2 |
| quarter · typewritten | 14 | 0 | 14 → 13 | 57.3 → 56.9 | -0.4 (-4.0 to +3.2) | +0.6 (-3.8 to +5.1) | 5 |

"original · scored" is the panel's headline set (the three agreement pages out). The half and quarter rows are the panel's downscaled copies of the same pages. Answered: a non-empty text.

## The 440 reference set, Latin-script pages (Vision reads only these)

| stratum | n | text identical | answered before → after | NES before → after | ΔNES (95% CI) | Δ bowF1 (95% CI) | pages moved ≥5 NES |
|---|---|---|---|---|---|---|---|
| all | 320 | 0 | 318 → 305 | 37.5 → 39.3 | +1.8 (+0.6 to +3.1) | +1.9 (+1.3 to +2.5) | 134 |
| L5 | 80 | 0 | 80 → 80 | 38.4 → 41.1 | +2.7 (-0.3 to +5.8) | +3.8 (+2.3 to +5.3) | 39 |
| L6 | 80 | 0 | 78 → 80 | 22.4 → 26.5 | +4.1 (+1.0 to +7.2) | +0.3 (-0.2 to +0.8) | 51 |
| L7 | 80 | 0 | 80 → 65 | 16.3 → 14.3 | -2.0 (-4.1 to -0.0) | -0.6 (-2.0 to +0.6) | 28 |
| L8 | 80 | 0 | 80 → 80 | 72.8 → 75.3 | +2.6 (+1.9 to +3.2) | +4.2 (+3.1 to +5.2) | 16 |

## The capture ladder's re-save baseline

| comparison | set | n | Δ bowF1 (95% CI) | ΔNES (95% CI) |
|---|---|---|---|---|
| reported (resave 27.2 - raw 26.6) | all | 96 | +1.5 (+0.6 to +2.4) | +1.6 (-0.4 to +3.9) |
| update alone (raw 27.2 - raw 26.6) | all | 96 | +1.2 (+0.3 to +2.1) | +1.6 (-0.3 to +4.0) |
| re-encode alone (resave 27.2 - raw 27.2) | all | 96 | +0.3 (-0.3 to +0.9) | -0.0 (-0.6 to +0.5) |
| reported (resave 27.2 - raw 26.6) | pdf image | 33 | +2.3 (+0.9 to +3.8) | +4.6 (+0.1 to +10.6) |
| update alone (raw 27.2 - raw 26.6) | pdf image | 33 | +2.0 (+0.8 to +3.5) | +4.4 (-0.1 to +10.4) |
| re-encode alone (resave 27.2 - raw 27.2) | pdf image | 33 | +0.3 (+0.0 to +0.5) | +0.2 (-0.3 to +0.7) |

## Which reports carry which Vision

As of the swap (2026-11-04). **Now macOS 27.2, regenerated together:** `ocr-panel-local.md` (ocr_panel_score.py), `ocr-scorers.md`, `ocr-pages.csv` and `ocr-pages-agree.csv` (ocr_rescore.py, ocr_pages_export.py; the bench page's Vision rows and its cascade and agreement tables), `bench-corpus/routes.csv` (corpus/routes.py), every row of `capture-ladder.md`, the apple-vision row of `ocr-hands-rescore.md`, every Vision text in `ocr-ppocrv6-hands.md`, and the bench page. Already 27.2 before the swap: `r1-foundation.md` (complete; `r1-foundation.json` byte-identical after the swap), the capture ladder's defect and re-save rows and `capture-ladder-paid`, the hands panel's line boxes and `apple-vision (lines)`, and the layout-photo document route (read 2026-10-30 20:00 UTC).

**Still macOS 26.6, labelled so and pinned to the `*-26.6` folders until every arm is re-read on one OS:** `enh-dewarp.md` (all 16 arms, its raw row included: on 27.2 the two tools no longer agree byte for byte, so its guard reads the 26.6 pair), `enh-ocr-input.md` (every arm, and its suspect counts) and `truth-jpeg-upgrade.md` (both sides; with one side swapped Vision's JPEG-minus-PDF change would read -7.0 for -4.2). The bench page labels their Vision routes 26.6.

**Kept on their own dated inputs, never re-read** (a re-read would change a request a cached model reply is keyed on, so every cached reply would become a paid re-call, or the input belongs to another item): `ent-robust.md` (reads the `vision-26.6` folders), `ocr-postcorrect.md`, `date-traceable.md` (read 2026-10-30 16:33-16:45 UTC, before the 19:06 install), `date-image.md`, `chaos-probe.md`, the `vision-words.json` of 2026-10-14 behind the placement truth, and the segmentation Vision text cache (data.py's: Dean, Deaver, Herrnstein, RG165 and Stanton 2026-10-05 on 26.6; Sasha, SC0122, the Illustrated Review and the checkpack boxes 2026-11-01 on 27.2), which `seg_window_gateway.py` hashes into every request; `r1-foundation.md`'s Deaver text-only windows carry that 26.6 text. `layout-order.md` and `place-geom.md` read Vision caches of their own, which the swap does not touch, so neither was regenerated.


## Measurement card

- **Truth.** Unchanged and the same files the dated scores used: the owner panel's adjudicated truth (`ocr_truth` cache, owner-checked pages as recorded there) and the 440's frozen public truths. No model drafted anything here; this item compares Vision with itself.
- **Selection.** Every image the dated readings covered: all 139 panel jobs, all 320 Latin-script pages of the 440 (Vision's script filter, unchanged), the capture ladder's scored pages (the panel's originals less the three agreement pages). Nothing chosen by a route or by ABBYY text. The panel's pages were drawn through Vision (26.6) itself: Every page where Apple Vision (26.6) read fewer than 20 words was replaced at the draw (19 of them, 4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as empty, and every comparison with Vision on them is on pages Vision could read.
- **Comparison.** Same images byte for byte, same tool source and settings, same scorer (`ocr_panel_score.score`, the 440's per-stratum options) and truth; only the OS differs. The `segbench-ocr` (2026-11-03) and `segbench-dewarp` (2026-10-31) binaries were rebuilt on 27.2 from unchanged sources. The request revision is the default in both runs: on 27.2 with the 27.2 SDK it defaults to 3 and supports 1-3, as before, and the dated readings' tool was itself a 27.0-SDK build, so the change is inside revision 3, in the OS, and reaches the app whatever SDK it is built with.
- **Noise.** Read twice on 27.2, 30 of 30 texts (15 panel images, 15 public pages, one of them handwritten) came back byte-identical. Handwriting is not: the 19 handwritten originals read again with both tools (W46.vision-27-swap) gave `ocr.swift` 17 of 19 identical (p050 -3.7, p053 -2.7 NES); `segbench-dewarp lines` 18 of 19 identical (p048 +0.5 NES); an earlier repeat of the 16 scored ones gave 13 and 15 of 16. So on 27.2 Vision varies run to run on a few handwritten pages, by up to 3.7 NES on a page, under 0.1 point on the 96's mean, far inside every interval here, and the pages that vary are the ones where the two tools disagree on 27.2 (p048, p050, p053; 93 of 96 scored originals agree, 96 of 96 on 26.6): the tools are not different, the readings are. Intervals are paired bootstrap 95% over pages (10,000 resamples, `ocr_panel_score.paired`); none is given under ten pages.
- **Scope.** Apple Vision text only, on these images. It does not re-read the capture ladder's defect rows (all read on 27.2 on 2026-11-03, and paired against the same-run re-save, so their deltas stand), nor the Processor's own Vision path in the app.
