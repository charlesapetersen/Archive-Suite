# 09. Entities: sender, recipient, sending place (Phase 4 rule note, draft)

Drafted 2026-11-06 from the strand note, the entity result notes, `11-measurement-audit.md` and the measurement-review
passes; corrected after verification and walked with the owner on 2026-11-06 (the last section before the files). Paths are relative to the Archive Suite repo;
result notes are in `ArchiveProcessor/segbench-results/`.

## 1. Stage and question

The stage reads a correspondence document's text and returns its sender, recipient(s) and sending place, each with its
evidence (a quote from the document's own text, or marked inferred), for the sidecar, search and a later export, and as
an input to dating and segmentation. The user chooses which route extracts the fields, or none.

## 2. Is there a choice?

Yes. The shipped cloud call reaches sender 0.73, recipient 0.82 and place 0.72 (`ent-place-rule.md`); the best Mac model
0.60, 0.61 and 0.54 (`ent-local-shipped.md`, the shipped prompt on Vision text, n 138; 0.58, 0.55 and 0.46 on ABBYY
text before) [M]. Inside the API family the shipped tagging call and the
dedicated prompt at the same length tie on every field once both carry the place rule [M, `ent-place-rule.md`]; the
8,000-character dedicated prompt was not paired with the shipped call (0.76 against 0.73 on the sender, unpaired), so
the real choice is family, not prompt [I]. W47.wh-ent-8k-paired (2026-11-19) has since paired it with the shipped entity
call, fresh, run twice, on Gemini 3.8 Flash: sender +0.107 (+0.038 to +0.189) and +0.108 on the replicate against a rerun
drift of about -0.01, all on the 48 documents past 3,000 characters; recipient and place tie (`ent-8k-paired.md`) [M].
The owner moved the window to 8,000 (call 18, 2026-11-19), and W47.wh-ent-8k-apply built it on the cloud routes; a
model served on this Mac and Apple's name tagger keep 3,000, where 8,000 is unmeasured. The gain was measured on Apple
Vision text, where the app withholds the sender (rule `ent-vision-hands`, owner call 11), so it reaches users only on
text a model read. No model-read text of the 138 is in the bench cache to count; on the owner's 96 pages the readers'
text runs 1.01 to 1.05 times as long as Vision's (median page 1.00), so about the same letters run past 3,000 [M, a
proxy on other pages: `ent-robust`'s cached readings]. On Vision text 20 of the 42 long letters with a named sender
name it first in the first 3,000 characters, 10 between 3,000 and 8,000 and 5 past 8,000 [M, counted by W47.wh-ent-8k-apply
on the cached Vision text against `ent_truth.load_truth()` by full name or surname, kept in no result file]; a model reader that transcribes a signature Vision misses
would add senders at the end of a letter, which favours the longer window [I].

## 3. The rule for the settings layer

Sheet text: "Names: who sent each letter, to whom, and from where. Each name is shown with the words it was read from,
or marked inferred. Looked for only when names are among what matters most. On a cloud route it is one more request
a letter; on this Mac it needs a local model and typed pages."

- **Comparison metric.** Sender ed2 F1 on the entity truth as it now stands (`ent_truth.load_truth()`: W46.fix-ent-truth
  with the owner's answers and the sending-place rule), recipient ed2 F1 second, place by city third. Tie rule: a
  difference whose paired 95% bootstrap interval contains zero, or that sits inside the rerun floor, is a tie
  (`ent-place-rule.md`, `ent-score-paid.md` cards). An unpaired gap (different text or n) of a few points is noise:
  ENT-1 rules the 27B's 0.60 against the 8B's 0.56 on senders (n 82) a tie [M, audit ruling]. Ties go to the cheaper
  route, then to the route already running for another stage. The order of the three fields is this note's
  proposal [I]; the owner may weigh recipients first.
- **Kind rules for the regular route.** (a) The stage runs on correspondence only: the role figures are on 138
  correspondence documents, and
  non-correspondence output is unmeasured (`ent-prompt-app.md` Scope: author_name is now null there). (b) Typed or
  printed pages: every route that clears the bar may show names. (c) Handwritten pages: show names only from the API or
  27B readings, or from the 8B reading with the quote check; never from Apple Vision text (W46.ent-robust's switch-off
  rule, `ent-robust.md` Reading). (d) The sender field is never shown from Apple Vision text on any kind (same rule),
  and where the feature does not run, the sidecar leaves out the tagging call's `author_name` on Vision text too
  (owner, walkthrough 2026-11-13; `recipient_name` and `author_location` stay).
  (e) Pre-modern material is available through the low-confidence opt-in below.
- **Evidence rule.** A name whose quote is in the document's own OCR text (spacing-tolerant, edit distance 2) is shown
  as read; a name with no quote is shown marked inferred; a name found nowhere is never shown as read
  (`ent-score.md` Reading, G-entities §5). The check is against the document's own text, not the whole prompt, which
  carries neighbours' snippets (2 to 10 names a model lifted from them, `ent-score.md`).
- **Fallback.** When the chosen route fails on a document (unparsed or length-capped reply), no names, and the sidecar
  says so (`ent-robust.md`: the 8B failed 4 of 96 readings). No silent fallback to another route [I].
- **Run conditions.** Every route requires Names among the collection priorities (owner, walkthrough 2026-11-13) and
  respects the `none` override. The regular route follows rules (a)–(d). Its separate cloud call costs $4.39 per
  1,000 correspondence documents at 8,000 characters (`ent-8k-paired.md`, Gemini 3.8 Flash to 31 December).
- **Advanced opt-in (owner call 15, W47.wh-names-small-mac).** Apple NLTagger reads the first 3,000 characters of
  OCR text on this Mac, with no download or API request. The built-in finder uses the measured English settings and
  the letter-position rule where automatic tagging identifies correspondence and the text comes from a known model
  reader. Vision text, other documents and OCR-only runs can record exact quoted mentions with no assigned roles.
  Every entry produced by this route has low confidence. The opt-in is off by default and can be set for a collection
  without inferring the period of individual documents. Enable JSON metadata export to get the results alongside newly
  generated PDFs. GLiNER’s 0.24 sender F1 and NLTagger’s 0.14 are benchmark scores on 138 correspondence documents.
  The 0.02–0.37 on L5 and L7 is agreement across OCR and reference text, measured across readers and extractors.
- **The local picks on Vision text.** Both are scored on the shipped prompt over Vision text, n 138
  (`ent-local-shipped.md`, W46.ent-local-shipped-prompt): the Mac pick (`qwen3-vl-8b-mac`) at sender 0.60, recipient
  0.61, place 0.54; the cluster pick (`qwen3.6-27b`) at 0.66, 0.68, 0.56, ahead of the 8B on recipients (+0.073,
  +0.004 to +0.148) and tied on the rest. On the 82 each ties its old ABBYY-reply row on every field. Neither is
  provisional any longer.
- **The prompt the figures belong to** (owner call 10). The person-only sender rule and the heading-or-address place
  rule (4cdbba41, 4374254d) move to the entity feature's own prompt, and the tagging prompt is reverted to its
  pre-November name behaviour. The `gemini-tagging-place` figures were measured with both rules in the tagging prompt,
  so they describe the rules, not the reverted call; the reverted prompt's own figures are on the built truth only
  (`tagging` in `ent-prompt-app.md`: sender 0.706, recipient 0.717, place 0.617 ed2 F1) until item 3 restates them.
  The app's entity feature (W46.ent-feature) sends the entity3k-place prompt byte for byte, on the first 8,000
  characters since W47.wh-ent-8k-apply, so its row, `gemini-entity-feature`, carries the 8k arm's figures on the
  owner-rule truth (`ent-8k-paired.md`: sender 0.81, recipient 0.89, place 0.82, by city 0.89; $4.39 per 1,000, one
  extra call, median 5.9 s); the 3,000-character figures it shipped with are `ent-feature.md`'s (sender 0.69).
  `gemini-entity8k`, the 8,000-character row measured unpaired, is folded into it. `gemini-tagging-place` stays in §4
  as measured history, not offered (W46.ent-feature-table).

## 4. Table rows

Truth ids: `ent-owner-rule` is `ent_truth.load_truth()` (138 documents, 72 named places); `ent-built` is W46.fix-ent-truth
as built, used only where no restated figure exists. All values ed2 F1 unless named. Costs and seconds marked `[?]`
come from `build_figures.py`'s hand-entered rows with no measuring file behind them.

```json
{"id": "entities", "name": "Entities: sender, recipient, sending place", "unit": "documents", "choice": true,
 "metric": {"id": "sender_ed2_f1", "label": "sender found (ed2 F1), then recipient, then place by city", "higher_is_better": true},
 "kinds": ["correspondence-typed", "correspondence-handwritten", "non-correspondence"],
 "rules": [
  {"id": "ent-correspondence-only", "text": "The regular names route runs on correspondence only; the Advanced finder can record mentions without assigning roles.", "source": "ent-prompt-app.md §Measurement card", "switch": null},
  {"id": "ent-vision-hands", "text": "The regular route skips Apple Vision text on handwritten pages; no route assigns a sender from Vision text, the tagging call's included.", "source": "ent-robust.md §Reading", "switch": null},
  {"id": "ent-evidence", "text": "Quoted in the document's own text: shown as read; unquoted: written and shown marked inferred; never shown as read without a quote.", "source": "ent-score.md §Reading; G-entities.md §5; 14-owner-calls.md §1. The owner's calls", "switch": null},
  {"id": "ent-run", "text": "Names are extracted only when the collection interview ranks names, on every route; on the Mac on typed and printed correspondence only.", "source": "14-owner-calls.md §1. The owner's calls", "switch": {"id": "entities.enabled", "label": "Find senders, recipients and places", "default": false}},
  {"id": "ent-low-confidence-on-mac", "text": "Apple’s built-in finder can be chosen explicitly for smaller Macs or early material. Every result is marked low confidence.", "source": "14-owner-calls.md §1. The owner's calls; ent-score.md; ent-robust.md", "switch": {"id": "entities.low_confidence_on_mac", "label": "Find names on this Mac (low confidence)", "default": false}}
 ],
 "fallback": "none"}
```

The stage header above is kept apart from the route rows, which follow as a list like the other notes' blocks.

```json
[ {"id": "gemini-entity-feature", "name": "Gemini, the entity feature's own request (8,000 characters)", "family": "cloud",
  "app_route": "gemini|gemini-3.8-flash", "status": "shipped",
  "needs": {"key": ["gemini", "openrouter"], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "sender": {"value": 0.81, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-8k-paired.md", "route": "8k", "attribute": "sender F1", "value": "0.811"}},
   "recipient": {"value": 0.89, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-8k-paired.md", "route": "8k", "attribute": "recipient F1", "value": "0.892"}},
   "sending_place": {"value": 0.82, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-8k-paired.md", "route": "8k", "attribute": "place P / R / F1", "value": "0.86 / 0.78 / 0.818"}},
   "place_city": {"value": 0.89, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-8k-paired.md", "route": "8k", "attribute": "place by city", "value": "0.891"}},
   "quote_precision_sender": {"value": 0.82, "n": 130, "truth": "ent-owner-rule", "source": {"file": "ent-8k-paired.md", "route": "8k", "attribute": "sender, quote in text", "value": "107/130 (0.82)"}}},
  "cost": {"usd_1000_list": 4.39, "usd_1000_batch": null, "price_read": null, "source": {"file": "ent-8k-paired.md", "route": "8k prompt", "attribute": "one more call per correspondence document, Gemini 3.8 Flash's price to 31 December, metered tokens of the 138 calls", "value": "$4.39 per 1,000"}},
  "time": {"per_unit_s": 5.9, "measured": true, "measured_on": "AI Studio with the personal key, median of the 138 calls", "source": {"file": "ent-8k-paired.md", "route": "8k prompt", "attribute": "median a call", "value": "Median 5.9 s"}},
  "memory": null,
  "caveats": ["the first 8,000 characters on a cloud route (W47.wh-ent-8k-apply, owner call 18); a model served on this Mac and Apple's name tagger keep the first 3,000 (EntityExtractor.macTextCap), since 8,000 is unmeasured there (ent-8k-paired.md Scope)",
   "measured with Gemini 3.8 Flash on Apple Vision text, where the app withholds the sender (rule ent-vision-hands, owner call 11): the sender gain reaches users only on text a model read. No model-read text of the 138 is cached; on the owner's 96 pages the readers' text runs 1.01 to 1.05 times Vision's length, so about the same letters run past 3,000 (a proxy on other pages, W47.wh-ent-8k-apply)",
   "paired and run twice against the 3,000-character call it replaced: sender +0.107 [+0.038, +0.189] and +0.108 [+0.034, +0.194] against a rerun drift of -0.013 and -0.012, all on the 48 letters past 3,000 characters (0.46 against 0.80); recipient, place and city tie (ent-8k-paired.md)",
   "behind the app's correspondence gate (the tagging reply's format) 134 of 138 pass; the gate lets 4 of 21 non-correspondence documents through (ent-feature.md, measured at 3,000 characters)",
   "every quoted name was found in the text it was sent; a quote proves the words are on the page, not the role: read senders right 107 of 130 (ent-8k-paired.md)",
   "one extra call after the tagging call, +$0.55 per 1,000 over the 3,000-character call ($3.84); both double from 1 January 2027 (ent-8k-paired.md)",
   "the sender convention is the truth's: a person, or the issuing organisation when no person is named (owner call 10)"],
  "kind_rules": ["non-correspondence: do not show", "handwritten: allowed (ent-robust.md: Gemini text keeps 0.94 of the 27B extractor's names on hands)"],
  "fallback": "none", "conditions": []},
 {"id": "gemini-tagging-place", "name": "Gemini, inside the tagging call (measured history)", "family": "cloud",
  "app_route": null, "status": "measured",
  "needs": {"key": ["gemini", "openrouter"], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "sender": {"value": 0.73, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-place-rule.md", "route": "tagging-place", "attribute": "sender F1", "value": "0.73"}},
   "recipient": {"value": 0.82, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-place-rule.md", "route": "tagging-place", "attribute": "recipient F1", "value": "0.82"}},
   "sending_place": {"value": 0.72, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-place-rule.md", "route": "tagging-place", "attribute": "place P / R / F1", "value": "0.76 / 0.69 / 0.72"}},
   "place_city": {"value": 0.88, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-place-rule.md", "route": "tagging-place", "attribute": "place by city", "value": "0.88"}},
   "filled_no_place": {"value": 1, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-place-rule.md", "route": "tagging-place", "attribute": "filled, no place", "value": "1"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "date-tagging.md", "route": "gemini-3.8-flash", "attribute": "the tagging call itself", "value": "$4.07 per 1,000 documents, paid by the dating stage"}},
  "time": {"per_unit_s": 0, "measured": false, "measured_on": "no extra call", "source": {"file": "settings-design/build_figures.py", "route": "gemini-tagging", "attribute": "s_doc", "value": "0"}},
  "memory": null,
  "caveats": ["measured with Gemini 3.7 Flash on Vision text; the app's 3.8 not run on the shipped prompt (ent-prompt-app.md Scope)",
   "sender rule is person-only, stricter than the truth (P6-3); 41 of 129 senders left empty under tagging-new (ent-prompt-app.md)",
   "place rule a tie on the owner-checked truth: invented places 14 to 1, of which 7 to 1 on the 18 unchecked rows the rule emptied and 7 to 0 elsewhere (6 to 0 owner-checked, 1 to 0 on the 88 it did not empty), written places missed (ent-place-rule.md, W46.place-rule-fold)",
   "every gain against the old prompt is in-sample (ent-prompt-app.md card)",
   "first 3,000 characters only: 78 of 138 named senders in that span of Vision text, 90 in 8,000 (ent-score-paid.md)",
   "no quotes returned; the evidence rule needs an app-side text check (item 1)",
   "tagging call price doubles 1 Jan 2027 (G-entities.md R4)",
   "measured with both provisional rules in the tagging prompt; owner call 10 reverts that prompt, whose own figures are the built-truth tagging arm (sender 0.706, recipient 0.717, place 0.617; ent-prompt-app.md) until item 3 restates them"],
  "kind_rules": ["non-correspondence: do not show", "handwritten: allowed (ent-robust.md: Gemini text keeps 0.94 of the 27B extractor's names on hands)"],
  "fallback": "none", "conditions": ["not offered by the app: the tagging prompt was reverted to its pre-November name lines (owner call 10) and the app reads names with gemini-entity-feature; kept as measured history"]},
 {"id": "qwen3.6-27b", "name": "Qwen3.6 27B (your cluster or OpenRouter)", "family": "cluster",
  "app_route": null, "status": "measured",
  "needs": {"key": ["openrouter"], "plan": [], "cluster": true, "mac_gb": null, "gpus": 1},
  "figures": {
   "sender": {"value": 0.66, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3.6-27b tagging, Vision (138)", "attribute": "owner+rule sender", "value": "0.66"}},
   "recipient": {"value": 0.68, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3.6-27b tagging, Vision (138)", "attribute": "owner+rule recipient", "value": "0.68"}},
   "sending_place": {"value": 0.56, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3.6-27b tagging, Vision (138)", "attribute": "owner+rule place", "value": "0.56"}},
   "place_city": {"value": 0.71, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3.6-27b tagging, Vision (138)", "attribute": "owner+rule city", "value": "0.71"}},
   "handwritten_or_mixed": {"value": 0.438, "n": 22, "truth": "ent-built", "source": {"file": "ent-score.md", "route": "qwen3.6-27b", "attribute": "handwritten or mixed hand, sender / recipient / place", "value": "0.438 / 0.606 / 0.571"}},
   "g17_business_letters": {"value": 0.55, "n": 57, "truth": "G17", "source": {"file": "ent-robust.md", "route": "qwen3.6-27b", "attribute": "F1 micro (published median 0.55)", "value": "0.55"}}},
  "cost": {"usd_1000_list": 1.4, "usd_1000_batch": null, "price_read": null, "source": {"file": "settings-design/build_figures.py", "route": "qwen27b", "attribute": "usd_1000", "value": "1.4 [?]"}},
  "time": {"per_unit_s": 5.0, "measured": false, "measured_on": "estimate; Sherlock throughput, not a per-document time: the 138 entity requests in about 2 minutes at 32 in flight on one GPU (median 26.3 s a request in flight, ent-local-shipped.md), a 6.6-minute job with the model's load; 26 minutes for 2,078 texts and 57 letters on one L40S (ent-robust.md)", "source": {"file": "settings-design/build_figures.py", "route": "qwen27b", "attribute": "s_doc", "value": "5.0"}},
  "memory": null,
  "caveats": ["shipped tagging prompt on Vision text, 138 documents, vLLM FP8 on Sherlock (ent-local-shipped.md); against Gemini 3.7 on the same input: sender -0.051 (-0.115 to +0.003), recipient and place ties, city -0.111 (-0.168 to -0.059)",
   "against the Mac 8B on the same input: recipient +0.073 (+0.004 to +0.148), sender, place and city ties",
   "on the 82 the old prompt on ABBYY text also scored, a tie on every field (sender +0.039, -0.072 to +0.147)",
   "handwritten_or_mixed is the old ABBYY reply's (ent-score.md)"],
  "kind_rules": ["handwritten: allowed (ent-robust.md: own reading 0.82 of truth-text names)"], "fallback": "none", "conditions": []},
 {"id": "qwen3-vl-8b-mac", "name": "Qwen3-VL 8B on this Mac", "family": "mac",
  "app_route": null, "status": "measured",
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 16, "gpus": 0},
  "figures": {
   "sender": {"value": 0.60, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3-vl-8b MLX 4-bit tagging, Vision (138)", "attribute": "owner+rule sender", "value": "0.60"}},
   "recipient": {"value": 0.61, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3-vl-8b MLX 4-bit tagging, Vision (138)", "attribute": "owner+rule recipient", "value": "0.61"}},
   "sending_place": {"value": 0.54, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3-vl-8b MLX 4-bit tagging, Vision (138)", "attribute": "owner+rule place", "value": "0.54"}},
   "place_city": {"value": 0.68, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-local-shipped.md", "route": "qwen3-vl-8b MLX 4-bit tagging, Vision (138)", "attribute": "owner+rule city", "value": "0.68"}},
   "handwritten_or_mixed": {"value": 0.485, "n": 22, "truth": "ent-built", "source": {"file": "ent-score.md", "route": "qwen3-vl-8b", "attribute": "handwritten or mixed hand, sender / recipient / place", "value": "0.485 / 0.727 / 0.385"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "settings-design/build_figures.py", "route": "qwen8b-mac", "attribute": "usd_1000", "value": "0.0"}},
  "time": {"per_unit_s": 7.76, "measured": true, "load_s": 2.4, "measured_on": "M3 Pro 18 GB, text-only entity call, median of the 138 documents, load apart", "source": {"file": "ent-local-shipped.md", "route": "Qwen3-VL 8B MLX 4-bit", "attribute": "median s a document", "value": "7.76"}},
  "memory": {"peak_gb": 6.38, "whole_process_gb": 6.98, "measured_on": "M3 Pro 18 GB, text-only entity call (/usr/bin/time -l peak footprint)", "source": {"file": "ent-local-shipped.md", "route": "Qwen3-VL 8B MLX 4-bit", "attribute": "MLX peak / whole-process peak footprint", "value": "6.38 / 6.98"}},
  "caveats": ["shipped tagging prompt on Vision text, 138 documents (ent-local-shipped.md); against Gemini 3.7 on the same input: sender -0.105 (-0.173 to -0.045), recipient -0.110, place a tie",
   "on the 82 the old prompt on ABBYY text also scored, a tie on every field (sender +0.065, -0.038 to +0.167)",
   "handwritten_or_mixed is the old ABBYY reply's (ent-score.md)",
   "on Vision text: typed and printed pages only, never the sender, never handwritten (ent-robust.md)"],
  "kind_rules": ["handwritten: only on the 8B's own reading, with the quote check (ent-robust.md: 0.79)", "handwritten via Vision text: do not show"],
  "fallback": "none", "conditions": []},
 {"id": "qwen3.5-4b-mac", "name": "Qwen3.5 4B on this Mac", "family": "mac",
  "app_route": null, "status": "measured",
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 8, "gpus": 0},
  "figures": {
   "sender": {"value": 0.51, "n": 82, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "qwen3.5-4b tagging reply, ABBYY (82)", "attribute": "sender built -> owner", "value": "0.50 -> 0.51"}},
   "recipient": {"value": 0.42, "n": 82, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "qwen3.5-4b tagging reply, ABBYY (82)", "attribute": "recipient", "value": "0.42 -> 0.42"}},
   "sending_place": {"value": 0.36, "n": 82, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "qwen3.5-4b tagging reply, ABBYY (82)", "attribute": "owner+rule F1", "value": "0.36"}},
   "place_city": {"value": 0.44, "n": 82, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "qwen3.5-4b tagging reply, ABBYY (82)", "attribute": "owner+rule city", "value": "0.44"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "settings-design/build_figures.py", "route": "qwen4b-mac", "attribute": "usd_1000", "value": "0.0"}},
  "time": {"per_unit_s": 4.0, "measured": false, "measured_on": "estimate", "source": {"file": "settings-design/build_figures.py", "route": "qwen4b-mac", "attribute": "s_doc", "value": "4.0 [?]"}},
  "memory": {"peak_gb": 4.9, "measured_on": "no measuring file found", "source": {"file": "settings-design/build_figures.py", "route": "qwen4b-mac", "attribute": "peak_gb", "value": "4.9 [?]"}},
  "caveats": ["wrong sender on 30 of 77 documents against null on 15 (ent-score.md): wrong more often than empty", "ent-score.md: the field falls off at 4B"],
  "kind_rules": ["handwritten: do not show"], "fallback": "none", "conditions": ["not offered (owner call 11; 14-owner-calls.md section 2)"]},
 {"id": "nltagger", "name": "Apple NLTagger (built in)", "family": "mac",
  "app_route": null, "status": "measured",
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "sender": {"value": 0.14, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "nltagger (138)", "attribute": "sender built -> owner", "value": "0.13 -> 0.14"}},
   "recipient": {"value": 0.16, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "nltagger (138)", "attribute": "recipient", "value": "0.17 -> 0.16"}},
   "sending_place": {"value": 0.04, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "nltagger (138)", "attribute": "owner+rule F1", "value": "0.04"}},
   "place_city": {"value": 0.21, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "nltagger (138)", "attribute": "owner+rule city", "value": "0.21"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "ent-score.md", "route": "nltagger", "attribute": "on device", "value": "$0"}},
  "time": {"per_unit_s": 0.008, "measured": true, "measured_on": "M3 Pro CPU, background QoS: read the ratio", "source": {"file": "ent-score.md", "route": "nltagger", "attribute": "s/doc", "value": "0.008"}},
  "memory": null,
  "caveats": ["cannot replace the LLM: a perfect position rule over its spans finds at most 35 of 138 named senders (ent-score.md)"],
  "kind_rules": [], "fallback": "none", "conditions": ["not offered automatically; choose the low-confidence finder in Advanced settings", "lower-scoring: sender F1 0.14 on 138 correspondence documents; offered at the Advanced level only"]},
 {"id": "gliner2.5-base-spans-rule", "name": "GLiNER2.5 base, spans with the letter position rule", "family": "mac",
  "app_route": null, "status": "measured",
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {
   "sender": {"value": 0.24, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "gliner2.5-base-spans-rule (138)", "attribute": "sender built -> owner", "value": "0.24 -> 0.24"}},
   "recipient": {"value": 0.28, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "gliner2.5-base-spans-rule (138)", "attribute": "recipient", "value": "0.29 -> 0.28"}},
   "sending_place": {"value": 0.14, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "gliner2.5-base-spans-rule (138)", "attribute": "owner+rule F1", "value": "0.14"}},
   "place_city": {"value": 0.32, "n": 138, "truth": "ent-owner-rule", "source": {"file": "ent-truth-owner.md", "route": "gliner2.5-base-spans-rule (138)", "attribute": "owner+rule city", "value": "0.32"}}},
  "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": {"file": "ent-score.md", "route": "gliner2.5-base-spans-rule", "attribute": "on device", "value": "$0"}},
  "time": {"per_unit_s": 0.407, "measured": true, "measured_on": "M3 Pro CPU, background QoS: read the ratio", "source": {"file": "ent-score.md", "route": "gliner2.5-base-spans-rule", "attribute": "s/doc", "value": "0.407"}},
  "memory": null,
  "caveats": ["best of nine GLiNER settings; ceiling 60 of 138 named senders with a perfect rule (ent-score.md)"],
  "kind_rules": [], "fallback": "none", "conditions": ["never offered; the noise-aware fine-tune (G test 9) not run because it cannot close the gap (ent-robust.md)"]},
 {"id": "none", "name": "No names", "family": "manual", "app_route": null, "status": "shipped",
  "needs": {"key": [], "plan": [], "cluster": false, "mac_gb": 0, "gpus": 0},
  "figures": {}, "cost": {"usd_1000_list": 0.0, "usd_1000_batch": 0.0, "price_read": null, "source": null},
  "time": null, "memory": null, "caveats": [], "kind_rules": [], "fallback": null, "conditions": []}
]
```

Rows not given: R5 (Claude plan through `claude -p`): the plan arm was dropped, not moved (owner, 2026-10-30;
`ent-score-paid.md` card), so no figure exists. R6: none found (G-entities.md Routes, search stated there). R8 (local
proposes, quote check confirms, paid route on the residue): designed in G-entities.md §3, never run as a cascade [M:
no result note]. Qwen3.6 27B on a 32 or 64 GB Mac: in the G route table, memory and figures unmeasured on the Mac.

Fields used beyond 00-index.md's schema: none in the route rows. The stage header is a separate block holding the
schema's stage fields (`id`, `name`, `unit`, `choice`, `metric`, `kinds`, `rules`, `fallback`) without `routes`; figure
keys are field names (`sender`, `recipient`, `sending_place`, `place_city`) and subsets (`handwritten_or_mixed`,
`g17_business_letters`, `quote_precision_sender`, `filled_no_place`) rather than document kinds.

## 5. Caveats carried

- **ENT-1 to ENT-5** (`11-measurement-audit.md` lines 280-289, one block, "hold, with caveats"). The block is not
  split by id, so each point is carried by content. Model truth with Sonnet ruling 86 documents: carried as the truth
  id and the self-ruling counts below. 5 handwritten letters: the `handwritten_or_mixed` figures (n 22, built truth) are
  the only kind split, and the handwriting rules lean on `ent-robust.md`, not on accuracy. Replies scored on ABBYY
  text: a caveat on every Qwen row. Close ranks are noise: the tie rule in §3. ent-robust measures consistency against
  the 27B's own names: the Mac-route rules cite it as consistency, never as accuracy. The audit's fix (Vision text,
  the 56 additions, the owner control) is done by W46.ent-score-paid and W46.ent-truth-owner-fold [M].
- **P6-3** (`measure-reviews/2026-11-03.md`): the sender rule shipped as an app default on a tie (+0.025, -0.016 to
  +0.070), stricter than the truth (an organisation where no person is named) and than G-entities' design (a person
  or an organisation). Respected: the tagging row carries it as a caveat, and owner call 10 moves the rule to the entity feature's prompt. Its queued
  condition, that W47.item-fields-retruth-score score the person-only rule on non-correspondence, is not met:
  `item-fields-score.md` Scope says it does not settle sender [M]. Filed as item 3.
- **P6-5** (same note): the reply cache ignored the prompt. Settled: pass 7 found every reply now carries the
  prompt's hash, 810 reconstructed, none re-called (`measure-reviews/2026-11-04.md`, "The four corrections"); the
  "364 quoted names" label now reads 364 and 347, 711 in both arms (`ent-score-paid.md`) [M].
- **P7-7** (`measure-reviews/2026-11-04.md`): the key hashed the prompt but not model, temperature or token cap, and the
  city and place reruns were one-signed drifts listed as floors. Settled by W46.ent-cache-key: pass 8 reports 810
  replies carrying {gemini-3.7-flash, 0, 8192} and the drifts +0.044, -0.032, -0.155, -0.029 as drifts
  (`measure-reviews/2026-11-04-2.md`) [M]. The tie rule treats a one-signed drift as a floor of that size [I].
- **P8-1 (e, f)** (`measure-reviews/2026-11-04-2.md`): `ent-robust.md`'s Apple Vision text is the 26.6 panel cache;
  `ent-score-paid`'s Vision text was read on 27.2 (2026-11-03). The Mac-route rule rests on pre-update Vision text: a
  caveat on rule `ent-vision-hands`. A Vision re-read would turn keyed replies into paid re-calls; item 6 must not
  re-read.
- **P10-8** (`measure-reviews/2026-11-05-2.md`): 88 of 138 entity8k calls came from the gateway cache. Respected: a
  caveat on the entity8k row; the sentence is now in `ent-score-paid.md`'s card [M].
- **P11-3** (`measure-reviews/2026-11-05-3.md`): the tagging prompt's place gain rested on rows the rule emptied, and the
  kept class was unchecked. Settled by W46.place-rule-sheet and W46.place-rule-fold (82375889): kept class 0 of 12
  wrong (Wilson 0% to 24%), emptied class 4 of 8 wrong (22% to 78%); the tagging line is now a tie (by city +0.03,
  -0.04 to +0.08, was +0.08), with invented places 14 to 1 (`ent-place-rule.md`; Daemon Report 2026-11-06). Its two
  Phase 4 points, the inside address and non-correspondence dates, are item 2 (call 2, decided: test).
- **P11-5** (same note): Sonnet's unasked self-rulings: sender 12, recipient 12, place 21 (14 places since emptied by
  the rule; 8 senders and 4 recipients still filled where the readers named different people); the owner overturned
  3 of 7 asked rulings (Wilson about 0.16 to 0.75), about 2-3% of those fields wrong in the truth. Cards now in
  `ent-score.md` and `ent-truth.md` [M]. The rule treats a gap under about 0.03 on sender or recipient as within truth
  error as well as noise [I].
