# 12. Training on the user's own photographs: the kit, its gate, its plug-in points

Draft for Phase 4 (W46.review-phase4), 2026-11-06. Format and schema: `13-stage-rules/00-index.md`. Every figure names
its file; [M] measured, [I] inferred, [?] unverified.

## 1. Stage and question

The kit trains a model on one user's own material (a segmentation student or LoRA continuation on a cluster, a
same-hand line-recogniser fine-tune on the Mac) and admits it to the app only through a held-out gate and a manifest.
The user chooses whether to train at all (the general interview's fine-tuning answer); the range view then shows
the trained routes as "after training" points beside the shipped routes of stages 04 and 07, each with its condition.

## 2. Is there a choice?

Yes, of a special kind. No row here is a route the user can pick on day one: each row has status `after-training`,
appears only when the fine-tuning answer allows it, and becomes selectable only once its condition holds (enough
labels, and for segmentation a passing gate and a manifest). The solver never picks an after-training row as a
default; it shows it as a point with its expected gain against the route it would replace. Three routes are rows; a
fourth (the Mac segmentation LoRA) is a row marked not offered, so the sheet can say why it is absent.

## 3. The rule for the settings layer

Text the sheet shows: "Training adapts a model to your material. It is optional, runs on a cluster (segmentation) or
on this Mac (one handwriting hand), and a trained model is used only after it passes a check on pages it never saw."

The fine-tuning answer (general interview, `12-settings-design.md` §3.1: no; with a coding agent; on a cluster):
- **no** (the default): no row of this stage is shown.
- **with a coding agent** (no cluster): the Mac-side row only, `kit-hands-ppocrv6-ft`, for the handwritten kind.
  The answers are nested; the mapping is confirmed (call 7.6, decided 2026-11-06).
- **on a cluster**: the cluster rows as well (`kit-seg-student-tags`, `seg-2b-lora-k200`), with `needs.cluster`
  true. A cluster answer without a coding agent still shows them: the README's steps are manual commands
  (`institutional-compute/README.md`, training section) [M].

Comparison metric and tie rule. Segmentation rows use stage 07's metric (gap accuracy on known gaps, unsure gaps out,
W46.seg-unsure-mask), paired against the shipped 2B on the same gaps. No rerun floor has been measured in gap
accuracy: the 1.4-3.2-point floor a box (SEG-10, quoted in `seg-kit-gate.md`) is measured in pages exact and is not
reused as the gap-accuracy tie unit (P7-4; `seg-boxes-score.md` Noise). So a segmentation difference is a tie when its
paired interval reaches zero, and the gate leans on that interval and on a checker-enforced minimum support. The
handwriting row uses stage 04's NES in points, paired against the same recogniser untuned on the same held-out pages.
Both sides are kraken, whose fixed-weight rerun floor is 0 (`ocr-ppocrv6-hands.md` Noise, not remeasured; the 0.49
there is the comparators' floor), so the paired interval decides: a tie is an interval reaching zero.

The gate, as proposed (`seg-kit-gate.md` §The gate; `institutional-compute/README.md`): the candidate needs an anchor
score on a locked public box, a held-out score on the user's own held-out collections, and a paired held-out interval
against the shipped model whose low end is above -3 points, paired over every gap the shipped run answered with the
candidate's unanswered gaps counted wrong; a candidate with no shipped run or no paired gap fails (W46.kit-gate-coverage,
which closed P2-1). `train_seg.py check` exits 1 on failure and writes `archive-seg-manifest.json`. The app's admission
rule is narrower and separate: `LocalSegmenter.refusal` refuses a model folder without a manifest of kit `seg-kit-1`,
prompt c1 and an anchor pages-exact score (`seg-kit-gate.md`) [M]. The threshold, the minimum support and the anchor
margin were call 7.2, decided 2026-11-06: gap accuracy against the shipped 2B, a checker-enforced minimum known-gap
count from the measured "needed" column (about 147 or 267 gaps, `seg-kit-gate.md`), two scored runs, and an anchor
margin of 3.2 points on the public anchor. Until W46.kit-gate-rule enforces it, the solver shows the gate's verdict and
interval, and never shows an after-training segmentation row as selectable without a manifest that passed.

