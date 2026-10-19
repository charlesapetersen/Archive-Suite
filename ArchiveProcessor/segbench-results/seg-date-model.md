# Combined segmentation + dating 2B — fixed-recipe comparison

Training1856294 completed in4h37m on one L40S: the unchanged13,313-row mix (5,885 segmentation windows,
7,428 dating examples), one epoch, seed41. No recipe search. The unrounded single-task references and
one-point acceptance fields were committed before outputs in `seg-date-comparison-plan.json`.

## GPU checks before the locked test

| measure | separate 2B | combined 2B |
|---|---:|---:|
| Development document pages in exact document |469/518 (90.54%)|467/518 (90.15%)|
| Held-out agreed gaps correct |5443/5668 (96.03%)|5412/5668 (95.48%)|
| Owner year exact |167/250|168/250|
| Owner month exact |76/120|77/120|
| Public year exact |285/300|290/300|
| Public month exact |224/240|227/240|
| Public day exact |139/150|138/150|
| Public full date exact |136/150|135/150|

All decision fields pass the maximum absolute loss0.01 at this stage. Dev uses the same oracle photo
labels as the GPU reference; that differs from the Mac's own-photo comparison. All187 dev windows are
successful. All2459 held-out windows are terminal and unique; three remain malformed after the existing
retry, including two length caps. Their gaps receive neutral0.5 votes, rather than disappearing from the
denominator. This yields the same counts as the original scorer's diagnostic omission here. No extra
inference retries or test-guided training. False splits191/false merges65 on the5668 agreed gaps.

The date parser succeeds on all600 outputs; neither owner Date Uncertain behavior nor dating defaults
are improved by declaration: the combined model still emits no DU tags for the50 uncertain documents.
Owner inferred-year accuracy54/131 is diagnostic. The same collection-split and catalogue-precision
limitations in `date-model.md` apply.

`seg-date-model-gpu.json` retains additive counts. `seg-date-model-frozen.json` records the reviewed
choice, exact original locked-test reference (260/330 document pages), and merged-weight SHA-256
57137dd743b2d63d4417f1a3d7e0008c353ec774ade784e4ed43e33ef73a8643.
The single locked-test pass follows this committed freeze. The Mac600-date/187-dev comparison is running
under the unchanged resource guard. **Final acceptance remains pending both checks.** No app default,
model publication, release, paid call or real-corpus write is included.
