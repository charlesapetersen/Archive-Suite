# Marks pre-flag pilot: what came back, and what it changes

W46.fix-marks-set-draft, reviewed 2026-10-29. The owner's session ran the frozen
15-page pilot (`marks-preflag-pilot.json`, freeze `09977f3b…`) on Sherlock, and
it was collected into the private artifact `marks-preflag-20261025`. Summary
from `marks_pilot.py summary`, which checks every receipt against the freeze:

| | |
|---|---|
| Reader | Qwen3.6-27B-FP8, revision `e89b16eb`, vLLM 0.31.0, one request at a time |
| Receipts | 15 of 15: 14 valid JSON, 1 parse failure |
| Pre-flagged (any mark) | 5 of the 14 |
| Request time | 78.1 s in all, median 5.16 s a page |
| Slurm elapsed | CPU stage 16 s; GPU job 5 min 51 s with model load |
| GPU-hours | 0.098 in total, about 0.076 of it startup |

The parse failure (Herrnstein `3edfd1a6…`) is a correct-looking object wrapped
in a ```` ```json ```` fence, despite "No Markdown". It was kept as a failure and
not retried.

## A session's look at the 15 images

Each image was checked at 1,500 px against the reply. This is one session's
visual check, **not truth**: it settles nothing about recall on small marks,
and no page here enters any benchmark on its strength.

| Page | Model | What is visible |
|---|---|---|
| Deaver `fdeb45f3` | annotation, signature | Handwritten source and date at the top (a true mark). The "signature" is the cartoonist's printed one |
| Herrnstein `66f1a780` | annotation | Handwritten note at the top right (true) |
| RG165 `0351a8d4` | annotation, overlap | A letter inked over the typed file number (true, overlapping) |
| Dean `eb8d819e` | annotation, signature, overlap | No ink on this side; the text and script showing through from the reverse side were flagged |
| RG165 `ee80aa79` | annotation, overlap | Heavy typewriter overstrikes and a struck date. Probably not handwriting; unsure |
| Dean `7af36b75` | none | The `$` and `%` in Table A may have been added by hand; unsure |
| Herrnstein `3edfd1a6` | parse failure (none in the fenced object) | Two underlined words, possibly by hand |
| 8 other pages | none | Nothing visible at this scale |

`page_kind` was `typed_printed` on all 14 valid replies, the full-page cartoon
included, so it is not informative.

## What it changes

- The reader follows the schema and finds clear handwriting, so the wider pass
  goes ahead with the same reader. It has no recall figure, and none can come
  from this pilot.
- Its false flags fall into three kinds that a prompt can name: text showing
  through from the reverse side, a printed signature, and typewriter
  underlining or overstrikes. The scan prompt (v2) names all three.
- W46.mixed-route-bands needs pages in each of the owner's four handwriting
  bands (`mixed-def-score.md`), so the scan asks for the band as well as the
  mark classes.
- The fence is removed before parsing and recorded in the receipt (`fenced`),
  so the receipt shows it was there.
- With startup about 4.5 minutes and about 5.2 s a page one at a time, a scan
  of about 1,000 pages is about 1.5 GPU-hours. The size review for it is in
  `execution-plans/items/W46.fix-marks-set-draft.md`.

No model's flags are mark truth. Precision and recall come only from the
drafted, audited and owner-checked set this item builds.
