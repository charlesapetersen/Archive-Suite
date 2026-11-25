# Archive Processor — Pipeline Pruning & Simplification Decision Pack (`W49.proc-pipeline-prune`)

**Date:** 2026-11-24 · **Gate:** `W49.proc-pipeline-prune-ok` (HOLD QUEUE)  
**Rule respected:** Owner Call 13 (2026-11-18) — nothing is removed, hidden, or downgraded by this pack; every change below awaits your explicit call.

This pack puts **six concrete pipeline simplifications** to you in plain language, each with the measured numbers behind it, what happens today, the concrete options and trade-offs, and a clear recommendation.

---

## Decision 1: Handwriting text placement (`hand-blla-ctc` kraken + PyTorch placer)

- **What happens today:** For every handwritten page, Processor writes a **separate text page** (page 2 of the pair) *and*, when "Also place handwritten text on the page image" is on (the current default), runs a separate Python/PyTorch/kraken + McCATMuS alignment pipeline on the Mac (`VisionOCRKit/HandPlacer.swift`) to try to lay an invisible text layer over the handwriting image as well.
- **What was decided before:** On 2026-10-20 you preferred text placed on the image unless a text page is necessary; on 2026-11-17 you raised the confidence gate from `0.67` to `0.90` based on the line-pass table (`05-placement.md` §3–4).
- **What the numbers actually show:**
  - Runtime cost: **7.52 s/page median** (`9.0 s` mean, up to `17.5 s` max) and up to **8.51 GB peak RAM** (`4.39–4.64 GB` single page/MPS, unbounded growth over 60 pages on CPU), plus a separate Python/PyTorch/kraken runtime download and maintenance surface (`place-hands-cost.md`).
  - Payoff on the owner's 20 handwritten pages: at the `0.90` gate, the layer is kept on only **9 of 20 pages (45%)**, passing **55.3% (110/199)** of lines on those kept pages (**42.9% overall**; **35.7%** on Bentham). It fails on reflowing readers (LightOnOCR-3: `21.5%`), and **every handwritten page already gets a complete, searchable, copyable text page either way**.
- **Options:**
  1. **Option A (Recommended) — Default handwritten pages to the clean text page only; move `hand-blla-ctc` to 2.0 (or remove the Python/kraken runtime from 1.0).** Saves ~6–8 GB RAM pressure, removes an entire Python/PyTorch runtime, speeds up handwritten batches dramatically, and still gives 100% searchable/copyable text on page 2.
  2. **Option B — Keep `hand-blla-ctc` as an opt-in Advanced download (default OFF).** Preserves selectable-on-image handwriting for the ~45% of pages that pass `0.90` for users who explicitly want it, without burdening default runs.
  3. **Option C — Keep as today (default ON).** Every handwritten page pays 7.5–17.5 s and Python/PyTorch setup for a partial layer on fewer than half of pages.
- **What priority would favour another option:** If selecting words directly on top of cursive images in Preview/Reader is essential for your workflow even when it only works on ~45% of pages and ~55% of lines on those pages, pick **Option B** (or C).

---

## Decision 2: Per-kind OCR routing on cloud routes & the mixed-page switch

- **What happens today:** Processor bundles a Core ML page-kind classifier (`PageKindClassifier.swift`, `0.6 s/page` via Apple Vision) to route each page (typed, printed, handwritten, form) to a different OCR model, plus a **"Read handwriting on typed pages"** (mixed-page) switch that sends typed/printed pages to a handwriting reader.
- **What was decided before:** Built in `W41.app-page-kind` and `W46.mixed-route-setting` (default OFF); kept as an optional switch in Phase 4 (`10-kinds-and-routing.md`).
- **What the numbers actually show:**
  - **Per-kind routing (`10-kinds-and-routing.md` §3):** On the owner's 96 pages, even a perfect oracle classifier only reaches `97.26` NES vs. `96.47` for the best single cloud reader (`+0.79` pts). Routing with the **actual shipped classifier scores `96.26` — `0.21` points *worse* than just using one strong cloud reader**. Outside modern English, classifier accuracy drops to `21/80` (early modern hands L5), `7/40` (Hebrew N4), `14/40` (Devanagari N6), and misclassifies `80/80` registers (L4) as handwritten.
  - **Where per-kind routing *does* help:** Only on the **free Mac profile** (sending typed/printed pages to fast `0.19 s` Apple Vision and only handwritten pages to a slower local VLM like LightOnOCR-3 or Gemma 3 12B).
  - **Mixed-page switch (`10-kinds-and-routing.md` §5 P11-4, P18-5):** Unmeasured on actual mixed pages (`n = 2`, `-12.1 [-20.7, -3.6]` is anecdote), slows Mac reading **140×** (`25.5 s` vs. `0.17 s/page`), and Pass 18 confirmed ATRIUM's standalone numbers do not measure the live switch's traffic or accuracy.
