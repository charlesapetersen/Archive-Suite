# 08. Dating (strand B)

Draft for Phase 4, 2026-11-06. Unit: documents. Figures are copied from the named files; [M] measured, [I] inferred,
[?] unverified. Nothing here is recomputed; where a later pass corrected a figure, the corrected form and the pass id
are given.

## 1. Stage and question

The stage gives each document a year and, where the document states it, a month and day, and marks every date that is
not on the document itself with `Date Uncertain` and the evidence it rests on. The user chooses which model reads the
dates (text call, image pass, neighbour estimate) and so what it costs; the order of the steps and the rule for
`Date Uncertain` are fixed by the owner's traceable-dating rule (`00-plan.md`, "Owner decisions", 2026-10-20).

## 2. Is there a choice?

Yes. The routes are in section 4. What the user chooses is the model behind each step; the steps, the evidence each
must carry and when `Date Uncertain` is written are the stage rule below and do not vary by route.

## 3. The rule for the settings layer

**What the sheet shows.** "Dates come from the document first: its own text, then the page image for dates the text
missed. A document with no date of its own takes the date of a dated covering letter or a dated folder when that link
is known, and otherwise a year estimated from its neighbours, marked Date Uncertain, with the neighbour and the words
it rests on. A guess with no evidence is never written."