- **The 18 rule-emptied places nobody checked** are the weakest truth rows: about half would be written on the
  fold's draw (`ent-place-rule.md` Reading). Every place figure on `ent-owner-rule` carries this.
- **`ent-robust.md` has no measurement card** [M, read in full]. Not named by any pass found; item 5.
- **Model version.** Every Vision-text arm is Gemini 3.7 Flash; the app's default is Gemini 3.8 Flash. The only 3.8
  figure is the old prompt on ABBYY text, level with 3.7 on Vision on the 82 (sender +0.03, recipient +0.01, city
  +0.00, ties; `ent-score-paid.md`), which changes model and text together.

## 6. What would change the rule

- A local route on this Mac that reaches the shipped tagging row's sender F1 (0.73, `ent-place-rule.md`) within the tie
  rule on the 138 would make the Mac family the default for profile 1 on typed pages.
- A 27B row on a 32 GB Mac with measured memory would add a profile-1 pick at 32 GB (item 4 scored both local models
  on Vision text, the 27B on the cluster only).
- A dedicated entity prompt that beats the shipped tagging call outside the tie rule on any field, with the same rules
  in both and paired on the same documents, would justify its extra call (the 3,000-character pair ties on all four,
  `ent-place-rule.md`; the 8,000-character prompt is unpaired with the shipped call).
