# Can the straightening slope reuse the Vision reader's pass? (W49.proc-vision-page-cache)

Measured by `scripts/segbench/vision_cache_slope.sh` on 2026-11-26 (rows: `vision-page-cache-slope.tsv`). The
reading copy straightens a page whose lines slope by 1 degree or more (`ReadingCopy`, the trigger from
`place-geom-real5.md`). It measures that slope with its own Vision pass: accurate recognition at 1,600 pixels, no
language correction. On a run whose reader is Apple Vision with default settings, or whose read-poorly check has
run, the shared page cache already holds a full-page pass at the same turn: accurate, language correction on, en-US.
The question was whether the slope can be read from that pass and the separate one dropped.

## Verdict

**No. The reading copy keeps its own pass.** Read from the shared pass, the slope moves the straighten-or-leave decision
on **7 of 297 page images (2.4%)**. Six of them sit within 0.4 degrees of the 1-degree trigger, and one is p094 as stored,
which reads 0.0 degrees on its own pass and 2.2 on the shared one. Elsewhere the two agree closely: the median
difference is 0.03 degrees, 0.25 at the 90th percentile, and 2.2 at most. Neither is more consistent with the turns
applied (median error 0.071 against 0.084 degrees). The saving would be one pass of about 0.16 s per page (median;
the shared pass took 0.19 s). That is too little to justify changing a decision on about 1 page in 40 that was measured
on the separate pass.

| | pages |
|---|---|
| page images read (99 owner pages × as stored, +2.5°, −4°) | 297 |
| both passes give a slope | 293 |
| own pass only / neither | 2 / 2 |
| straighten decision differs | 7 |
| difference above 0.3° | 22 |

## Measurement card

- **Truth.** None for the slope itself. The check is agreement between the two passes, plus each pass's consistency
  with the turn applied: the slope as stored plus the applied +2.5 or −4 degrees, by `ReadingCopy.straightened`.
- **Selection.** The 99 cached original images of the owner's OCR panel
  (`~/Library/Caches/ArchiveSuiteRehearsal/ocr-panel-local/images/*-original.jpg`). They were chosen by neither pass, and
  each page was read as stored and turned twice. The skewed public photographs of place-geom-real5 were no longer in
  the cache.
- **Comparison.** Same image file and same slope formula (`ReadingCopy.lineAngle(of: PageVisionSnapshot)`). Only the
  Vision pass differs: 1,600 pixels without language correction, against full size with correction and en-US.
- **Noise.** Single run. Vision is deterministic on one machine for the same input, so the 7 decision changes are a
  property of the passes, not rerun noise. n = 297 images from 99 pages; the images of one page are not independent.
- **Scope.** This covers the straightening slope only. Rotation (a 1,000-pixel thumbnail with correction and a
  minimum text height, `rotation-routes.md`) and page kind (full size without correction; the bundled model was fitted
  on those features) were not merged either. Each was measured or fitted on its own pass, and a merge would need those
  measurements rerun, not this one.