- **Options:**
  1. **Option A (Recommended) — Use page-kind routing ONLY for the free Mac split (Apple Vision on typed/printed, local VLM on handwritten); on cloud/cluster routes use one strong reader per batch and drop the mixed-page switch until 2.0 (`W46.kinds-mixed-truth`).** Simplifies Settings, removes a negative-gain cloud complexity, and keeps the one place where kind routing actually saves massive time (Mac Vision vs. local VLM).
  2. **Option B — Keep per-kind cloud routing and the mixed-page switch as Advanced-only opt-ins.** Preserves every toggle at the cost of carrying the classifier/ATRIUM/tag-precedence plumbing in Advanced Settings.
- **What priority would favour another option:** If you want to mix a cheap cloud reader for typed pages with an expensive cloud reader for handwritten pages on very large paid batches, pick **Option B**.

---

## Decision 3: Prune the 91 unwired (`app_route: null`) routes from the app's runtime `settings-routes.json`

- **What happens today:** `ArchiveProcessor/segbench-results/settings-routes.json` is `347 KB` with **119 route rows** across 12 stages. Verified directly against the file: only **37** have `status: "shipped"`, only **28** have a non-null `app_route` that Processor can actually execute, **91 have `app_route: null`**, and **35** have `time.measured: false`.
- **What was decided before:** The Nov 4 prototype included bench-only routes to show "what a better figure would need" (hollow marks on Pareto charts).
- **Why this matters now:** Keeping 91 unrunnable bench rows inside the shipping app's runtime solver inflates Settings copy, produces confusing "measured elsewhere, not runnable here" caveats, and forces the app to carry bench maintenance debt (Pass 18 P18-4, P18-6). Every single measured route is already published and charted on **ArchiveOCRBench** (the bench website).
- **Options:**
  1. **Option A (Recommended) — Keep all 119 rows on ArchiveOCRBench, but restrict the app's bundled `settings-routes.json` to runnable app routes (plus the small set of downloadable/cluster routes the app actually supports).** Cuts solver/UI clutter dramatically while preserving 100% of the scientific record on ArchiveOCRBench.
  2. **Option B — Keep all 119 rows in the app's bundle so "What a better figure would need" can cite unshipped bench routes.**
- **What priority would favour another option:** If you want Processor's Settings window itself (rather than the ArchiveOCRBench website) to serve as a research leaderboard of models the app does not run, pick **Option B**.

---

## Decision 4: Unify the contradictory tie rules across Reading (Stage 04) and Segmentation (Stage 07)

- **What happens today:** The solver uses **opposite statistical rules** in the two biggest stages:
  - **Reading (`04-reading.md` §3):** Uses **rerun floor only, ignoring 95% confidence intervals** (owner 2026-11-11). For deterministic local Mac models the rerun floor is `0.00` pts — meaning a `0.01`-pt difference on 96 pages "separates" two Mac models even when the sampling uncertainty is ±2–4 pts.
  - **Segmentation (`07-segmentation.md` §3, P16-1):** Does the **exact opposite** — uses **paired 95% CIs holding 0** (`39/55` pairs tie on 2 boxes) while **ignoring the measured `1.4–3.2`-pt student rerun floor** (owner 2026-11-18). Including that floor makes `51/55` pairs tie and flips 5 profile picks to the free local 2B.
- **Why this matters now:** Two stages inside the same Settings solver contradict each other on what "a real difference" means, causing false precision on local Mac OCR picks and inconsistent tie-breaking.
- **Options:**
  1. **Option A (Recommended) — One consistent rule across all stages: two routes tie unless (a) the paired 95% CI clears zero *or* the gap clears a sensible practical floor (e.g. `0.5` NES pts for Reading, `2.0` pts for Segmentation) — and never treat `0.01` pts on 96 pages as a real win.** When routes tie, prefer the cheaper, then faster route.
  2. **Option B — Keep today's split rules (Reading floor-only with `0.00` local floor; Segmentation CI-only without rerun floor).**
- **What priority would favour another option:** If you prefer every deterministic Mac OCR model to rank strictly by its raw 96-page point score regardless of sample noise, pick **Option B**.

---

## Decision 5: Fix US-only numeric date parsing and owner-corpus prompt priors (`prompts.md`)

- **What happens today:**
  - `08-dating.md` §3 specifies: *"A numeric date reads month-first when its first part can be a month"* — so `04/07/1962` is silently parsed as **April 7** even in UK, European, Commonwealth, or Latin American archives where it means **July 4**.
  - `ArchiveProcessor/prompts.md` hardcodes US/owner-specific examples (`"Joel Dean Papers"`, `"Deaver and Hannaford"`, `"Baker Library"`, `"Hoover Institution"`, `"Democratic Party"`, `"City, State"`), and the item-fields prompt (`prompts.md:380`) still opens with *"You are labelling catalogue fields for a test set built from a historical archive."*
- **Why this matters now:** You want Archive Suite to be genuinely usable by other historians, not just on 20th-century US correspondence.
- **Options:**
  1. **Option A (Recommended) — Add a simple collection-level date-order setting (`MM/DD` US default vs. `DD/MM` International, or `Auto/Ambiguous -> Year+Month Uncertain` when day ≤ 12) and neutralize the owner-specific examples in `prompts.md` during `W49.proc-metadata-consolidate`.** Zero cost, avoids silent date corruption for non-US historians.
  2. **Option B — Keep US month-first and current prompts for 1.0, deferring international date order to 1.1.**