**The steps, in order** (DAT-1's fix: an image pass first, then neighbour estimation on what is left):

1. *Explicit, from the text.* The tagging call on the app's own OCR text, with the three neighbouring segments the app
   already sends. A year is explicit when a rule candidate (four-digit years 1800-2030, month and numeric forms; the
   rule stage of `date_traceable.py`, 0.38 ms a document [M]) carries it in the document's own text. No `Date
   Uncertain`. Evidence: the quoted string and its line.
2. *Explicit, from the image.* On documents whose own OCR text gives no year candidate, the image pass: the page
   images of the first two pages, the reply quoting every date, its kind and its place, and naming the document's own
   date (`date-image.md`). A year written in a quoted date is explicit: no `Date Uncertain`; evidence the quote and its
   place. It runs only on documents with no year candidate in the app's own text (call 7.3, decided 2026-11-06).
3. *Inherited.* (a) An enclosure whose covering letter is established as such takes `Sent With <cover's own date>`
   and the cover's year with `Date Uncertain`, as `EnclosureDates` and `SPEC/tag-format.md` already do; an uncertain
   relation writes `Sent With Date Uncertain`. Today the only signal is the OCR prompt's `[enclosure]` marker, which
   is close to inert (section 5, B-enc). No new relation stage is added. (b) A dated folder photo dates the otherwise
   undated documents in its run: this is the fold-in point for `W47.ct-folder-date` (owner, 2026-10-31), not
   designed here; its open questions (the tag a range becomes, whether `Date Uncertain` is kept, the month) go to the
   owner at `W47.ct-design-ok`. A document's own date always wins over either inheritance.
4. *Estimated from neighbours, on what is left.* The trace prompt with neighbour dates (`trace-neigh`): the reply names
   the year, the cited neighbouring document and a quote from it, and a 90% interval. It is written only when the
   evidence check passes (`date_scorers.evidence_check`: the cited neighbour is in the context, the quote is a
   substring of its text and carries the year), and always with `Date Uncertain`. A reply whose evidence fails is not
   written as a date (owner rule: "an untraceable guess is not acceptable"), and is not shown as a suggestion either
   until item 8.3 fixes the checker's false refusals (owner call 9, 2026-11-06). On routes with no model for this step, propagation is the estimate: the year of the nearest earlier
   document printing one, at most three documents back (t=3), with that document as the evidence and `Date
   Uncertain`.
5. *Not used.* Typeface or paper dating (DAT-4: 11 of 12 ranges contain the year at a median width of 50 years,
   `date-image-typeface.md`) and look-alike retrieval (27 exact of 122 against 52 for the nearest dated document
   before, `date-image.md`) are not steps.

**`Date Uncertain` is set by the evidence class, never by the model's flag.** Explicit (steps 1-2): off. Inherited
from a cover (step 3a) and estimated (step 4): on. Inherited from a dated folder (step 3b): left to
`W47.ct-folder-date`, whose open question at `W47.ct-design-ok` is whether an inherited date keeps the flag
(`SUITE_TODO.md`). Measured reason: the model's own flag errs both ways. Gemini 3.8 Flash flags 31.5%
(63/200) of owner-certain years uncertain and leaves 12.0% (6/50) of owner-uncertain ones unflagged; on the
owner-certain years not in the text it flags 69.8% (60/86) (`date-truth.md`) [M], largely the definitional mismatch
DAT-7 names. The trained 2B and 4B flag none of the 50 owner-uncertain documents (`date-model.md`) [M]. On undated
documents the app writes a year on 90 of 90 and `Date Uncertain` on 49% (44/90) (`date-undated.md`) [M]; a year
without the flag and without a date on the page is the false year this rule removes by construction [I]. DAT-7's own
measure, the flag against "a date is on the document's own pages" from the image pass, agrees on 82% (174/212; 76-87)
of both sets, and on 70% (14/20; 48-85) of the owner-ruled sheet, an enriched audit rather than a population accuracy
(pass 3) (`date-undated.md`) [M].

**What a non-explicit date shows** (owner call 9). Its evidence class and the cited quote with its place, on every
route; the 90% conformal interval only on routes where it was measured, in the sidecar and the PDF header, with the tag
contract unchanged. Second-role dates (received stamps, postmarks, filing dates) go in the document's JSON sidecar with
role, quote and place, never as a second bare year.

**Comparison metric and tie rule.** Metric: exact year on documents whose year is not in the text (`not in text`),
among routes whose non-explicit years carry checked evidence; the second metric is exact year where the year is in the
text. Tie: a gap no larger than the rerun floor, the same year on 94% (85/90) of documents between two identical runs
(`date-undated.md`, "Rerun"; the floor `date-tagging.md`'s card adopts as a guide), is a tie; that floor is a
same-year agreement rate, not a gap in points, so reading it as a points threshold is [I]. A paired gap is also a tie when its
discordant pairs give no sign-test difference (DAT-3: 52 against 48, discordant 6 against 2, p about 0.29) [M].
A tie goes to the route whose non-explicit years carry evidence, then to the cheaper.

**Kind rules.** The stage scores apart: year in the text, year only on the page, enclosure, undated, decade-tagged. It
does not score document kinds (typed, handwritten, printed); no per-kind dating figure exists, and handwritten dates
are 10 of the 56 Gemini found on the page (`date-image.md`), a share DAT-2 calls weakened. A bound magazine issue is its
own relation, not a cover with enclosures (`date-truth-sets.md`); its articles take the issue's date from the cover or
contents page (STATE.md, Illustrated Review ruling, 2026-10-29). A relation never crosses a box or folder label
(`B-dating.md` §2).

**Fallback.** When the chosen route's reply cannot be parsed, the app writes no year and `Date Uncertain`
(`date-tagging.md`, built-in behaviour); the rule stage's explicit year, if any, stands. When the image pass fails, the
document goes on to step 4.

**When the stage must not run.** On box and folder label segments as documents (they are inputs to step 3b), and when
the user turns dating off (the `none` row).

## 4. Table rows

The draft rows in `settings-design/figures.json` ("date") are replaced, for four reasons recorded in section 5 (F-1 to
F-4). `not in text` figures are on the 131 ABBYY-defined documents unless named `unprinted-122` (the 122 of them with a
JPEG original) or `reread-107` (the 107 whose year neither the ABBYY nor the Vision text prints).

```json
[
 {"id": "gemini3.8-flash-oneshot", "name": "Gemini 3.8 Flash, the app's tagging call", "family": "cloud",
  "app_route": "gemini|gemini-3.8-flash", "status": "shipped", "step": [1],
  "needs": {"key": ["gemini", "openrouter"], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "in_text": {"value": 97.5, "n": 119, "truth": "owner-tags", "source": {"file": "segbench-results/date-tagging.md", "route": "gemini-3.8-flash", "attribute": "year exact, year in text yes", "value": "97.5% (116/119)"}},
   "not_in_text": {"value": 63.4, "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-tagging.md", "route": "gemini-3.8-flash", "attribute": "year exact, year in text no", "value": "63.4% (83/131)"}},
   "reread_107": {"value": 61.7, "n": 107, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "gemini-3.8-flash (corpus text)", "attribute": "not in text, classes re-read with Vision text", "value": "61.7%"}},
   "all_pool_weighted": {"value": 89.2, "n": 250, "truth": "owner-tags", "source": {"file": "segbench-results/date-tagging.md", "route": "gemini-3.8-flash", "attribute": "all, weighted to the pool", "value": "89.2%"}},
   "du_certain_flagged": {"value": 31.5, "n": 200, "truth": "owner-tags", "source": {"file": "segbench-results/date-truth.md", "route": "gemini-3.8-flash", "attribute": "certain -> flagged (all)", "value": "31.5% (63/200)"}},
   "du_uncertain_unflagged": {"value": 12.0, "n": 50, "truth": "owner-tags", "source": {"file": "segbench-results/date-truth.md", "route": "gemini-3.8-flash", "attribute": "uncertain -> not flagged (all)", "value": "12.0% (6/50)"}}},
  "cost": {"usd_1000_list": 4.07, "usd_1000_batch": null, "price_read": "2026-10-20", "source": {"file": "segbench-results/date-tagging.md", "route": "gemini-3.8-flash", "attribute": "Cost", "value": "$4.07 per 1,000 documents"}},
  "time": {"per_unit_s": null, "measured": false, "measured_on": "not tabulated (figures.json's 3.0 is a hand estimate)", "source": {"file": "settings-design/build_figures.py", "route": "gemini-oneshot", "attribute": "s_doc", "value": "3.0"}},
  "memory": null,
  "caveats": ["input was ABBYY text, banned since 2026-10-30; not rerun on the app's own OCR", "cites no evidence: its non-explicit years fail the traceable rule unless step 4 supplies it", "price doubles 1 Jan 2027 (J-compute.md)", "pooled 79.6% is unweighted (DAT-6)"],
  "kind_rules": [], "fallback": "no year, Date Uncertain", "conditions": []},
 {"id": "gemini3.7-flash-oneshot-vision", "name": "Gemini 3.7 Flash, the app's tagging call on Vision text (gateway)", "family": "cloud",
  "app_route": null, "status": "measured", "step": [1],
  "needs": {"key": ["gateway"], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "unprinted_122": {"value": 71.0, "n": 122, "truth": "owner-tags", "source": {"file": "segbench-results/date-undated.md", "route": "app call, Vision text", "attribute": "dated set, all, year exact", "value": "71% (87/122)"}},
   "undated_false_year": {"value": 6.7, "n": 90, "truth": "owner-ruled (W46.date-undated-fold)", "source": {"file": "segbench-results/date-undated.md", "route": "app call, Vision text", "attribute": "False year on owner-ruled truth", "value": "6.7% (6 of 90); finite bounds 6.7-36.7%; model-based 6.7-16.7%"}}},
  "cost": {"usd_1000_list": null, "usd_1000_batch": null, "price_read": null, "source": {"file": "segbench-results/date-undated.md", "route": "all calls", "attribute": "Cost", "value": "about $1.31 for 482 calls, not split by arm"}},
  "time": {"per_unit_s": null, "measured": false, "measured_on": "not tabulated", "source": null},
  "memory": null,
  "caveats": ["gateway serves 3.7, the app's default is 3.8; a direct Gemini key runs 3.8, unmeasured on this step (P7-4)", "false-year rate scoped to the accepted collection-balanced 90, not the 425 (P3-1)", "Vision text read on macOS 26.6 or 27.2 not stated per arm [?]"],
  "kind_rules": [], "fallback": "no year, Date Uncertain", "conditions": []},
 {"id": "gemini3.7-flash-trace-neigh", "name": "Gemini 3.7 Flash, trace prompt with neighbour dates (gateway)", "family": "cloud",
  "app_route": null, "status": "measured", "step": [4],
  "needs": {"key": ["gateway"], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "not_in_text": {"value": 61.8, "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable-paid.md", "route": "Gemini 3.7 Flash (gateway), trace-neigh", "attribute": "not in text", "value": "61.8%"}},
   "c_plus_d": {"value": 39.3, "n": 56, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable-paid.md", "route": "trace-neigh", "attribute": "C+D", "value": "39.3%"}},
   "evidence_valid": {"value": "86 / 45", "n": 131, "truth": "evidence_check", "source": {"file": "segbench-results/date-traceable-paid.md", "route": "trace-neigh", "attribute": "evidence valid / unsupported", "value": "86 / 45"}},
   "interval_90": {"value": "96.9% coverage, 4.5 y", "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable-paid.md", "route": "trace-neigh", "attribute": "coverage, width", "value": "96.9%, 4.5"}}},
  "cost": {"usd_1000_list": 2.88, "usd_1000_batch": null, "price_read": "3.8 list as ceiling", "source": {"file": "segbench-results/date-traceable-paid.md", "route": "all three trace prompts", "attribute": "Cost", "value": "about $2.88 per 1,000 replies"}},
  "time": {"per_unit_s": null, "measured": false, "measured_on": "not tabulated", "source": null},
  "memory": null,
  "caveats": ["corpus (ABBYY) text input", "gateway only; 3.8 on a direct Gemini key is unmeasured on this step (P7-4)", "run only on the 161 the rules leave undated or whose year is not in the text", "C+D and examples subgroup claims rest on 3 and 1 documents (DAT-8)"],
  "kind_rules": [], "fallback": "propagation t=3", "conditions": ["written only when the evidence check passes, with Date Uncertain"]},
 {"id": "gemini3.7-flash-image", "name": "Gemini 3.7 Flash image pass (gateway)", "family": "cloud",
  "app_route": null, "status": "measured", "step": [2],
  "needs": {"key": ["gateway"], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "unprinted_122_doc_year": {"value": 43, "n": 122, "truth": "owner-tags", "source": {"file": "segbench-results/date-image.md", "route": "Gemini 3.7 Flash (gateway, 2,400 px), image", "attribute": "doc year exact", "value": "52/122 (43%)"}},
   "unprinted_122_on_page": {"value": 46, "n": 122, "truth": "owner-tags", "source": {"file": "segbench-results/date-image.md", "route": "Gemini 3.7 Flash, image", "attribute": "on the page", "value": "56/122 (46%)"}},
   "owner_own_page": {"value": 78, "n": 27, "truth": "owner-ruled (date-truth-sets)", "source": {"file": "segbench-results/date-image.md", "route": "Gemini 3.7 Flash", "attribute": "found the owner's year on the page", "value": "21/27 (78%)"}},
   "owner_ruled_misses": {"value": "7 of 12", "n": 12, "truth": "owner-ruled blind sheet", "source": {"file": "segbench-results/date-undated.md", "route": "image pass", "attribute": "the image pass missed it", "value": "58% (7/12)"}},
   "owner_ruled_inventions": {"value": "0 of 8", "n": 8, "truth": "owner-ruled blind sheet", "source": {"file": "segbench-results/date-undated.md", "route": "image pass", "attribute": "invention count", "value": "0% (0/8)"}}},
  "cost": {"usd_1000_list": 2.75, "usd_1000_batch": null, "price_read": "3.8 list as ceiling", "source": {"file": "segbench-results/date-image.md", "route": "Gemini 3.7 Flash", "attribute": "Reading it", "value": "$2.75 per 1,000 documents"}},
  "time": {"per_unit_s": 5.291, "measured": true, "measured_on": "Stanford gateway, median", "source": {"file": "segbench-results/date-image.md", "route": "Gemini 3.7 Flash, image", "attribute": "median s", "value": "5.291"}},
  "memory": null,
  "caveats": ["tied with the 27B (DAT-3)", "gateway only; 3.8 on a direct Gemini key is unmeasured on this step (P7-4)", "measured only on documents whose year is not in the ABBYY text and on undated ones", "no measurement card in date-image.md"],
  "kind_rules": [], "fallback": "step 4", "conditions": ["documents with no year candidate in the app's own OCR text (owner call 7.3)"]},
 {"id": "qwen3.6-27b-image", "name": "Qwen3.6 27B image pass (your cluster)", "family": "cluster",
  "app_route": null, "status": "measured", "step": [2],
  "needs": {"key": [], "plan": [], "cluster": true, "mac_gb": null, "gpus": 1},
  "figures": {
   "unprinted_122_doc_year": {"value": 39, "n": 122, "truth": "owner-tags", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3.6-27B (Sherlock, vLLM, 2,400 px), image", "attribute": "doc year exact", "value": "48/122 (39%)"}},
   "unprinted_122_on_page": {"value": 43, "n": 122, "truth": "owner-tags", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3.6-27B, image", "attribute": "on the page", "value": "52/122 (43%)"}},
   "owner_own_page": {"value": 74, "n": 27, "truth": "owner-ruled (date-truth-sets)", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3.6-27B", "attribute": "found the owner's year on the page", "value": "20/27 (74%)"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "segbench-results/date-image.md", "route": "open arms", "attribute": "cost", "value": "$0"}},
  "time": {"per_unit_s": 17.5, "measured": true, "measured_on": "Sherlock, vLLM, median a document", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3.6-27B, image", "attribute": "median s", "value": "17.5"}},
  "memory": null,
  "caveats": ["24 of its quotes eye-checked by a Claude subagent before the 2026-10-30 rule (DAT-12)", "32 GB Mac 4-bit untested for dating [?]"],
  "kind_rules": [], "fallback": "step 4", "conditions": ["as gemini3.7-flash-image"]},
 {"id": "qwen3-vl-8b-image-mac", "name": "Qwen3-VL 8B 4-bit image pass (Mac)", "family": "mac",
  "app_route": null, "status": "measured", "step": [2],
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 16, "gpus": 0},
  "figures": {
   "unprinted_122_doc_year": {"value": 16, "n": 122, "truth": "owner-tags", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3-VL 8B, 4-bit MLX (1,400 px), image", "attribute": "doc year exact", "value": "20/122 (16%)"}},
   "unprinted_122_on_page": {"value": 32, "n": 122, "truth": "owner-tags", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3-VL 8B, image", "attribute": "on the page", "value": "39/122 (32%)"}},
   "owner_own_page": {"value": 59, "n": 27, "truth": "owner-ruled (date-truth-sets)", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3-VL 8B", "attribute": "found the owner's year on the page", "value": "16/27 (59%)"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "segbench-results/date-image.md", "route": "open arms", "attribute": "cost", "value": "$0"}},
  "time": {"per_unit_s": 12.05, "measured": true, "measured_on": "M3 Pro 18 GB, median a document", "source": {"file": "segbench-results/date-image.md", "route": "Qwen3-VL 8B, image", "attribute": "median s", "value": "12.05"}},
  "memory": {"peak_gb": 7.64, "measured_on": "M3 Pro 18 GB (OCR run)", "source": {"file": "ocr-mac-local.md", "route": "Qwen3-VL 8B 4-bit", "attribute": "MLX peak memory, GB, max", "value": "7.64"}},
  "caveats": ["quotes the right date and picks another: use as a quote source, the year by rule", "1,400 px and 4-bit not separated (DAT-11)", "3 of 99 OCR pages looped (build_figures.py)"],
  "kind_rules": [], "fallback": "step 4", "conditions": ["as gemini3.7-flash-image; its quotes feed the rule stage"]},
 {"id": "vision-2b-chooser-t3", "name": "Apple Vision text, rules, the trained 2B as chooser, propagation (Mac, no key)", "family": "mac",
  "app_route": null, "status": "measured", "step": [1, 4],
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 8, "gpus": 0},
  "figures": {
   "in_text": {"value": 89.9, "n": 119, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "2B chooser (Vision-text arm, R1)", "attribute": "in text", "value": "89.9%"}},
   "not_in_text": {"value": 47.3, "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "Vision text: 2B chooser|no residue stage|t=3", "attribute": "not in text", "value": "47.3%"}},
   "reread_107": {"value": 38.3, "n": 107, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "Vision text: 2B chooser|no residue stage|t=3", "attribute": "not in text (re-read classes)", "value": "38.3%"}},
   "evidence_valid": {"value": "269 / 24", "n": 300, "truth": "evidence_check", "source": {"file": "segbench-results/date-traceable.md", "route": "2B chooser (Vision)", "attribute": "evidence valid / unsupported", "value": "269 / 24"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "segbench-results/date-traceable.md", "route": "all arms", "attribute": "Cost", "value": "No money on any arm"}},
  "time": {"per_unit_s": null, "per_1000_s": 204, "measured": true, "measured_on": "this Mac, the 2B chooser; Vision OCR (1.02 s a page) belongs to the reading stage", "source": {"file": "segbench-results/date-traceable.md", "route": "Vision text: 2B chooser|no residue stage|t=3", "attribute": "Mac seconds per 1,000 (2B)", "value": "204"}},
  "memory": {"peak_gb": 3.784, "measured_on": "MLX peak; 4.549 GB guard footprint", "source": {"file": "segbench-results/date-model.md", "route": "trained 2B, Mac 8-bit", "attribute": "Peak MLX memory", "value": "3.784 GB"}},
  "caveats": ["Vision text read on macOS 26.6 (P8-1(f)); Vision moved on 27.2 (vision-27-reread.md)", "2B chooser replies were made from corpus text, kept only where they name a Vision candidate", "7/300 invalid"],
  "kind_rules": [], "fallback": "rule pick, else no year", "conditions": ["propagated years written with Date Uncertain, the propagated document as evidence"]},
 {"id": "vision-rules-t3", "name": "Apple Vision text, rules and propagation only (Mac, built in)", "family": "mac",
  "app_route": null, "status": "measured", "step": [1, 4],
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "in_text": {"value": 85.7, "n": 119, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "Vision-text arm, rules only", "attribute": "in text", "value": "85.7%"}},
   "not_in_text": {"value": 48.1, "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "Vision-text arm, rules only", "attribute": "not in text", "value": "48.1%"}},
   "reread_107": {"value": 38.3, "n": 107, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "Vision text: rules only|no residue stage|t=3", "attribute": "not in text (re-read classes)", "value": "38.3%"}},
   "evidence_valid": {"value": "268 / 25", "n": 300, "truth": "evidence_check", "source": {"file": "segbench-results/date-traceable.md", "route": "Vision-text arm, rules only", "attribute": "evidence valid / unsupported", "value": "268 / 25"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "segbench-results/date-traceable.md", "route": "all arms", "attribute": "Cost", "value": "No money on any arm"}},
  "time": {"per_unit_s": null, "per_unit_ms": 0.38, "measured": true, "measured_on": "rule stage on this Mac", "source": {"file": "segbench-results/date-traceable.md", "route": "owner rule time", "attribute": "rule time", "value": "0.38 ms a document"}},
  "memory": null,
  "caveats": ["as vision-2b-chooser-t3", "no chooser: ambiguous candidates take the rule pick"],
  "kind_rules": [], "fallback": "no year", "conditions": ["as vision-2b-chooser-t3"]},
 {"id": "qwen3.6-27b-trace-neigh-vision", "name": "Qwen3.6 27B trace prompt on Vision text (your cluster)", "family": "cluster",
  "app_route": null, "status": "measured", "step": [1, 4],
  "needs": {"key": [], "plan": [], "cluster": true, "mac_gb": null, "gpus": 1},
  "figures": {
   "in_text": {"value": 93.3, "n": 119, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "27B trace-neigh one shot (Vision text)", "attribute": "in text", "value": "93.3%"}},
   "not_in_text": {"value": 56.5, "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "27B trace-neigh one shot (Vision text)", "attribute": "not in text", "value": "56.5%"}},
   "reread_107": {"value": 47.7, "n": 107, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "27B trace-neigh one shot (Vision text)", "attribute": "not in text (re-read classes)", "value": "47.7%"}},
   "evidence_valid": {"value": "216 / 80", "n": 300, "truth": "evidence_check", "source": {"file": "segbench-results/date-traceable.md", "route": "27B trace-neigh (Vision text)", "attribute": "evidence valid / unsupported", "value": "216 / 80"}},
   "interval_90": {"value": "93.1%, 9.5 y", "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-traceable.md", "route": "27B trace-neigh (Vision text)", "attribute": "90% conformal coverage, width", "value": "93.1%, 9.5 y"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "segbench-results/date-traceable.md", "route": "all arms", "attribute": "Cost", "value": "No money on any arm"}},
  "time": {"per_unit_s": 0.98, "measured": true, "measured_on": "GPU-seconds a reply, one Sherlock L40S, 16 at once", "source": {"file": "segbench-results/date-traceable.md", "route": "trace-neigh (Vision text)", "attribute": "GPU-seconds a reply", "value": "0.98"}},
  "memory": null,
  "caveats": ["thinking must be off: with the app's local route (no reasoning switch) the 27B ran to the cap on 300 of 300 (date-tagging.md)", "4/300 invalid; Vision text on macOS 26.6 (P8-1(f))"],
  "kind_rules": [], "fallback": "propagation t=3", "conditions": ["non-explicit years written only when the evidence check passes, with Date Uncertain"]},
 {"id": "mlx-date-2b-8bit", "name": "Trained Qwen3.5 2B 8-bit, the app's prompt (Mac)", "family": "mac",
  "app_route": null, "status": "measured", "step": [1],
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 8, "gpus": 0},
  "figures": {
   "in_text": {"value": 95.0, "n": 119, "truth": "owner-tags", "source": {"file": "segbench-results/date-tagging.md", "route": "mlx-date-2b-8bit-nothink", "attribute": "year, in text", "value": "95.0%"}},
   "not_in_text": {"value": 38.9, "n": 131, "truth": "owner-tags", "source": {"file": "segbench-results/date-model.md", "route": "trained 2B, Mac 8-bit", "attribute": "inferred-year accuracy", "value": "51/131 (38.9%)"}},
   "du_uncertain_unflagged": {"value": 100.0, "n": 50, "truth": "owner-tags", "derived": "none of the 50 marked Date Uncertain, so 50 of 50 unflagged", "source": {"file": "segbench-results/date-model.md", "route": "trained 2B, Mac 8-bit", "attribute": "owner-uncertain identified", "value": "none of the 50"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "segbench-results/date-model.md", "route": "all", "attribute": "money", "value": "No money spent"}},
  "time": {"per_unit_s": 1.39, "measured": true, "measured_on": "this Mac, MLX", "source": {"file": "segbench-results/date-model.md", "route": "2.683 GB MLX build", "attribute": "seconds per document", "value": "about 1.39"}},
  "memory": {"peak_gb": 3.784, "measured_on": "MLX peak; 4.549 GB guard footprint", "source": {"file": "segbench-results/date-model.md", "route": "trained 2B, Mac 8-bit", "attribute": "Peak MLX memory", "value": "3.784 GB"}},
  "caveats": ["not recommended as the default tagger (date-model.md)", "no evidence cited; ABBYY text input", "figures.json's 2.7 GB is the build size, not the peak"],
  "kind_rules": [], "fallback": "no year, Date Uncertain", "conditions": ["kept for its chooser role in vision-2b-chooser-t3"]},
 {"id": "none", "name": "No dating", "family": "manual", "app_route": null, "status": "shipped", "step": [],
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {}, "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": null},
  "time": null, "memory": null, "caveats": [], "kind_rules": [], "fallback": null, "conditions": []}
]
```

`step` is an addition to the schema: dating is a pipeline, and a profile's pick is one row per step, not one row. The
solver adds the steps' costs; this note adds none. Stage `noise`: metric `not_in_text`, tie "the rerun floor, same
year 94% (85/90), or no paired sign-test difference", source `date-undated.md`, `11-measurement-audit.md` DAT-3. The
Gemini 3.7 rows need the gateway (`key: ["gateway"]`, as in notes 04 and 07): the gateway serves only 3.7 (P7-4).

Fields used beyond 00-index.md's schema: `step` (a list of step numbers), `time.per_unit_ms`, `time.per_1000_s`,
string figure values ("86 / 45", "7 of 12", "96.9% coverage, 4.5 y") and `memory: null`.

## 5. Caveats carried

- **F-1, figures.json's combined row.** `gemini-oneshot-image` repeats the one-shot's year figures and adds $2.8 to
  $4.07 by hand; no run measured the combined pipeline. Replaced by separate step rows; the combined figure is item 8.1.
- **F-2.** `cluster-27b-image`'s "not in text 39.0" and `mac-8b-image`'s "16.0" are document-year exact on the 122, not
  the 131; relabelled `unprinted_122_doc_year`. **F-3.** `mac-2b`'s peak 2.7 GB is the build size; the measured peak is
  3.784 GB (`date-model.md`). **F-4.** `uncertain_marked 88` is plain agreement on owner-uncertain documents; replaced by
  the two error rates (DAT-7, `date-truth.md`).
- **DAT-1.** The 131 and the classes A-D are ABBYY-defined; every `not_in_text` field says so, and the `reread_107`
  field gives the Vision re-read where it exists. The route is restated with the image pass first (section 3). The
  residue design of `10-gap-audit.md` is not used: staging lost to one shot, 49.6% against 61.8%
  (`date-traceable-paid.md`). "Unprinted" for the app means no year candidate in its own OCR text [I].
- **DAT-2.** The handwritten share (10 of 56, Gemini) rests on an ABBYY-chosen pool; no handwritten-date reader is
  filed except as nice-to-have (8.7).
- **DAT-3.** Gemini 3.7 and the 27B image passes are a tie; the solver treats them as equal on accuracy.
- **DAT-4.** Typeface dating is not a step.
- **DAT-5.** Enclosure verdicts rest on 3 owner-confirmed enclosures (`date-enclosure.md`: every arm 0 of 3 recall but
  the 27B's 1 of 3; the marker wrote `[enclosure]` on 0 of 225 pages on Qwen3-VL 8B and 2 of 225 on Gemini, one of them
  the false a25). Called B-enc above. The IIT-CDIP set of 80 pairs and 40 negatives (`date-iitcdip.md`) is unscored.
  Step 3a stays as shipped and is not extended.
- **DAT-6.** The headline is given pool-weighted (89.2%) beside the per-stratum rows; undated documents are now
  measured (`date-undated.md`).
- **DAT-7.** `Date Uncertain` is reported as two error rates and is set by evidence class, not by the model. The fix's
  measure is carried beside the owner-tag rates: agreement with "a date on the document's own pages" 82% (174/212),
  70% (14/20) on the owner-ruled sheet (`date-undated.md`).
- **DAT-8.** The C+D and five-example subgroup figures are carried as figures, not as verdicts.
- **DAT-9.** The stratified 200's "52 with no dating year" is not used by any row.
- **DAT-10 to DAT-12.** Per-class intervals of 12-20 points: no rule here rests on a single class figure. Resolution
  and quantisation differ between image arms (a row caveat). The 27B's 24 eye-checked quotes were a Claude subagent's
  check before the 2026-10-30 rule: kept as history, not repeated.
- **R-1 (measure review 2026-10-31).** The 13% false-year rate was scored against the same Gemini model's own image
  reading. Replaced by the owner-ruled figure from W46.date-undated-fold: 6.7% (6 of 90), with the image pass missing a
  page date on 7 of the 12 and inventing none in 8 controls (`date-undated.md`). The 13% appears only as the
  model-scored comparison.
- **P3-1 (pass 3, 2026-10-31-3).** The 6.7% is scoped to the accepted collection-balanced 90, not to the 425 or the
  corpus; the finite bounds (6.7-36.7%) and the model-based interval (6.7-16.7%) are labelled as such, the seven checked
  controls kept fixed (confirmed by pass 4, 2026-11-01). The row's caveat carries the scope; no corpus false-year rate is
  claimed.
- **P8-1(f) (2026-11-04-2).** `date-traceable.md` and `date-image.md` were read on macOS 26.6 Vision text; the Vision
  re-read moved NES +1.7 on the 96 (`vision-27-reread.md`). The Vision rows carry it; item 8.5.
- **Cards.** Of the dating reports only `date-tagging.md` and `date-undated.md` carry a measurement card (grep of
  `segbench-results/date-*.md`) [M]; the rest are read with that gap noted, item 8.9.
- **Truth quality.** The owner's year tag differs from the year he read on the page for 4 of 26 own-page cases
  (`date-truth-sets.md`) and 13 of the stratified 200 tags are contradicted by the page (`date-draft-audit.md`) [M], so
  a route quoting the page can score as wrong against the tag (date-image's 4-of-4 case).

## 6. What would change the rule

- An open model whose `reread_107` exact year on Vision text comes within the tie of Gemini 3.8's 61.7%
  (`date-traceable.md`) makes it the cluster and 32 GB default for step 4 without a key.
- A relation classifier that finds more than 1 of the 3 owner enclosures and, on the IIT-CDIP 80 pairs, fires on covers
  with precision the owner accepts, adds a relation step to 3a; nothing measured so far does.
- The image pass on documents with a year in the text changing the year or its evidence on a share the owner judges
  material (item 8.2) moves step 2 to every document.
- The reading stage choosing an image-reading model (Gemini as OCR) whose text already carries the page dates would
  make step 2 redundant on that route [I]; item 8.1 measures it.
- The Gemini 3.8 Flash price doubling on 1 January 2027 (`J-compute.md`: $0.75/$3.75 to $1.50/$7.50) moves the cost
  rows; the tie rule then favours the cheaper of tied routes.
- `W47.ct-folder-date`'s measurement (how many undated documents sit in a dated folder) sets how much step 3b covers.

## 7. Owner calls

7.1 **Second-role dates (B open question 3).** Which of received stamp, postmark and filing date are kept, and where.
Options: (a) drop them; (b) keep them in the segment JSON sidecar, each with its role, quote and place, never as a
second bare year; (c) a new tag facet beside `Sent With`, a SPEC and Reader change at Tier-2. Evidence: stamps are 5 of
the 56 page dates Gemini found (`date-image.md`); a received stamp is later than the document (`B-dating.md` §1); the
owner's own answer on e4be2882 separated a manuscript's receipt date from its dating year (`date-draft-audit.md`); the
tag vocabulary's only second role is `Sent With`. Recommendation: (b), with the image pass already returning kind and
place, so no new call [I]. Decided (b), no SPEC change (owner call 9, 2026-11-06).

7.2 **The confidence form shown with a non-explicit date.** Options: (a) the evidence class and the cited quote and
place, no number; (b) that plus the 90% conformal interval; (c) a model-stated score. Evidence: stated confidence was
never measured (the rerun was dropped, `date-traceable-paid.md`); conformal widths are 4.5 years for Gemini trace-neigh
and 9.5 for the 27B on Vision text, and decades on the rule pipelines from a few far-wrong picks
(`date-traceable.md`). The owner's rule asks every non-explicit date to carry its evidence "and a confidence score or
similar" (`00-plan.md`, "Owner decisions"); (a) meets it only if the evidence class and quote count as "or similar".
Recommendation: (a) on every route, (b) where the route's interval is measured, shown in the sidecar and the PDF header
with the tag contract unchanged (`B-dating.md` open question 7) [I]. Decided as recommended, the evidence class and quote
taken as the "or similar" the rule asks for (owner call 9, 2026-11-06).

7.3 **Image pass on every document or only those with no year in the text.** Evidence: in-text years are exact on 97.5%
(Gemini) and 89.9% (Vision rules and 2B) already; the image pass was measured only on the not-in-text and undated sets.
Cost: $2.75 per 1,000 documents and 5.3 s median on Gemini 3.7, $0 and 17.5 s on the 27B, $0 and 12.05 s on the Mac 8B
(`date-image.md`); run on every document, the whole of that cost applies; run on the no-year share only, it applies to that share [I].
Recommendation: only where the own OCR text gives no year candidate, until item 8.2 reports. Decided as recommended
(`14-owner-calls.md` section 2).

7.4 **The Mac route's standing.** Settled by measurement as far as defaults go: the trained 2B and 4B never mark a date
uncertain (0 of 50) and reach 41.2% and 40.5% where the year is not printed (`date-model.md`), so neither is a dating
default. Under section 3 the flag no longer comes from the model, which removes one objection; what remained was
whether the 2B ships as the chooser in the no-key route, decided under 7.5.

7.5 **The laptop profile's dating route when there is no key.** Options: (a) Vision text, rules, the 2B chooser and
propagation at t=3, every propagated year with `Date Uncertain` and its document (47.3% not in text, 89.9% in text, $0);
(b) the same without the 2B (48.1%, 85.7%); (c) (a) plus the Qwen3-VL 8B image pass at 16 GB as a quote source, 12.05 s
a document; (d) no non-explicit years at all, explicit dates only. Evidence: section 4 rows. Recommendation: (a) at 8 GB
and up, adding (c) at 16 GB once item 8.1 shows its quotes improve the year [I]; (d) is the user's switch, not the
default. Decided as recommended (`14-owner-calls.md` section 2).

7.6 **What happens to an estimate whose evidence fails.** The owner's rule forbids writing it. Whether it is offered to
the user as an unwritten suggestion is not settled. Evidence: 45 of 131 Gemini trace-neigh replies fail the check,
and of the 27B's failures many are right years whose quotes carry OCR damage (49 of 101, `date-traceable.md`).
Recommendation: not shown until item 8.3 fixes the checker's false refusals [I]. Decided as recommended (owner call 9).

## 8. Items to file

8.1 `W46.date-route-pipeline` [M, about $1-2 gateway, I]: the restated route end to end on the owner's 300 with JPEG
originals and macOS 27.2 Vision text: steps 1, 2 and 4 with `Date Uncertain` set by class, on Gemini 3.7 and the 27B;
report `not_in_text` redefined from the image pass, the false-year rate on the undated 90, and cost and seconds per
1,000. Done when the combined rows replace F-1. Waits on nothing.
8.2 `W46.date-image-intext` [S, about $0.35, I]: the image pass on the 119 in-text documents; how often it changes the
year, finds a second-role date or adds evidence. Settles 7.3.
8.3 `W46.date-evidence-check` [S, $0]: the checker accepts OCR-damaged four-digit years and two-digit dates in a quote,
re-scored on cached replies. Until it is done, failed estimates stay hidden (owner call 9).
8.4 `W46.date-mac-27b` [S, $0]: the 27B 4-bit image pass and trace prompt on a 32 GB Mac, seconds and peak memory.
Fills the 32 and 64 GB tiers.
8.5 Re-run the Vision-text dating arms on macOS 27.2 [S, $0, Mac], under W46.vision-27-swap's conditions (P8-1).
8.6 Foundation Models as the R1 chooser and relation yes/no [S, $0], unmeasured (`date-traceable.md`, "Not in this run").
8.7 Nice-to-have: DAT-2's handwritten-date share on a JPEG-mirror draw (about $0.30); DAT-5's IIT-CDIP relation scoring.
8.8 The Rawls invented-date check that STATE.md assigns to W46.date-traceable appears in no dating report [?]; confirm
or file [XS, $0].
8.9 Cards for date-image, date-traceable(-paid), date-enclosure, date-model, date-truth(-sets) [XS, $0].
8.10 Gaps for the table (`12-settings-design.md` §3.9): cloud seconds for the tagging call and trace prompt; the
gateway tagging call's own cost per 1,000; batch prices measured, not halved by rule.
8.11 `W47.ct-folder-date` is already filed; this note names step 3b as its fold-in point only.

## 9. Profile test expectations

- **Laptop, 16 GB, no key:** step 1 and 4 `vision-2b-chooser-t3` (47.3 not in text, 89.9 in text, over
  `mlx-date-2b-8bit` 38.9 with no evidence); step 2 `qwen3-vl-8b-image-mac` as quote source pending 7.5.
- **Laptop, 32 GB and 64 GB:** as 16 GB until item 8.4 measures the 27B on a Mac; the solver must not borrow the
  cluster rows' figures [?].
- **Laptop, under 8 GB:** `vision-rules-t3` (48.1, 85.7); a tie with the 2B row on `not_in_text`, broken on in-text.
- **Cheap API (OpenRouter key):** steps 1 and 4 `gemini3.8-flash-oneshot` needs `openrouter` and qualifies; its
  non-explicit years carry no evidence, so step 4 must be a trace row. `gemini3.7-flash-trace-neigh` needs the
  gateway, so an OpenRouter key alone has no measured step 2 or 4 row: steps 2 and 4 fall to the laptop rows. Where the
  gateway is present, step 4 is `gemini3.7-flash-trace-neigh` (61.8 against 63.4, both on ABBYY-text inputs on the 131;
  the 94% floor is a same-year rate between reruns, not a gap in points, so calling this gap a tie is [I]) and step 2
  `gemini3.7-flash-image`.
- **Premium (Gemini key):** step 1 `gemini3.8-flash-oneshot`. Steps 2 and 4 have no measured row on a direct key (it
  runs 3.8; the 3.7 rows are the gateway's): the solver falls to the laptop rows for them and the card says 3.8 is
  unmeasured on those steps. With the gateway, step 2 `gemini3.7-flash-image` (43 / 46 on the 122, $2.75) and step 4
  `gemini3.7-flash-trace-neigh`.
- **Cluster:** steps 1 and 4 `qwen3.6-27b-trace-neigh-vision` (56.5, 93.3, thinking off), step 2 `qwen3.6-27b-image`
  (tied with Gemini, DAT-3).
- **Any profile plus a coding agent:** the base profile's picks; no after-training dating row exists (the fine-tunes
  are not recommended, `date-model.md`).
- **Kinds:** a document whose own text has a year gets step 1 only, no `Date Uncertain`; one with a page-only date gets
  step 2's year, no flag; an established enclosure gets `Sent With` and the flag; an undated one in a dated folder waits
  on `W47.ct-folder-date`; the rest get a step 4 year with the flag and evidence, or no year if the check fails.

## Owner's calls (2026-11-06)

From `14-owner-calls.md`. Owner call 9: second-role dates go in the document's JSON sidecar with role, quote and place,
never as a second bare year, with no SPEC change (7.1); every non-explicit date shows its evidence class and the cited
quote with its place, and the 90% conformal interval only where the route measured it, in the sidecar and the PDF
header, the evidence class and quote being the "confidence score or similar" the owner's rule asks for (7.2); an
estimate that fails the evidence check is not shown at all until item 8.3 (7.6). Section 2's dating picks, open to the
owner's veto: the image pass runs only where the app's own text gives no year candidate (7.3); the trained 2B and 4B
are not dating defaults (7.4); the no-key laptop route is Vision text, rules, the 2B chooser and propagation at t=3,
every propagated year `Date Uncertain` with its source document, the Mac 8B image pass added at 16 GB once item 8.1
shows its quotes help (7.5). Section 3 carries all of these; the inherited flag on a dated folder stays with
`W47.ct-folder-date`.

Files read: `execution-plans/processing-review/00-plan.md` (1-140); the worktree's `13-stage-rules/00-index.md`;
`settings-design/figures.json` and `build_figures.py`; `B-dating.md` (1-16, 89-178); `11-measurement-audit.md` (DAT-1
to DAT-12); `12-settings-design.md` (§3.8-3.9); `10-gap-audit.md` (Phase 4 questions); `STATE.md` (dating lines);
`J-compute.md` (Gemini prices); `measure-reviews/2026-10-31.md` (R-1), `2026-10-31-3.md` (P3-1), `2026-11-01.md`,
`2026-11-04.md` (P7-3), `2026-11-04-2.md` (P8-1, P8-6), with a grep of the rest; `segbench-results/date-tagging.md`,
`date-traceable.md`, `date-traceable-paid.md`, `date-image.md`, `date-image-typeface.md`, `date-enclosure.md`,
`date-undated.md`, `date-truth.md`, `date-truth-sets.md`, `date-draft-audit.md`, `date-model.md`, `date-iitcdip.md`,
`vision-27-reread.md` (head), `r1-foundation.md` (grep); `SPEC/tag-format.md` (Sent With rows); `SUITE_TODO.md`
(W47.ct-folder-date, W46.review-phase4).