Kind rules. Segmentation rows are per material, not per page kind: a trained student or continuation applies to the
collection (or project of similar collections) it was gated on, and the manifest's held-out collections name it. The
handwriting row applies to the handwritten kind and to one hand: one fine-tune per hand, with its own held-out pages.
No row covers typed, printed, forms, clippings, newspapers or non-Latin scripts; for them the stage has no route
("none found": H §6.3 lists no small-data VLM OCR success, and a VLM OCR LoRA is "not in the kit until a small-data
success exists").

Fallback. When an after-training route fails on a page or window, the stage falls back to the route it replaced:
the shipped 2B for segmentation (`seg-qwen3.5-2b-8bit`, stage 07), the untuned recogniser for handwriting (stage 04).
A failed window counts as the bench's neutral answer (`seg-kit-gate-sherlock.md`). A model the app refuses is never run.

When the stage must not run. No training when a stage has fewer labels than its floor (H §6.3 step 1): fewer than 200
corrected gaps of one material for a continuation (the trigger is note 07's), fewer than 80 line-broken corrected
lines of one hand for the handwriting fine-tune (call 7.4, decided). No handwriting fine-tune from paragraph-level truth
(`ocr-ppocrv6-hands.md`: the owner's Shils pages, 3 of 4 held-out pages worse). No Mac segmentation training at
16-18 GB (row `kit-seg-lora-mac`). No anchor or held-out set built from material the model trained on (H §6.3 step 2:
hold out whole collections or boxes, never a random page split).

## 4. Table rows

```json
[
 {
  "id": "kit-seg-student-tags",
  "name": "Segmentation student trained on your tagged corpus (cluster), served on the Mac or the cluster",
  "family": "kit",
  "app_route": null,
  "status": "after-training",
  "needs": {"key": [], "plan": [], "cluster": true, "mac_gb": 16, "gpus": 1},
  "figures": {
   "owner-heldout-box-sasha": {"value": 89.1, "n": 175, "truth": "owner-ruled Sasha, known gaps", "metric": "gap accuracy",
     "source": {"file": "ArchiveProcessor/segbench-results/seg-kit-gate-sherlock.md", "route": "fine-tuned Qwen3.5 2B (the shipped build's source)", "attribute": "Sasha gap accuracy", "value": "89.1%"}},
   "owner-heldout-box-sasha-pages": {"value": 46.6, "n": 174, "truth": "owner-ruled Sasha; 174 resolved document pages (seg-boxes-score.md common support)", "metric": "pages exact",
     "source": {"file": "ArchiveProcessor/segbench-results/seg-kit-gate-sherlock.md", "route": "fine-tuned Qwen3.5 2B", "attribute": "Sasha pages exact", "value": "46.6%"}},
   "owner-test-boxes": {"value": 80.3, "n": 363, "truth": "owner-ruled Stanton and RG165", "metric": "pages exact, no checking",
     "source": {"file": "ArchiveProcessor/segbench-results/seg-students.md", "route": "Qwen3.5 2B, fine-tuned", "attribute": "test pooled, no checking", "value": "80.3%"}},
   "public-lincoln-anchor": {"value": 33.07, "n": 251, "truth": "lincoln.json 5ba5a0e67380", "metric": "pages exact (20.96 to 47.83)",
     "source": {"file": "ArchiveProcessor/segbench-results/seg-kit-gate.md", "route": "shipped manifest", "attribute": "anchor pages exact", "value": "33.07%"}},
   "public-tabme": {"value": 0.814, "n": 6236, "truth": "TABME++ test split", "metric": "boundary F1",
     "source": {"file": "ArchiveProcessor/segbench-results/seg-tabme.md", "route": "Trained 2B, images and text", "attribute": "boundary F1", "value": "0.814"}}
  },
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": null, "price_read": null,
    "source": {"file": "ArchiveProcessor/segbench-results/seg-students.md", "route": "Qwen3.5 2B, fine-tuned", "attribute": "per 1,000 pages, standard", "value": "$0.00"}},
  "time": {"per_unit_s": 6.0, "per_window_s": 18.0, "measured": true, "measured_on": "M3 Pro 18 GB, 8-bit MLX build, about 6 s a page (18 s a seven-page window)", "derived": "seconds a seven-page window over 3, a window every 3 pages at stride 3",
    "source": {"file": "ArchiveProcessor/segbench-results/seg-students.md", "route": "2B, 8-bit", "attribute": "s a window", "value": "18"}},
  "memory": {"peak_gb": 4.4, "measured_on": "M3 Pro 18 GB",
    "source": {"file": "ArchiveProcessor/segbench-results/seg-students.md", "route": "2B, 8-bit", "attribute": "peak GB", "value": "4.4"}},
  "caveats": [
   "figures are the owner's own student (trained on his tags via the 27B teacher), not a measured result for another user's tags",
   "Sasha is one held-out owner box; the 2B leads its teacher there 89.1% to 67.4% (44 gaps to 6), which shows the teacher can be beaten, not by how much elsewhere (seg-kit-gate-sherlock.md)",
   "on TABME++ the students read like a zero-shot reader of about the teacher's quality on one public set (P10-10)",
   "the 97.6% held-out figure is agreement with the teacher on agreed gaps, not accuracy, and is not used (SEG-5)",
   "scored against the user's tags the gate inherits their noise: 5.3% wrong among agreed labels, 0-12.4% (seg-kit-gate.md)",
   "training wall time for the seg students is not recorded in the files read (H-corpus.md 6.3)",
   "the Mac build step does not exist in the kit yet (W46.kit-mac-build)"
  ],
  "kind_rules": ["per material: applies to the collections named in its manifest"],
  "fallback": "seg-qwen3.5-2b-8bit",
  "conditions": [
   "the fine-tuning answer is 'on a cluster'",
   "the user's corpus has per-document structure (tags or folders) to label from (H-corpus.md 6.3 item 3)",
   "train_seg.py check passes under the gate rule of call 7.2 (gap accuracy, minimum support, two runs, 3.2-point anchor margin), on held-out whole collections and the locked anchor",
   "archive-seg-manifest.json beside the Mac build, hashed on that build (W46.kit-mac-build)"
  ]
 },
 {"id":"seg-2b-lora-k200","name":"The 2B adapted to your material (LoRA continuation on a cluster after about 200 corrected gaps)","family":"kit","app_route":null,"status":"after-training","needs":{"key":[],"plan":[],"cluster":true,"mac_gb":16,"gpus":1},
  "figures":{"manuscripts-public.next_box":{"value":86.8,"n":244,"truth":"Lincoln box 2: catalogue starts plus Gemini 3.7 continuation calls (lincoln2.json)","metric":"pages exact; corpus 2B 52.1%","source":{"file":"seg-adapt-lora.md","route":"LoRA, k = 200, box 2","attribute":"pages exact","value":"86.8%"}},
   "manuscripts-public.next_box_errors_per_100":{"value":4.9,"n":244,"truth":"as above","metric":"errors per 100 gaps; corpus 2B 17.2; change -12.3 (-18.8 to -7.4)","source":{"file":"seg-adapt-lora.md","route":"LoRA, k = 200, box 2","attribute":"errors per 100 gaps","value":"4.9"}},
   "manuscripts-public.next_box_errors_per_100_k50":{"value":15.6,"n":244,"truth":"as above","metric":"errors per 100 gaps; change -1.6 (-4.5 to +1.2), a tie","source":{"file":"seg-adapt-lora.md","route":"LoRA, k = 50, box 2","attribute":"errors per 100 gaps","value":"15.6"}}},
  "cost":{"usd_1000_list":0,"usd_1000_batch":null,"price_read":null,"source":{"file":"seg-adapt-lora.md","route":"What this means","attribute":"cost","value":"about 1.4 GPU-hours on Sherlock; $0.45 gateway for box 2's truth only"}},
  "time":{"per_unit_s":null,"measured":false,"measured_on":"training 15 and 54 minutes on one Sherlock GPU; serving as the 2B","source":{"file":"seg-adapt-lora.md","route":"What this means","attribute":"training","value":"15 and 54 minutes"}},
  "memory":{"peak_gb":null,"measured_on":"unmeasured: an adapter or merged continuation on the Mac was not measured; the shipped 2B 8-bit it continues peaks at 4.4 GB on the M3 Pro (seg-students.md); Mac training not measured to fit (P9-12)","source":null},
  "caveats":["the pre-set rule (no loss of start recall) is not met: at k = 200 each box loses one start (box 2 finds 67 of 69 catalogue starts against the 2B's 68)","one material (Lincoln correspondence), two adjacent boxes, one training seed","box 2's truth holds no scored start inside an item (P9-8)","k = 50 buys a tie on box 2 and loses two catalogue starts there"],
  "kind_rules":["per material: the next boxes of the material the corrections came from"],"fallback":"seg-qwen3.5-2b-8bit",
  "conditions":["the fine-tuning answer is 'on a cluster' (14-owner-calls.md call 7)","at least 200 corrected gaps of one material in the review records (trigger: note 07)","labelled 'measured on one material'","review flagging by disagreement with a second model stays on after adaptation","the kit's gate passes on a held-out box of the same material (note 12, seg-kit-gate.md)"]},
 {
  "id": "kit-seg-lora-mac",
  "name": "Segmentation LoRA trained on this Mac",
  "family": "kit",
  "app_route": null,
  "status": "after-training",
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": null, "gpus": 0},
  "figures": {},
  "cost": null,
  "time": null,
  "memory": {"peak_gb": null, "measured_on": "M3 Pro 18 GB: no image-window step finished; stops at 8.26-10.25 GB process memory under guards, lower bounds",
    "source": {"file": "ArchiveProcessor/segbench-results/kit-mac-lora.md", "route": "seg-20-r8-i20", "attribute": "stopped", "value": "10.25 GB process memory"}},
  "caveats": [
   "not measured to fit on 18 GB: every stop was a guard, not an out-of-memory failure (P9-12)",
   "Qwen3.5's Gated DeltaNet kernel has no gradient in mlx-vlm; train mode takes a memory-heavy path (kit-mac-lora.md)",
   "a 32 GB or larger Mac is unmeasured",
   "any adapter-against-2B figure measures adaptation to the scoring text (Vision for ABBYY), not Mac against cluster training (P6-4)"
  ],
  "kind_rules": [],
  "fallback": null,
  "conditions": ["not offered in this release (14-owner-calls.md call 7); revisited only if a Mac step is measured to complete"]
 },
 {
  "id": "kit-hands-ppocrv6-ft",
  "name": "kraken PP-OCRv6 fine-tuned on corrected lines of one hand (Mac)",
  "family": "kit",
  "app_route": null,
  "status": "after-training",
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 16, "gpus": 0},
  "figures": {
   "handwritten-one-hand-160-lines": {"value": 2.50, "n": 16, "truth": "By the People, Blackwell held-out pages", "metric": "NES gain over the untuned model, base 59.7; +1.70 to +3.24 (CPU)",
     "source": {"file": "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "route": "blackwell-n160-cpu", "attribute": "delta", "value": "+2.50"}},
   "handwritten-one-hand-160-lines-mps": {"value": 2.60, "n": 16, "truth": "Blackwell held-out", "metric": "NES gain; +1.74 to +3.43",
     "source": {"file": "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "route": "blackwell-n160-mps", "attribute": "delta", "value": "+2.60"}},
   "handwritten-one-hand-80-lines": {"value": 1.12, "n": 16, "truth": "Blackwell held-out", "metric": "NES gain; +0.31 to +1.91 (CPU)",
     "source": {"file": "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "route": "blackwell-n80-cpu", "attribute": "delta", "value": "+1.12"}},
   "handwritten-owner-base": {"value": 71.6, "n": 16, "truth": "owner 16 handwritten pages, drafted, hand places owner-checked", "metric": "NES of the untuned recogniser on blla lines",
     "source": {"file": "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "route": "ppocrv6-kraken-blla", "attribute": "handwritten", "value": "71.6"}}
  },
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": null, "price_read": null,
    "source": {"file": "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "route": "all", "attribute": "money", "value": "No money"}},
  "time": {"per_unit_s": null, "measured": true, "measured_on": "M3 Pro 18 GB: training 6.3 min (MPS) or 18.1 min (CPU) at 160 lines; reading 4.2-13.6 s a page median (CPU)",
    "source": {"file": "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "route": "blackwell-n160-mps / -cpu", "attribute": "minutes", "value": "6.3 / 18.1"}},
  "memory": {"peak_gb": 5.88, "measured_on": "M3 Pro 18 GB, MPS training at 160 lines (CPU 3.54; reading 5.78-5.87 a call)",
    "source": {"file": "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "route": "blackwell-n160-mps", "attribute": "peak GB", "value": "5.88"}},
  "caveats": [
   "one public hand, one seed per condition; seed and cross-hand variability unmeasured",
   "20 and 40 lines are ties; 240 against 160 is a measured tie, both trained to early stop at 5 epochs (P7-5)",
   "on the owner's Shils pages with paragraph truth it made 3 of 4 held-out pages worse",
   "the untuned recogniser is 71.6 on the owner's hand pages against 89.9 for LightOnOCR-3 4B 8-bit on the Mac, so a +2.5 gain does not close that gap",
   "needs blla or Vision line boxes and a line-correction screen, which the Processor lacks today and builds in this release (H-corpus.md 6.3; 14-owner-calls.md call 7)",
   "the kraken port's licence is not stated in the files read [?]"
  ],
  "kind_rules": ["handwritten only; one fine-tune per hand"],
  "fallback": "ppocrv6-kraken-blla",
  "conditions": [
   "the fine-tuning answer is 'with a coding agent' or 'on a cluster'",
   "at least 80 line-broken corrected lines of one hand, target about 160 (call 7.4, decided)",
   "the line-correction screen exists (built in this release, 14-owner-calls.md call 7)",
   "a separate held-out acceptance check for each hand passes (ocr-ppocrv6-hands.md)",
   "kraken PP-OCRv6 on blla lines is the stage 04 route the user has (the low-memory fallback)"
  ]
 }
]
```

The row `seg-2b-lora-k200` is one row shared with note 07, copied there as the same JSON; its bare file names are in
`ArchiveProcessor/segbench-results/`, as note 07's are. Note 07 owns its trigger; this note owns the training job, the
gate and the held-out box.

Fields used beyond 00-index.md's schema: `metric` inside a figure; figure keys of the form `kind.attribute` (the shared
row); a `memory.source` of null with the reason in `measured_on`.

## 5. Caveats carried

- **SEG-5** (`11-measurement-audit.md` lines 341-348). The students' 97.6% is agreement with the teacher on 5,668
  agreed held-out gaps, not accuracy. No row quotes it; the student row uses Sasha (owner-ruled, held out) and the test
  boxes, and its caveat says so.
- **SEG-6** (label noise). 5.3% wrong among agreed labels (0-12.4%) and 9.5% for start-trust; a gate scored on the
  user's tags carries it. The rule asks for `--ruled` when the user has ruled gaps.
- **SEG-10** (rerun floor 1.4-3.2 points a box, in pages exact) with **P7-4** (the floor applied to gap accuracy without
  saying so). Respected: the floor is not the gap-accuracy tie unit; the gate's bootstrap interval does not include rerun
  wobble (`seg-kit-gate.md`: "the gate should score two runs, or demand the difference clear the larger floor"), so the
  decided gate scores two runs; the anchor margin of 3.2 points is the floor's top, on the pages-exact anchor.
- **P2-1** (kit checker passes without its comparison). Closed by W46.kit-gate-coverage: a candidate with no shipped run
  or no paired gap fails, and unanswered gaps count wrong (`seg-kit-gate.md`, README) [M from the files; the fix's tests
  were not rerun here].
- **P2-2** (unsure gaps as artificial agreements). Every segmentation figure in the rows is on known gaps, unsure out
  (W46.seg-unsure-mask), as both kit reports state.
- **P2-3** (stale kit tables and manifest). The shipped manifest's anchor is now 33.07% (20.96 to 47.83) on truth
  `5ba5a0e67380…`, the current Lincoln truth; the planning estimate is now about 1,850 gaps, not the earlier 1,988.
- **P2-4** (shared errors are not a ceiling; noise need not cancel). The rows carry no ceiling claim; the gate's
  label-noise effect is the discordant-gap sensitivity (gap-accuracy difference shifts ±0.41 to ±1.2 points at 5.3%
  and 12.4%, `seg-kit-gate.md`), a sensitivity, not a noise term.
- **P4-2** (SC0122 truth not independent). SC0122 and the Illustrated Review are trained-on diagnostics; no row uses them.
- **P6-4** (Mac LoRA against the 2B is adaptation to the scoring text). No Mac image step finished, so no such figure
  exists; the condition is a caveat on `kit-seg-lora-mac` for any later one.
- **P7-5** (the step-budget premise was wrong). The hands row says 240 against 160 is a measured tie with both trained to
  early stop at 5 epochs (-0.27 (-1.13 to +0.51) CPU; +0.25 (-0.39 to +0.74) MPS); no step-budget hedge is carried.
- **P9-12** (18 GB Mac "not measured to fit"). The Mac LoRA row is worded so; a text-only LoRA's fit depends on its
  sequence length (one step done at 1,121 tokens, 4.52 GB; a 2,849-token step stopped at 8.43 GB, `kit-mac-lora.md`).
- **P9-8** (box 2 has no scored internal start). A condition on the continuation row.
- **P10-10** (TABME++). The student row says "zero-shot, about the teacher's quality, on one public set" for other users'
  material; it is not a default with the owner's figures.
- **Pass 3, reference coverage and minimum support** (`measure-reviews/2026-10-31-3.md`). The repaired checker can still
  pass on a tiny reference-supported comparison, and the 1,850-gap figure is document resampling within five owner
  boxes, not a guarantee for new collections or rerun variance. Assessed in call 7.2; not adopted here.
- **Input shift** (`seg-kit-gate-sherlock.md`). The students trained on ABBYY-text windows and are measured on Vision
  text, the app's input; a kit run for a user trains on Vision text (no ABBYY input, owner 2026-10-30) [I].

## 6. What would change the rule

- A Mac image-window LoRA step that completes on a 32 GB or larger Mac, or an mlx-vlm release with a gradient for the
  Gated DeltaNet kernel that completes one on 18 GB (`kit-mac-lora.md` Scope): `kit-seg-lora-mac` becomes offerable at
  the measured tier.
- A continuation measured on a second material unlike Lincoln, or on the owner's own boxes, with internal-start recall
  scored (P9-8): the 200-correction floor and the "flagging stays on" condition are re-read.
- A per-hand fine-tune scored on a second hand or a second seed: the 80/160-line floor moves, or becomes per-script.
- A student trained on another user's tags, gated on that user's held-out box: the student row's figures stop being
  the owner's.
- A measured held-out set size on a non-owner collection, or two-run gate scoring: the minimum n in call 7.2.

## 7. Owner calls

**7.1 Does the kit ship in this release, and in what form?** Options: (a) the cluster kit only (student from tags,
continuation after 200 corrections) plus the Mac handwriting fine-tune; (b) the cluster kit only; (c) cluster kit and
a Mac segmentation LoRA; (d) not in this release. Evidence: the cluster kit runs end to end dry except one step (no step
builds the Mac model, `seg-kit-gate.md` §The kit end to end; W46.kit-mac-build) [M]; the Mac segmentation LoRA is not
measured to fit at 18 GB and is unmeasured at 32 GB (`kit-mac-lora.md`, P9-12); there is no Sherlock profile yet
(`STATE.md`; profiles are farmshare and example-university) [M]. The handwriting fine-tune needs a line-correction screen
the Processor lacks (H §6.3). Recommendation was (b). Decided (owner, 14-owner-calls.md call 7): (a), the cluster kit
with the continuation, W46.kit-mac-build before it ships, no Mac segmentation LoRA, and the handwriting fine-tune with a
line-correction screen built in this release.

**7.2 The gate rule.** The proposed rule (low end of the paired held-out interval above -3 points against the shipped
model, every expected gap counted). Open parts: (i) the measure: gap accuracy needs about 147 (4B against 2B) or 267
(teacher against 2B) held-out gaps for ±3 points, pages exact about 1,850-1,923 (`seg-kit-gate.md`); (ii) a minimum n
the checker enforces, since the repaired checker can still pass a tiny comparison (pass 3); (iii) the rerun floor on
top (score two runs, or require the larger floor); (iv) the anchor: required to exist, but no margin is set, while H
§6.3 step 6 asks for "not below the shipped model on the public anchor by more than a stated margin"; the shipped
anchor is Lincoln, 33.07% (20.96 to 47.83) on 75 documents. Options: adopt as proposed; adopt on gap accuracy with a
minimum known-gap count from the table above and two runs; adopt with an anchor margin as well. Recommendation:
gap accuracy, a checker-enforced minimum taken from the measured "needed" column, two scored runs, and an anchor
margin the owner sets; the figures do not choose the margin. The 1,850 figure is within five owner boxes only (pass 3).
Decided (session, 14-owner-calls.md section 2): that rule, with an anchor margin of 3.2 points, the rerun floor's top.

**7.3 The licence statement for research-licensed models run through the kit.** The principle is settled (owner,
2026-10-20, `00-plan.md`: a model a user runs on their own cluster through the kit may carry a research or
non-commercial licence, stated plainly in the kit). Not settled: the wording and where it sits. The kit README has
no licence statement today (grep, `institutional-compute/README.md`) [M]. The kit's own bases are Apache-2.0 (Qwen3.5,
kraken, doc-split-v1) and mlx-vlm MIT (`10-gap-audit.md` stage 10); the kraken PP-OCRv6 port's licence is not stated in
the files read [?]; research-licensed readers such as Churro-3B appear on R7 (`10-gap-audit.md`). Options: a README
section plus a manifest field (`licence`) the app shows on the range point; a README section only. Recommendation:
both, so the range view can show it; the wording is the owner's. Decided (session, section 2): both, the wording the
owner's at ship time.

**7.4 The handwriting fine-tune's place: how many corrected lines before it is offered.** Measured on one hand: 20 lines
-0.14, 40 lines -0.32 (ties), 80 lines +1.12 (+0.31 to +1.91), 160 lines +2.50 (+1.70 to +3.24), 240 lines a tie with 160
(`ocr-ppocrv6-hands.md`). Gemini given 8 or 16 corrected lines: ties (+0.25 and -0.46, `ocr-ppocrv6-hands-paid.md`); Qwen
in-context is "not an adaptation route on this evidence" (`ocr-ppocrv6-hands-qwen.md`). Options: offer from 80 lines with
a 160 target; offer from 160; do not offer in this release. Note the base recogniser trails LightOnOCR-3 4B on the owner's
hand pages (71.6 against 89.9), so the route matters only where kraken is what the user runs. Recommendation: offer from
80 with 160 as the target, on the handwritten kind, only after a line-correction screen exists; else not this release.
Decided (owner, 14-owner-calls.md call 7): offered from 80 corrected lines, target 160, on the handwritten kind; the
line-correction screen is built in this release.

**7.5 The adaptation-after-200-corrections rule's plug-in point (kit's part only; the rule is note 07's).** The kit's
part: the continuation is a cluster job the kit runs when the review records hold at least 200 corrected gaps of one
material; its held-out set is the next box of that material; it passes the gate before the app loads it; flagging stays
on. Open: where corrections live for the kit (H open question 9, gap audit §6); whether a next box of about 244 gaps
(box 2's size, `seg-adapt-lora.md`) is enough held-out support under call 7.2, given 267 is the larger gap-accuracy
figure. Carried to note 07 for the trigger; the support question is decided with 7.2. Decided (session, section 2):
corrections live in the review records; the next box of the same material is the held-out set; the gate's minimum
support applies to it.

**7.6 The fine-tuning answer's mapping.** Section 3 reads "with a coding agent" as Mac-side steps and "on a cluster" as
adding cluster rows [I]. Confirm, or make the coding agent a requirement for the cluster rows too. Decided (session,
section 2): confirmed as read.

## 8. Items to file

- **W46.kit-mac-build** (exists, [S], blocked on W46.review-done): build, hash and measure the Mac model; fills the
  student row's Mac figures from the kit's own warm-up. Done: manifest written beside the Mac build with its hash and `mac`.
- **W46.kit-gate-rule** [S], no blocker (call 7.2 decided): `train_seg.py check` enforces the minimum known-gap count,
  two scored runs and the 3.2-point anchor margin; synthetic regressions for a tiny-support pass. $0.
- **W46.kit-sherlock-profile** [S], waits on the account (`STATE.md`): `profiles/sherlock.json`, the containerised
  scorer for the gate (H open question 7).
- **W46.kit-licence-statement** [S], no blocker (call 7.3 decided): README section and a manifest `licence` field shown
  by the range view; the wording the owner's at ship time.
- **W46.kit-hands-check** [M], no blocker (14-owner-calls.md call 7): a per-hand held-out acceptance check and a
  manifest for the handwriting fine-tune (none exists [I]); and the line-correction screen it needs, built in this
  release, filed with stage 04's queue.
- **W46.kit-corrections-store** [S], with note 07: corrected gaps and lines kept in the review records (call 7.5
  decided) in a form a kit run can read.
- **Gaps the table needs** (`12-settings-design.md` §3.9): the seg students' training wall time on one GPU (not in the
  files read); Mac memory and seconds for a continuation loaded as an adapter (unmeasured); a gate held-out size measured
  on non-owner material; the kraken port's licence [?]; a second hand for the fine-tune curve; a 32 GB Mac LoRA step
  (hardware-blocked, gap audit owner question 4).

## 9. Profile test expectations

Each expectation is what the solver shows, given the fine-tuning answer; no profile gets an after-training row as its
default pick.

- **Laptop 16 GB, open weights, answer "no".** No row shown. Segmentation stays the shipped 2B (stage 07; 4.4 GB peak,
  `seg-students.md`).
- **Laptop 16 GB, "with a coding agent".** Handwritten kind: `kit-hands-ppocrv6-ft` shown as an after-training point only
  where stage 04 has chosen kraken on blla lines, with "+2.50 at 160 lines on one hand"; hidden below 80 corrected lines.
  `kit-seg-lora-mac` shown as not offered ("not measured to fit"). Typed, printed and other kinds: nothing.
- **Laptop 32 GB and 64 GB, "with a coding agent".** As 16 GB: the Mac LoRA row stays not offered, because 32 GB is
  unmeasured (`kit-mac-lora.md`), not because it failed.
- **Cheap API; premium APIs or plans, answer "no".** No row. With "with a coding agent": only the hands row, and only if
  the user's handwritten route is kraken; the cloud readers lead it on the owner's hands (stage 04).
- **A cluster, answer "on a cluster".** All kinds' segmentation: `kit-seg-student-tags` shown when the corpus has tags or
  per-document folders, with Sasha 89.1% gap accuracy and the TABME++ caveat; `seg-2b-lora-k200` shown after 200
  corrected gaps of one material, with box 2's 17.2 to 4.9 errors per 100 gaps, the lost-start caveat and the label
  "measured on one material". Neither
  becomes selectable until a manifest that passed is beside the Mac build; before W46.kit-mac-build lands, the solver
  shows them as "needs the Mac build step".
- **Any profile plus a coding agent and a cluster.** The union of the two cases above; the fallback for any failed window
  is the shipped 2B, and for a failed line the untuned recogniser.

## Owner's calls (2026-11-06)

From 14-owner-calls.md. The owner's own call bearing on this stage:
- **Call 7, the kit's scope in this release.** The cluster kit ships: the student from the user's tags, and the
  continuation (`seg-2b-lora-k200`) once 200 corrected gaps of one material exist, flagging kept on, labelled measured on
  one material, every model past the gate; W46.kit-mac-build before it ships. No Mac segmentation LoRA
  (`kit-seg-lora-mac` stays a not-offered row). The handwriting fine-tune also ships: a line-correction screen is built
  in this release, and kraken PP-OCRv6 is offered from 80 corrected lines with 160 as the target, on the handwritten
  kind. Calls 7.1 and 7.4 above are decided by it; section 3's floors stand as written.

Picks the session took on this note's recommendations (section 2, owner may veto): the gate is gap accuracy against the
shipped 2B with a checker-enforced minimum known-gap count from the measured "needed" column, two scored runs, and an
anchor margin of 3.2 points (the rerun floor's top) on the public anchor; the licence statement goes in the kit README
and a manifest `licence` field the range view shows, wording the owner's at ship time; corrections for the continuation
live in the review records and the next box of the same material is the held-out set; "with a coding agent" means
Mac-side steps and "on a cluster" adds the cluster rows. Section 3 amends the tie rule to match: no gap-accuracy rerun
floor exists, so the paired interval and the minimum support decide; the handwriting tie uses kraken's floor of 0.

Files read: execution-plans/processing-review/00-plan.md (1-105); 13-stage-rules/00-index.md and 14-owner-calls.md (worktree
suite-wt-20261106-205546-44529); H-corpus.md §5, §6.3, §7, §8, §9; 10-gap-audit.md (stage 10 table, owner questions,
§7); 12-settings-design.md (§3.1, §3.9, §5); 11-measurement-audit.md SEG-5, SEG-6 and kit lines; measure-reviews
2026-10-31-2.md (P2-1 to P2-4), 2026-10-31-3.md (§3 kit gate), 2026-11-01.md (P4-2), 2026-11-02.md, 2026-11-03.md
(P6-4, P6-2), 2026-11-04.md (P7-5), 2026-11-04-2.md, 2026-11-05.md (P9-8, P9-12), 2026-11-05-2.md (P10-10);
ArchiveProcessor/segbench-results/seg-kit-gate.md, seg-kit-gate-sherlock.md, seg-boxes-score.md (support, Noise), seg-students.md, seg-teacher.md,
seg-adapt-lora.md, seg-adapt-curve.md (findings and the first tables), kit-mac-lora.md, seg-tabme.md,
ocr-ppocrv6-hands.md, ocr-ppocrv6-hands-paid.md, ocr-ppocrv6-hands-qwen.md (opening); ArchiveProcessor/scripts/segbench/
institutional-compute/README.md and profiles/; SUITE_TODO.md (W46.kit-mac-build, W46.review-phase4); STATE.md line 26.