- **What priority would favour another option:** Only pick **Option B** if you want zero prompt changes before 1.0 ships.

---

## Decision 6: Newspaper read-poorly flags (`n = 15` single-collection scans) & direct-key rotation models (`W46.rotation-direct-keys`)

- **What happens today:**
  - **Newspaper read-poorly flags (`W49.proc-read-flag-newspaper-app`, `W49.proc-read-flag-newspaper-whole-app`):** Both cutoffs (`0.45` regions, `0.20` 9-tile) were fitted on **15 newspaper scans** (14 from one Library of Congress collection, **0 photographed newspapers**). Pass 18 (P18-1) also found that **Qwen3.6 27B** (the app's designated whole-page newspaper reader) was never actually tested against the 9-tile partner, and the region/tile checks add ~2 s/page of Vision work.
  - **Direct-key rotation (`W46.rotation-direct-keys`):** `LLMRotationDetector` sends direct-key rotation fallbacks to `gemini-2.5-flash-lite`, `gpt-5.4-mini`, or `claude-sonnet-4-6`, none of which were ever measured (only gateway `gemini-3.7-flash` was measured, P9-3).
- **Options:**
  1. **Option A (Recommended) — Defer both newspaper read-poorly flag items to 1.1 (after `W46.newspaper-photo-truth` lands on Dec 1 so we have photographed newspapers too), and for rotation keep Vision + PP-LCNet local agreement as default with fallback to the user's configured OCR model (retiring `W46.rotation-direct-keys`).** Avoids shipping `n = 15` overfitted scan thresholds and eliminates a separate unmeasured rotation-model list.
  2. **Option B — Ship the two scan-only newspaper flags in 1.0 (labelled "scanned newspapers only, n=15") and keep `W46.rotation-direct-keys` in 1.1.**
- **What priority would favour another option:** If you plan to process large batches of scanned (not photographed) newspapers in 1.0 and want an automatic read-poorly flag immediately despite the small calibration set, pick **Option B**.

---

## Summary Table (Quick Picks for `W49.proc-pipeline-prune-ok`)

| # | Area | Recommendation | Impact if Adopted |
|---|---|---|---|
| 1 | Handwriting placer (`hand-blla-ctc`) | **Option A** (clean text page only in 1.0; defer kraken/PyTorch to 2.0) | Drops 8.5 GB Python/PyTorch runtime; 7–17 s/page faster |
| 2 | Per-kind cloud routing & mixed switch | **Option A** (keep Vision/VLM split on Mac only; 1 reader on cloud; defer mixed switch) | Removes −0.21 pt complexity & 140× unmeasured switch |
| 3 | 91 unwired `settings-routes.json` rows | **Option A** (keep on ArchiveOCRBench; bundle only runnable routes in app) | Shrinks Settings/solver clutter sharply |
| 4 | Contradictory Reading vs. Segmentation tie rules | **Option A** (one consistent CI + practical-floor rule) | Stops 0.01-pt noise picks on Mac OCR |
| 5 | US-only dates & owner prompts | **Option A** (date-order option + neutral prompts in `W49.proc-metadata-consolidate`) | Safe for non-US archives |
| 6 | Newspaper flags (`n=15`) & direct-key rotation | **Option A** (defer newspaper flags to 1.1; fallback rotation to active OCR model) | Avoids shipping uncalibrated `n=15` thresholds |

---

## Locked Owner Decisions (2026-11-24 — `W49.proc-pipeline-prune-ok`)

1. **Handwriting text placement (`hand-blla-ctc`):** **Option B** — keep as an opt-in Advanced on-demand download, **default OFF** (clean text page is default in 1.0).
2. **Per-kind OCR routing & mixed-page switch:** **Option A1** — simplify to one clean **2-way split (Typed/Printed vs. Handwriting)** for both Mac and Cloud cost-saving; drop the 4-way per-kind matrix; defer the mixed-page switch to 2.0 (`W46.kinds-mixed-truth`).
3. **Unwired (`app_route: null`) routes:** **Option A** — bundle only runnable/supported app routes in the app's runtime `settings-routes.json`; keep all 119 rows on ArchiveOCRBench.
4. **Solver tie rules:** **Option A1** — **practical-floor-only** across both Reading (`0.5` NES pts for both cloud and local) and Segmentation (`2.0` pts); display 95% CIs honestly without letting underpowered CIs force ties onto weaker models.
5. **Numeric date order & owner-corpus prompts:** **Option A** — add a collection-level date-order setting (`MM/DD` US default vs. `DD/MM` International) and neutralize owner-specific prompt examples in `ArchiveProcessor/prompts.md` during `W49.proc-metadata-consolidate`.
6. **Newspaper read-poorly flags & direct-key rotation:** **Option A** — defer `W49.proc-read-flag-newspaper-app` and `W49.proc-read-flag-newspaper-whole-app` to 1.1 (`W46.nice-to-have`); keep Vision + PP-LCNet local agreement for rotation with fallback to the user's configured OCR model, retiring `W46.rotation-direct-keys`.
