# 14. The owner's calls, Phase 4 (2026-11-06, interactive)

Walked one at a time in the owner-started session, after the twelve rule notes were drafted. Calls the figures settle,
and technical picks taken on the notes' recommendations, are listed in section 2 for the owner's veto; the owner's own
calls are section 1.

## 1. The owner's calls

1. **Where a collection's settings live.** Beside the collection's output folder, as the design proposed (§3.5), written
   by the Processor from the settings build; the general layer in the app's own store; resolved settings frozen into each
   run's record. The Reader and Notes reading the document is filed as its own item behind the settings build, not part
   of it.
2. **The two limits the design dropped from the integration plan.** A per-batch switch "this batch stays on the Mac"
   is added, hiding every route that leaves the Mac (for sensitive material; without it a user with keys for other work
   would have to remove them or override every card). No quality floor: the preference stands in for it, and each stage
   card names what a better figure would need. Integration plan decision 4 is superseded accordingly.
3. **What a user who skips both interviews gets.** "Free, on this Mac", always: detected keys and plans are shown on the
   sheet but nothing is spent until the user picks a route or a starting point (the design's §3.7 proposal to fill "A few
   dollars, overnight" when a key is detected is not taken). Default priority order reading, finding documents, dates,
   names (stage weights 45/30/15/10, the prototype's); the mixed-page switch off until its time cost is measured like
   for like (P11-4).
4. **The free default's reader per kind (note 04, call 7.1).** Typed and printed pages read at once with Apple Vision.
   Handwritten pages: on a 16 GB Mac the sheet proposes LightOnOCR-3 4B 8-bit as a download; a user who declines, or a
   smaller Mac, gets them flagged "needs a download or a key" rather than read at about 60. A page Vision returns empty
   for is flagged, never skipped, on every profile.
5. **The failure cascade (notes 04 call 7.2 and 10 call 2).** A route like any other: each measured cascade is a row
   with its own figures on the reading chart, and the solver picks it when it beats the single routes within the user's
   limits. No separate on/off default; failure is the only trigger; the Vision word-count trigger stays opt-in. Note 04's
   "on whenever a second route exists" and note 10's "no default beyond off" are both superseded by this.
6. **What may touch the reading copy (notes 01 calls 2-3, 02 C2, 05 call 2, 06 call 3).** Straightening (deskew above
   a 1 degree median line angle) on by default, switchable off. Dewarping is not offered: UVDoc removes content (900 of
   15,067 lines on Real5; a loss on the owner's pages), and no per-page guard exists; a guarded dewarp is filed to revisit.
   Shading division is not offered for viewing: it greys coloured marks by about a fifth and helps no reader. Note 06's
   "may be offered for viewing" is withdrawn.
7. **The training kit's scope in this release (notes 12 calls 7.1 and 7.4, 07 call 1).** The cluster kit ships: the
   student from the user's tags, and the continuation once 200 corrected gaps of one material exist ("adaptation after
   about 200 corrections, flagging kept on", labelled measured on one material), every model past the gate; the Mac step
   (W46.kit-mac-build) before it ships. No Mac segmentation LoRA (not measured to fit). The handwriting fine-tune also
   ships: a line-correction screen is built in this release, and kraken PP-OCRv6 is offered from 80 corrected lines with
   160 as the target, on the handwritten kind.
8. **The Gemini 3.8 Flash offsets on the personal key, about $2.60 (note 07 call 4; pass 7).** Declined. No personal-key
   spend; Gemini 3.8 Flash stays the app's segmentation default, and its card shows Gemini 3.7's measured range labelled
   as 3.7's, with the single 3.8 run shown as a single run. The Sasha lead over the 2B stands on the 3.7 card only.
9. **How a non-explicit date appears (note 08 calls 7.1, 7.2, 7.6).** Second-role dates (received stamps, postmarks,
   filing dates) go in the document's JSON sidecar with role, quote and place, never as a second bare year; no SPEC
   change. Every non-explicit date shows its evidence class and the cited quote with its place; the 90% conformal
   interval appears only on routes where it was measured, in the sidecar and the PDF header. An estimate that fails the
   evidence check is not shown at all until the checker's false refusals are fixed (item 8.3).
10. **The names the tagging prompt writes (note 09 calls 1 and 6).** Both provisional rules (person-only sender,
    heading-or-address place; 4cdbba41, 4374254d) move to the entity feature's own prompt and the tagging prompt is
    reverted to its pre-November name behaviour; the entity feature decides them with its own measured prompt. A name the
    page does not show may be written when marked inferred, as Date Uncertain is accepted for years.
11. **When entities run, and the export (note 09 calls 3 and 4).** On a cloud route names are extracted always (they
    come with the call at no cost) and shown when the collection interview ranks names; on the Mac the local extractor
    runs only when names are ranked, on typed and printed correspondence, the sender never taken from Vision text
    (ent-robust rule), the 4B not offered. No export format until a user asks; CMIF against CSV goes to
    POTENTIAL_FEATURES, not the queue.

## 2. Settled by the figures, or decided by the session on the notes' recommendations (owner may veto)

Each is a table default or a filed item, reversible without app work; the figures and files are in the note named.

- **Rotation (note 01 call 1, W46.rotation-default):** the agreement rule per profile: free "Vision checked by PP-LCNet,
  else flag" (5 of 119 held-out pages wrong, 14 flagged); cloud "agree, else llmSingle" on the gateway only until a
  direct-key model is measured (P9-3); llmSingle on every page for charters and non-Latin scripts. The five set-apart
  pages are shown to the owner in a later sheet, about a minute (P10-7). Deskew's 1 degree trigger stands.
- **OCR input (note 02 C1):** no enhancement for any route, stated for the five readers measured; a small-reader power
  test filed, not run.
- **Layout (note 03 calls 1-5):** PP-DocLayoutV3 regions on newspapers for every reader (the gain is nil, not negative,
  for large readers on 15 pages); everything else whole page; never on handwriting or registers; the cluster "regions
  first for small readers" lives as a kind rule on note 04's cluster rows; the PP-DocLayoutV3 against DocLayout-YOLO
  pair test on L9 filed.
- **Placement (note 05 calls 1 and 3):** aligned lines on handwriting, default on, gate at 0.67 as filed; the hand line
  detector is a visible setting on the cluster profile only (PP-OCRv6 det needs 32 GB on the Mac CPU); its own peak
  memory and alignment time measured by a filed item before the 16 GB claim is made.
- **Marks (note 06):** no layer offered; the two-pass route described, behind W46.marks-detect-own (nice-to-have, as the
  owner set on 2026-11-06); region routes must keep picture regions (7 of 45 marks kept by the app's filter against 26).
- **Reading (note 04 calls 7.3-7.7):** hands routes ranked on the public L1-L3 where both figures exist, hands16
  otherwise, every hands figure labelled (OCR-1): LightOnOCR-3 4B on the Mac, Gemini 3.8 Flash on an API labelled
  "conditional on the truth", Infinity-Parser2-Pro on a cluster pending its pair. Loop fallback: a second VLM reader
  first where installed, kraken PP-OCRv6 on Latin lines where none, never a half-size retry on the cluster; a solver
  setting, not a measured optimum (18 pages). Public strata shown per row for the run that read them; a Mac row may show
  its cluster twin's figures only for the same weights and precision. 32 and 64 GB Macs pick from the 16 GB rows until a
  Mac measurement of a 27B-class reader exists (filed). Ties judged against the best feasible route only, faster wins
  among equal cost; no chaining. The ChatGPT plan has no OCR row (unmeasured; filed).
- **Segmentation (note 07 calls 2, 3, 5-8):** the text-only cloud window is filed as a test-box run on the gateway
  (about $1.30) before any tier is offered; the review rule is disagreement with a second model for the 2B when a partner
  is feasible, own confidence otherwise and for the cloud routes; the magazine kind is shown with "ranks nothing yet"
  until W46.seg-magazine-rule-redo; the 20 s checking-time assumption is kept, labelled, with a timing measure filed for
  an owner session after the redo; the 2B is offered to every 16 GB Mac with no key with a zero-shot card and the
  manuscript warning, and as an optional disagreement partner beside a cloud voter; the tie threshold is 3.2 points,
  the top of the rerun floor, until a measured range exists.
- **Dating (note 08 calls 7.3-7.5):** the image pass runs only where the app's own text gives no year candidate (its
  whole cost would otherwise apply to every document); the trained 2B and 4B are not dating defaults; the no-key laptop
  route is Vision text, rules, the 2B chooser and propagation at t=3, every propagated year Date Uncertain with its
  source document, the Mac 8B image pass added at 16 GB once item 8.1 shows its quotes help.
- **Entities (note 09 calls 2 and 5):** the inside-address and non-correspondence-date tests filed (offline, cached text);
  the Mac extractor under the ent-robust rule, the 4B not offered.
- **Kinds (note 10 calls 1, 3-5):** one mixed switch acting on every typed or printed page, wording "measured level on
  typed pages, not measured on mixed pages", Mac time "figure pending" until timed like for like (P11-4), off by default
  (call 3 above); the mix shown with its sample size and the classifier's error (137 of 141; 723 of 895) and pages under
  the 0.8 floor shown as unsure; kinds the classifier does not measure (clippings, newspapers, registers, mixed) asked in
  the interview labelled "not measured"; ATRIUM's licence conflict noted, moot while the shipped classifier is kept.
- **Capture (note 11 calls 1-3):** static guidance only until a sharpness cut is validated on real captures (the
  in-sample cuts false-alarm on 17-34% of good pages); flash off, raw original kept, no on-phone processing; the Android
  and iOS quality settings wait on a device read; 2,048 px at JPEG 0.85 stands as measured (`enh-dewarp.md` §"The app's encoding": Vision +0.5, Qwen3.6-27B -0.3, LightOnOCR -0.4,
  PP-OCRv6 +0.8, Gemini -0.1), so no encoding test is filed.
- **Kit (note 12 calls 7.2, 7.3, 7.5, 7.6):** the gate is gap accuracy against the shipped 2B with a checker-enforced
  minimum known-gap count from the measured "needed" column, two scored runs, and an anchor margin of 3.2 points (the
  rerun floor's top) on the public anchor; the licence statement goes in the kit README and a manifest `licence` field the
  range view shows, wording the owner's at ship time; corrections for the continuation live in the review records, the
  next box of the same material is the held-out set; "with a coding agent" means Mac-side steps, "on a cluster" adds the
  cluster rows.
- **Design (12-settings-design.md):** figures shown as points with sample size and the tie rule, as the design session
  decided; the solver's memory headroom stays 5 GB over the measured peak until a measurement says otherwise.
