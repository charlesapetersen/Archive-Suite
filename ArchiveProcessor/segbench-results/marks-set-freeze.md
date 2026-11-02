# Marks set: the answered owner core

40 pages answered; 85 accepted boxes (1 added), 23 draft candidates rejected.

Question feedback: 18 entries on 12 pages. These pages remain in the reviewed record but are excluded from detector labels until resolved. 16 kept entries containing feedback have no scored text. Raw owner entries are retained verbatim in the frozen record.

| Core group | Answered pages | Detector-eligible pages | Accepted rough boxes |
|---|---:|---:|---:|
| A-core | 16 | 14 | 7 |
| B-core | 24 | 14 | 78 |

Feedback pages: Dean-0a07517aa636ba99, Dean-23edf5f15485b7ff, Dean-24a6d76b84c2729b, Dean-7d1bce1dde28dfee, Dean-b31c4f7387db3844, Dean-d3a52a7e272b066a, Dean-e6ecf7a0b3ed6e6b, Herrnstein-04d25d2e123a33d0, Herrnstein-39bea9fb30cda479, Herrnstein-3f753f88969588ac, Herrnstein-5d66cd10e6af25f0, RG165-15a0647456422fb9.

## Measurement card

- **Truth.** Owner keep/reject, class, touches-print and handwriting bands on all 40 pages. Two model families proposed the rough boxes; the owner added missed boxes. Question comments in transcription fields are preserved separately and never scored as document text. Explicit duplicate/grouping and legibility concerns remain unresolved, rather than being merged or guessed.
- **Selection.** Frozen 150-page two-phase selection; 16 A-core and 24 B-core pages. The core is enriched and has no validated population inclusion weights. All results stay descriptive by core group; independent mixed prevalence is unchanged.
- **Comparison.** This is a truth freeze, not a model ranking or OCR experiment. Non-core agreed drafts stay separate and are not evaluation truth. Existing owner bands are not re-labelled.
- **Noise.** No accuracy estimate or confidence interval. Excluded pages are not zero-mark negatives. Keep uncertainty at field/page level; do not infer tight localization from rough boxes.
- **Scope.** Descriptive enriched core, A-core/B-core apart. No population weights or prevalence. Feedback pages are not detector training/evaluation truth; rough draft boxes are not independently measured geometry. Non-core agreement remains model drafts, never truth.

## Provenance

Frozen record: `/Users/cp1/Library/Application Support/ArchiveSuiteRehearsal/marks-set-frozen-da388b05c388`.
Input SHA-256 receipts are in the adjacent JSON. Images and all owner text stay outside Git.

## Feedback view repair prepared — 2026-11-01 (item remains open)

`marks_feedback.py` accounts for all 18 comments: seven entries record six explicit
relationships; two retain rejected candidates; nine places on seven pages need a
bounded owner recheck. Relationship metadata preserves every class, band and rough
box. In particular, duplicated text does not establish identical geometry, and
connected boxes with different owner classes are not silently merged.

The corrected sheet uses hash-verified original JPEG bytes (9,420,729 bytes across
seven pages), with EXIF-upright coordinates, native-pixel clean crops/full-page
views, rotation, hideable boxes/numbers and separate mark notes. It is ready now:
the known view defects are fixed and the remaining pending experiments consume
this truth, rather than changing these nine questions. Allow about 30–45 minutes,
with sittings supported by isolated browser storage.

Open `~/.local/state/archive-autonomous/artifacts/marks-feedback-da388b05c388/index.html`
and export `marks-feedback-answers.json`. Labels/bands remain locked. An unread or
incomplete reading may stay blank with an uncertainty note. A source-bound envelope
prevents the seven-page export being mistaken for a new core. Gate
`W46.fix-marks-sheet-feedback-owner-ok` waits for the owner's export; a later pass
validates and folds it against the full baseline, settles grouped subannotations
and publishes a new derived truth without replacing the original freeze.

The da388b05c388 freeze, 40 labels/bands and all exclusion masks are unchanged.
All 12 feedback pages remain outside detector training/evaluation; missing label
files are never no-mark negatives. No transcription is inferred from comments,
no model run or paid call was made. Kept the review artifact and its original-byte
receipts as pending owner work; no disposable benchmark cache was created.