- An HTR route for hands whose reading lifts the 27B extractor's consistency on handwritten pages from Vision's 0.52
  to 0.8 or more (`ent-robust.md` scale) would lift rule `ent-vision-hands` for that route.
- The entity feature's own prompt settling the sender convention (owner call 10) changes the sender figures of every
  row; the truth would be re-scored offline from cached replies.

## 7. Owner calls

1. **The sender and place rules in the tagging prompt.** Shipped in 4cdbba41 and 4374254d as provisional until Phase 4
   (`ent-prompt-app.md`). Options: (a) keep both; (b) loosen the sender to "a person, or the issuing organisation when
   no person is named", matching the truth and G-entities' design; (c) make both rules the entity feature's own
   prompt and revert the tagging prompt. Evidence: sender under the rule a tie (+0.025, -0.016 to +0.070); wrong
   senders 16 to 6, empty 31 to 41 of 129 (`ent-prompt-app.md`). Place line a tie on the owner-checked truth (by city
   +0.03, -0.04 to +0.08), invented places 14 to 1, wrong where written 14 to 15; it emptied all four places the owner
   restored (`ent-place-rule.md`). Dates do not move (year right 74 to 76 of 82). Recommendation [I]: keep the place
   line (it stops invented places at no measured cost, the owner's definition) and take (b) for the sender, since the
   person-only rule leaves empty senders the truth counts right and the G17 run shows the sender/firm ambiguity is
   the benchmark's too (`ent-robust.md`: 0.11 on senders naming the firm); re-score offline before shipping.
   Decided (c) (owner call 10): both rules move to the entity feature's own prompt, which decides them with its own
   measured prompt; the tagging prompt is reverted to its pre-November name behaviour.
2. **The inside address and non-correspondence dates, untested.** Whether "an address" pulls in a recipient's inside
   address is bounded only loosely (none of the 12 kept places the owner checked was one; wrong-where-written did not
   fall, `ent-place-rule.md` Scope). The tagging prompt runs on every document, and its dates on non-correspondence
   under the new lines are unmeasured. Options: test both before the rules are final (item 2), or accept and log.
   Recommendation: test; both are offline-cheap on cached text [I]. Decided: test (`14-owner-calls.md` section 2).
3. **The export: CMIF or a four-field CSV.** G-entities open question 6, a product question; the sidecar change is the
   same either way. CMIF carries `@cert` and `@evidence="conjecture"` for inferred names and maps to correspSearch; a
   `Sent With` date has no CMIF slot (G-entities §5). No user has asked for either (G-entities). Options: CMIF, CSV,
   both, or neither until asked. No measured figure bears on it. Decided: no export format until a user asks; CMIF
   against CSV goes to POTENTIAL_FEATURES, not the queue (owner call 11).
4. **Run by default, or only when the collection interview ranks names.** The fields already come with the tagging call
   at no extra money (date-tagging.md: $4.07 per 1,000 documents for the call itself); nothing in the Reader, Notes or
   the SPEC reads them yet (P6-3). The interview's priorities order reading, finding documents, dates and names
   (`12-settings-design.md`). Options: extract always and show only when names rank; extract and show always; extract
   only when names rank. Recommendation [I]: extract always on a cloud route (no cost), show when ranked; on the Mac,
   run the local model only when ranked, since it costs seconds a document. Decided as recommended (owner call 11).
   Changed at the walkthrough of 2026-11-13: extract only when names rank on every route, since the feature became a
   separate call ($2.37 per 1,000 correspondence documents, `ent-feature.md`) and nothing reads unshown names.
5. **The Mac routes' standing.** Names survive Vision text on typed pages and not on hands: the 27B extractor keeps
   0.88 of its names on typed and 0.85 on printed Vision pages, 0.52 on handwritten; through Vision 8 of 17 senders
   match (`ent-robust.md`, consistency, 26.6 text). The Mac LLM's accuracy is 0.58 / 0.55 / 0.46 for the 8B
   (`ent-truth-owner.md`, ABBYY text; since restated as 0.60 / 0.61 / 0.54 on Vision text, `ent-local-shipped.md`). Options: offer the 8B on typed and printed pages with the evidence rule and
   no Vision sender (the ent-robust rule); offer nothing on the Mac; offer it everywhere marked low confidence. Also
   whether a floor applies (the 4B at 0.51 sender, wrong more often than empty). Recommendation: the ent-robust rule
   as written, the 4B not offered [I]. Decided as recommended (owner call 11; section 2).
6. **Inferred names.** G-entities open question 2: may a name the page does not show be written, marked inferred? 38
   of Gemini's 56 unquoted names the truth confirms, and of 13 judged, 11 right and 1 an invention (`ent-score.md`).
   The rule in §3 shows them marked inferred. Recommendation: accept, as `Date Uncertain` is accepted for years [I].
   Decided: accepted, written marked inferred (owner call 10).

## 8. Items to file

1. **W46.ent-evidence-check** [S]: in the app, check each returned name against the document's own text (whitespace
   folded, edit distance 2 on names of five letters or more) and store quote or `inferred` with its source; close the
   neighbour-snippet leak. Done: a test with a quoted, an inferred and a neighbour-lifted name. Unblocked (owner call 10).
