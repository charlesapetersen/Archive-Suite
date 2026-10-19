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

The date parser succeeds on all 600 outputs; neither owner Date Uncertain behavior nor dating defaults
are improved by declaration: the combined model still emits no DU tags for the 50 uncertain documents.
Owner inferred-year accuracy54/131 is diagnostic. The same collection-split and catalogue-precision
limitations in `date-model.md` apply.

`seg-date-model-gpu.json` retains additive counts. `seg-date-model-frozen.json` records the reviewed
choice, exact original locked-test reference (260/330 document pages), and merged-weight SHA-256
57137dd743b2d63d4417f1a3d7e0008c353ec774ade784e4ed43e33ef73a8643.
## Final result: retain the separate models

The single locked GPU run 1857097 completed 310/310 windows, no failures. Locked-test document pages in
exact documents improve from 260/330 (78.79%) to 272/330 (82.42%). No test-guided repeat or tuning occurred.
The guarded Mac build completed600 date prompts and187 development windows, exit0. Development exact
document pages are 463/518 (89.38%), versus 468/518 (90.35%) for the separate 8-bit segmenter: a 0.965-point
loss, within the frozen limit. Mac comparisons use each model's own photo predictions, as the reference did.

| dating measure | separate GPU | combined GPU | separate Mac 8-bit | combined Mac 8-bit |
|---|---:|---:|---:|---:|
|Owner year|167/250|168/250|164/250|168/250|
|Owner month|76/120|77/120|78/120|77/120|
|Public year|285/300|290/300|284/300|290/300|
|Public month|224/240|227/240|224/240|227/240|
|Public day|139/150|138/150|140/150|139/150|
|Public full date|136/150|135/150|137/150|135/150|

**15 of 16 predeclared decision fields pass. Mac public full-date accuracy fails:** 135/150 (90.00%) versus
137/150 (91.33%), a 1.333-point loss. This is only two documents; it is not evidence of a statistically
reliable difference. It nevertheless exceeds the owner's fixed maximum-one-point rule. **Keep the
separate segmentation and dating models under that rule.** No combined-model default or publication.
All counts and exact-fraction decisions are in `seg-date-model-final.json`.

The Mac run took 4343s for dates plus segmentation, with 3437s for the 187 segmentation windows. MLX peak
4.37GB; the unchanged guard recorded 5152MB peak footprint and 2769MB RSS, no kill. Both model builds/raw
answers remain under Long term storage/FarmShare-20261018. Every date output parses. Both combined GPU
and Mac still emit no DU tags for the 50 owner-uncertain documents. App defaults remain unchanged.