2. **W46.ent-rule-gaps** [S, offline or about $1]: the inside-address question (kept places where a recipient's address
   is the quote) and the entity prompt's dates on non-correspondence documents. Unblocked (section 2's pick).
3. **W46.ent-sender-rule** [S, offline]: restate the reverted tagging prompt's cached `tagging` replies on the owner
   truth, so the shipped row has its own figures (owner call 10); score the person-only rule on non-correspondence
   (P6-3's unmet condition) as part of the entity feature's own prompt. Waits on nothing.
4. **W46.ent-local-shipped-prompt** [M, $0 on Mac and Sherlock]: the shipped tagging prompt on Qwen3-VL 8B and Qwen3.6
   27B over the 138's Vision text, with seconds a document and peak memory on the Mac, and the 27B at 4-bit on a 32 GB
   Mac if one is at hand. Fills the gaps: every `[?]` time and memory in §4 and the 32/64 GB picks. Done 2026-11-14
   (`ent-local-shipped.md`): both rows restated, the 8B's Mac time and memory measured; no 32 GB Mac was at hand, so
   the 32/64 GB picks and the 27B's Mac memory stay open.
5. **W46.ent-robust-card** [XS, offline]: a measurement card for `ent-robust.md` with the 26.6 Vision text named (P8-1).
6. **W46.ent-feature** [M]: the sidecar fields with evidence, confidence and the "Unknown" convention, several
   recipients kept apart, inferred names marked inferred, no export format (owner call 11), the sender and place rules
   in its own prompt (owner call 10). Waits on items 1 and 3.
7. Gaps the table needs and the bench lacks: cloud seconds a document (all `measured: false`); the dedicated prompt's
   cost (estimated); the Claude plan arm (dropped by the owner, so the R5 cell stays empty unless reopened);
   handwritten accuracy beyond 5 letters (G-entities: a set needs the JPEG mirror's hands).

Not filed: entity linking for dating (2 of 54 documents bracketed, `ent-robust.md`: "does not earn a line"); names
for the enclosure relation (50% against 43%, G-entities). The salutation and closing cue (90% precision at 24% recall
on 35,563 gaps, G-entities) belongs to `07-segmentation.md`.

## 9. Profile test expectations

Kinds: T typed or printed correspondence, H handwritten correspondence, N non-correspondence (always `none`).

- **1. Laptop, open weights, 16 GB.** Only when names are ranked (owner call 11). T: `qwen3-vl-8b-mac` (sender 0.60
  on Vision text; the only Mac row above the 4B), Vision text, sender hidden. H: `qwen3-vl-8b-mac` only if the 8B also reads the page, with the quote check; on Vision text,
  `none` (rule `ent-vision-hands`). N: `none`.
- **1. 32 GB and 64 GB.** Same as 16 GB until item 4 measures the 27B on the Mac [I].
- **1. 8 GB** (not a plan tier, a solver edge): `none`, since `qwen3.5-4b-mac` is conditioned off.
- **2. Cheap API (OpenRouter).** T and H: `gemini-entity-feature` (sender 0.81) if Gemini is reachable on the key, as
  the row's `needs` allows; else `qwen3.6-27b` (0.66). N: `none`.
- **3. Premium API.** T and H: `gemini-entity-feature` (0.81 sender, $4.39 per 1,000 extra); `gemini-tagging-place`
  (0.73) is not offered by the app. A ceiling that leaves less than the feature's cost
  drops names to the profile-1 pick. **Plan only:** no plan row; fall to the profile-1 pick.
- **4. Cluster.** T and H: `qwen3.6-27b` (0.66 sender on Vision text), any reading
  route but Vision for H. With a Gemini or OpenRouter key as well: `gemini-entity-feature`. Its sender gap to
  `qwen3.6-27b` was 0.03 at 3,000 characters, inside the unpaired 0.05 tie rule, so the cluster's $0 won; at 8,000
  (0.81) it is 0.15, outside it, so the key buys the feature at $4.39 per 1,000 (W47.wh-ent-8k-apply). No paired comparison of the two is reported
  (`ent-local-shipped.md` pairs the 27B with Gemini's tagging prompt), so the 0.15 is an unpaired gap.
- **5. Plus a coding agent.** As the base profile: no kit route (the fine-tune not run, `ent-robust.md`).

## Owner's calls (2026-11-06)

From `14-owner-calls.md`. Owner call 10: both provisional rules (the person-only sender and the heading-or-address
place; 4cdbba41, 4374254d) move to the entity feature's own prompt, which decides them with its own measured prompt;
the tagging prompt is reverted to its pre-November name behaviour; a name the page does not show may be written when
marked inferred, as `Date Uncertain` is accepted for years (calls 1 and 6). Owner call 11: on a cloud route names are
extracted always and shown when the collection interview ranks names; on the Mac the local extractor runs only when
names are ranked, on typed and printed correspondence, the sender never taken from Vision text, the 4B not offered; no
export format until a user asks, CMIF against CSV going to POTENTIAL_FEATURES (calls 3, 4 and 5). Walkthrough
2026-11-13: the cloud route too runs only when names rank, and no sidecar carries the tagging call's Vision-read sender. Section 2's picks,
open to the owner's veto: the inside-address and non-correspondence-date tests filed, offline on cached text (call 2,
item 2). Section 3 carries these, and marked the Mac and cluster picks provisional on ABBYY-input figures until item 4, which has since scored both on Vision
text (2026-11-14).

Files read: execution-plans/processing-review/00-plan.md (lines 1-105);
.worktrees/archive-suite/suite-wt-20261106-205546-44529/execution-plans/processing-review/13-stage-rules/00-index.md;
execution-plans/processing-review/settings-design/figures.json ("ent") and build_figures.py;
execution-plans/processing-review/G-entities.md (Comparison, Strand questions, Open questions, Routes);
execution-plans/processing-review/11-measurement-audit.md (lines 270-295); execution-plans/processing-review/10-gap-audit.md
(stage 9 table); execution-plans/processing-review/12-settings-design.md (grep); measure-reviews/2026-11-03.md (P6-3,
P6-5, entity summary), 2026-11-04.md (four corrections, P7-7), 2026-11-04-2.md (P8-1 e-h, cache line, closing),
2026-11-05-2.md (P10-8), 2026-11-05-3.md (P11-3, P11-5), and greps of all passes; ArchiveProcessor/segbench-results/
ent-score.md, ent-score-paid.md, ent-prompt-app.md, ent-place-rule.md, ent-place-sheet.md, ent-truth.md,
ent-truth-owner.md, ent-robust.md, item-fields-score.md (grep), ocr-mac-local.md (lines 50-56), date-tagging.md (Cost);
.maintenance/AUTONOMOUS_PLAN.md (W46.place-rule-fold entries and Daemon Report 2026-11-06, W46.review-phase4).
